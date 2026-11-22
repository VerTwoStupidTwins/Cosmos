//! The search index: Qdrant's REST API on localhost, one collection with a meaning vector (`text`, from nabu's
//! embedding model) and a keyword vector (`words`, BM25: term weights here, IDF from Qdrant) per point.

use std::collections::BTreeMap;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::store::Point;

pub const COLLECTION: &str = "memory";

// ---- keyword vectors

const STOP_WORDS: &[&str] = &[
    "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been", "being",
    "but", "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her", "here", "him",
    "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "me", "more", "my", "no", "not", "now", "of",
    "on", "one", "or", "our", "out", "she", "so", "some", "than", "that", "the", "their", "them", "then", "there",
    "these", "they", "this", "to", "too", "up", "us", "very", "was", "we", "were", "what", "when", "where", "which",
    "who", "why", "will", "with", "would", "you", "your", "owner", "assistant",
];

/// Lowercase words without stop words, with plurals folded ("fans" → "fan").
pub fn tokens(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && !STOP_WORDS.contains(w))
        .map(|w| {
            if w.len() > 3 && w.ends_with('s') && !w.ends_with("ss") && !w.chars().any(|c| c.is_ascii_digit()) {
                w[..w.len() - 1].to_string()
            } else {
                w.to_string()
            }
        })
        .collect()
}

fn term(word: &str) -> u32 {
    // FNV-1a: stable across versions, unlike std's hasher.
    word.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193))
}

/// BM25's term-frequency part for a stored text (k1 1.2, b 0.75, a typical length of 60 words).
pub fn document_words(text: &str) -> (Vec<u32>, Vec<f32>) {
    let words = tokens(text);
    let length = words.len().max(1) as f32;
    let mut counts: BTreeMap<u32, f32> = BTreeMap::new();
    for w in &words {
        *counts.entry(term(w)).or_default() += 1.0;
    }
    let norm = 1.2 * (0.25 + 0.75 * length / 60.0);
    counts.into_iter().map(|(t, tf)| (t, tf * 2.2 / (tf + norm))).unzip()
}

/// A query weighs each of its words once.
pub fn query_words(text: &str) -> (Vec<u32>, Vec<f32>) {
    let mut terms: Vec<u32> = tokens(text).iter().map(|w| term(w)).collect();
    terms.sort_unstable();
    terms.dedup();
    let values = vec![1.0; terms.len()];
    (terms, values)
}

// ---- Qdrant

pub struct Qdrant {
    http: reqwest::Client,
    url: String,
    key: String,
}

