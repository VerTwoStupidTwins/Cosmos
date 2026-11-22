//! nabu's models through llama-swap: the embedding model and reranker for search, the helper for consolidation.

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::store::Point;

pub struct Models {
    http: reqwest::Client,
    url: String,
    pub embedding: String,
    reranker: String,
    helper: String,
}

impl Models {
    pub fn new(url: &str, embedding: &str, reranker: &str, helper: &str) -> Self {
        Models {
            http: reqwest::Client::new(),
            url: url.trim_end_matches('/').into(),
            embedding: embedding.into(),
            reranker: reranker.into(),
            helper: helper.into(),
        }
    }

    async fn post(&self, path: &str, body: Value, timeout_secs: u64) -> Result<Value> {
        let response = self
            .http
            .post(format!("{}{path}", self.url))
            .json(&body)
            .timeout(std::time::Duration::from_secs(timeout_secs))
            .send()
            .await
            .with_context(|| format!("can't reach the models at {}", self.url))?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            bail!("{path} answered {status}: {}", text.chars().take(300).collect::<String>());
        }
        Ok(serde_json::from_str(&text)?)
    }

    pub async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut vectors = Vec::with_capacity(texts.len());
        for batch in texts.chunks(16) {
            let out = self.post("/v1/embeddings", json!({ "model": self.embedding, "input": batch }), 120).await?;
            let mut data: Vec<(u64, Vec<f32>)> = out["data"]
                .as_array()
                .context("no embeddings returned")?
                .iter()
                .map(|d| {
                    let v = d["embedding"].as_array().map(|a| a.iter().filter_map(Value::as_f64).map(|x| x as f32).collect());
                    (d["index"].as_u64().unwrap_or(0), v.unwrap_or_default())
                })
                .collect();
            data.sort_by_key(|(i, _)| *i);
            vectors.extend(data.into_iter().map(|(_, v)| v));
        }
        if vectors.len() != texts.len() {
            bail!("asked for {} embeddings, got {}", texts.len(), vectors.len());
        }
        Ok(vectors)
    }

    /// Relevance scores (0 to 1) in the documents' order.
    pub async fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f64>> {
        if documents.is_empty() {
            return Ok(vec![]);
        }
        let out = self.post("/v1/rerank", json!({ "model": self.reranker, "query": query, "documents": documents }), 60).await?;
        let mut scores = vec![0.0; documents.len()];
        for r in out["results"].as_array().context("no rerank results")? {
            if let (Some(i), Some(s)) = (r["index"].as_u64(), r["relevance_score"].as_f64())
                && let Some(slot) = scores.get_mut(i as usize)
            {
                *slot = s;
            }
        }
        Ok(scores)
    }

    /// The helper's answer, held to a JSON schema by llama.cpp's grammar.
    pub async fn chat_json(&self, system: &str, user: &str, schema: Value) -> Result<Value> {
        let out = self
            .post(
                "/v1/chat/completions",
                json!({
                    "model": self.helper,
                    "messages": [{ "role": "system", "content": system }, { "role": "user", "content": user }],
                    "response_format": { "type": "json_schema", "json_schema": { "name": "memory", "schema": schema, "strict": true } },
                    "max_tokens": 3000,
                    "chat_template_kwargs": { "enable_thinking": false },
                }),
                600,
            )
            .await?;
        let text = out["choices"][0]["message"]["content"].as_str().context("the helper returned no text")?;
        serde_json::from_str(text).with_context(|| format!("the helper's answer isn't JSON: {}", text.chars().take(200).collect::<String>()))
    }
}

// EmbeddingGemma's own prompts for retrieval.
pub fn query_text(query: &str) -> String {
    format!("task: search result | query: {query}")
}

pub fn document_text(p: &Point) -> String {
    let title = match p.kind_of.as_str() {
        "item" => p.kind.clone().unwrap_or_else(|| "note".into()),
        "topic" => "conversation topic".into(),
        _ => "conversation".into(),
    };
    format!("title: {title} | text: {}", p.content)
}

pub fn item_text(kind: &str, content: &str) -> String {
    format!("title: {kind} | text: {content}")
}