impl Qdrant {
    pub fn new(url: &str, key: String) -> Self {
        let http = reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)).build().expect("http client");
        Qdrant { http, url: url.trim_end_matches('/').into(), key }
    }

    async fn call(&self, method: reqwest::Method, path: &str, body: Option<Value>) -> Result<(u16, Value)> {
        let mut request = self.http.request(method, format!("{}{path}", self.url)).header("api-key", &self.key);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.with_context(|| format!("can't reach Qdrant at {}", self.url))?;
        let status = response.status().as_u16();
        let text = response.text().await?;
        let value = serde_json::from_str(&text).unwrap_or(json!({ "text": text }));
        Ok((status, value))
    }

    async fn ok(&self, method: reqwest::Method, path: &str, body: Option<Value>) -> Result<Value> {
        let (status, value) = self.call(method, path, body).await?;
        if !(200..300).contains(&status) {
            bail!("Qdrant {path}: {status} {}", value["status"]["error"].as_str().unwrap_or(&value.to_string()));
        }
        Ok(value["result"].clone())
    }

    /// Makes the collection fit vectors of `dims`. Returns true when it was (re)created empty, so everything has to be
    /// indexed again.
    pub async fn ensure(&self, dims: usize) -> Result<bool> {
        let path = format!("/collections/{COLLECTION}");
        let (status, info) = self.call(reqwest::Method::GET, &path, None).await?;
        if status == 200 {
            let size = info["result"]["config"]["params"]["vectors"]["text"]["size"].as_u64();
            if size == Some(dims as u64) {
                return Ok(false);
            }
            eprintln!("memory: the collection has {size:?}-dimension vectors, the model makes {dims}; rebuilding it");
            self.ok(reqwest::Method::DELETE, &path, None).await?;
        } else if status != 404 {
            bail!("Qdrant {path}: {status} {info}");
        }
        self.ok(
            reqwest::Method::PUT,
            &path,
            Some(json!({
                "vectors": { "text": { "size": dims, "distance": "Cosine" } },
                "sparse_vectors": { "words": { "modifier": "idf" } },
            })),
        )
        .await?;
        for (field, schema) in
            [("type", "keyword"), ("kind", "keyword"), ("status", "keyword"), ("room", "keyword"), ("core", "bool"), ("at", "integer")]
        {
            self.ok(
                reqwest::Method::PUT,
                &format!("{path}/index?wait=true"),
                Some(json!({ "field_name": field, "field_schema": schema })),
            )
            .await?;
        }
        eprintln!("memory: created the Qdrant collection ({dims} dimensions)");
        Ok(true)
    }

    pub async fn upsert(&self, points: &[(&Point, Vec<f32>)]) -> Result<()> {
        if points.is_empty() {
            return Ok(());
        }
        let body: Vec<Value> = points
            .iter()
            .map(|(p, dense)| {
                let (indices, values) = document_words(&p.content);
                json!({
                    "id": p.id,
                    "vector": { "text": dense, "words": { "indices": indices, "values": values } },
                    "payload": { "type": p.kind_of, "kind": p.kind, "status": p.status, "core": p.core, "room": p.room,
                                 "at": p.created_at() },
                })
            })
            .collect();
        self.ok(reqwest::Method::PUT, &format!("/collections/{COLLECTION}/points?wait=true"), Some(json!({ "points": body })))
            .await?;
        Ok(())
    }

    pub async fn delete(&self, ids: &[i64]) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        self.ok(reqwest::Method::POST, &format!("/collections/{COLLECTION}/points/delete?wait=true"), Some(json!({ "points": ids })))
            .await?;
        Ok(())
    }

    fn ids(result: &Value) -> Vec<(i64, f64)> {
        result["points"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| Some((p["id"].as_i64()?, p["score"].as_f64().unwrap_or(0.0))))
            .collect()
    }

    /// Meaning and keywords searched apart and fused by rank (RRF), best first.
    pub async fn hybrid(&self, dense: &[f32], text: &str, filter: &Value, limit: usize) -> Result<Vec<i64>> {
        let (indices, values) = query_words(text);
        let mut prefetch = vec![json!({ "query": dense, "using": "text", "limit": limit, "filter": filter })];
        if !indices.is_empty() {
            prefetch.push(json!({ "query": { "indices": indices, "values": values }, "using": "words", "limit": limit,
                                  "filter": filter }));
        }
        let result = self
            .ok(
                reqwest::Method::POST,
                &format!("/collections/{COLLECTION}/points/query"),
                Some(json!({ "prefetch": prefetch, "query": { "fusion": "rrf" }, "limit": limit })),
            )
            .await?;
        Ok(Self::ids(&result).into_iter().map(|(id, _)| id).collect())
    }

    /// The nearest points by meaning to a vector, with their cosine similarity.
    pub async fn similar(&self, dense: &[f32], filter: &Value, limit: usize) -> Result<Vec<(i64, f64)>> {
        let result = self
            .ok(
                reqwest::Method::POST,
                &format!("/collections/{COLLECTION}/points/query"),
                Some(json!({ "query": dense, "using": "text", "limit": limit, "filter": filter })),
            )
            .await?;
        Ok(Self::ids(&result))
    }

    /// The nearest points by meaning to a stored point.
    pub async fn near_point(&self, id: i64, filter: &Value, limit: usize) -> Result<Vec<(i64, f64)>> {
        let result = self
            .ok(
                reqwest::Method::POST,
                &format!("/collections/{COLLECTION}/points/query"),
                Some(json!({ "query": id, "using": "text", "limit": limit, "filter": filter })),
            )
            .await?;
        Ok(Self::ids(&result))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words() {
        assert_eq!(tokens("The P100s' fans are LOUD, aren't they?"), vec!["p100s", "fan", "loud", "aren", "t"]);
        let (a, _) = query_words("fan fans duct");
        assert_eq!(a.len(), 2);
        let weight = |(terms, values): (Vec<u32>, Vec<f32>)| values[terms.iter().position(|t| *t == term("fan")).unwrap()];
        let short = weight(document_words("fan duct"));
        let long = weight(document_words(&format!("fan {}", "word ".repeat(200))));
        assert!(short > long, "a word counts for more in a short text");
    }
}
