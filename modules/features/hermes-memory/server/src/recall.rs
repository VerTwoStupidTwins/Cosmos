//! Recall: meaning and keyword search over memories and wiki sections, ordered by the local reranker.

use std::collections::HashMap;
use std::sync::LazyLock;

use anyhow::Result;
use regex::Regex;
use serde_json::{Value, json};

use crate::App;
use crate::db;
use crate::memory::{self, Caller, MEMORY_FIELDS};
use crate::models;
use crate::wiki;

pub const CANDIDATES: usize = 30;
// Reranker scores below these were unrelated in testing. The reranker ranks one-sentence memories
// correctly but scores them far lower than wiki sections, so memories get a lower floor, and a memory
// whose embedding is this close to the query is kept even when the reranker underrates it.
pub const MIN_SCORE: f64 = 0.02;
pub const MIN_MEMORY_SCORE: f64 = 0.01;
pub const MIN_MEMORY_SIMILARITY: f64 = 0.70;

static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\w+").unwrap());

/// Postgres' English stop words, which its full-text search ignored and SurrealDB's analyzer keeps.
const STOP_WORDS: &[&str] = &[
    "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "as", "at", "be",
    "because", "been", "before", "being", "below", "between", "both", "but", "by", "can", "did", "do", "does",
    "doing", "don", "down", "during", "each", "few", "for", "from", "further", "had", "has", "have", "having", "he",
    "her", "here", "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into", "is", "it", "its",
    "itself", "just", "me", "more", "most", "my", "myself", "no", "nor", "not", "now", "of", "off", "on", "once",
    "only", "or", "other", "our", "ours", "ourselves", "out", "over", "own", "same", "she", "should", "so", "some",
    "such", "than", "that", "the", "their", "theirs", "them", "themselves", "then", "there", "these", "they", "this",
    "those", "through", "to", "too", "under", "until", "up", "very", "was", "we", "were", "what", "when", "where",
    "which", "while", "who", "whom", "why", "will", "with", "you", "your", "yours", "yourself", "yourselves",
];

/// The query's words for keyword search, any of which may match, or None when it has none worth searching.
pub fn keywords(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let words: Vec<&str> = WORD
        .find_iter(&lower)
        .map(|m| m.as_str())
        .filter(|w| w.chars().count() > 1 && !STOP_WORDS.contains(w))
        .take(32)
        .collect();
    if words.is_empty() { None } else { Some(words.join(" ")) }
}

/// Reciprocal rank fusion of several ranked id lists.
pub fn fuse(lists: &[Vec<Value>]) -> Vec<Value> {
    let mut scores: Vec<(Value, f64)> = vec![];
    for ids in lists {
        for (rank, key) in ids.iter().enumerate() {
            let add = 1.0 / (60.0 + rank as f64);
            match scores.iter_mut().find(|(k, _)| k == key) {
                Some((_, s)) => *s += add,
                None => scores.push((key.clone(), add)),
            }
        }
    }
    // A stable sort keeps first-seen order for ties, as Python's sorted() does.
    scores.sort_by(|a, b| b.1.total_cmp(&a.1));
    scores.into_iter().map(|(k, _)| k).collect()
}

fn ids(rows: &[Value]) -> Vec<Value> {
    rows.iter().map(|r| r["id"].clone()).collect()
}

async fn memory_candidates(
    app: &App,
    qvec: &[f32],
    words: &Option<String>,
    caller: &Caller,
    include_past: bool,
) -> Result<Vec<Value>> {
    let (vis, mut params) = memory::visibility(caller, include_past);
    params.push(("q", json!(qvec)));
    params.push(("n", json!(CANDIDATES)));
    let by_meaning = db::rows(
        &app.db,
        &format!(
            "SELECT record::id(id) AS id, vector::similarity::cosine(embedding, $q) AS s FROM memory
             WHERE {vis} ORDER BY s DESC LIMIT $n"
        ),
        params.clone(),
    )
    .await?;
    let mut by_words = vec![];
    if let Some(w) = words {
        let mut p = params.clone();
        p.push(("words", json!(w)));
        by_words = db::rows(
            &app.db,
            &format!(
                "SELECT record::id(id) AS id, search::score(1) AS score FROM memory
                 WHERE {vis} AND content @1,OR@ $words ORDER BY score DESC LIMIT $n"
            ),
            p,
        )
        .await?;
    }
    let order: Vec<Value> = fuse(&[ids(&by_meaning), ids(&by_words)]).into_iter().take(CANDIDATES).collect();
    if order.is_empty() {
        return Ok(vec![]);
    }
    let rows = db::rows(
        &app.db,
        &format!(
            "SELECT {MEMORY_FIELDS}, vector::similarity::cosine(embedding, $q) AS similarity
             FROM memory WHERE record::id(id) IN $ids"
        ),
        vec![("q", json!(qvec)), ("ids", json!(order))],
    )
    .await?;
    Ok(order.iter().filter_map(|id| rows.iter().find(|r| &r["id"] == id).cloned()).collect())
}

async fn wiki_candidates(app: &App, qvec: &[f32], words: &Option<String>, include_deprecated: bool) -> Result<Vec<Value>> {
    let filter = "($deprecated OR page.details.status != 'deprecated')";
    let params = vec![("q", json!(qvec)), ("n", json!(CANDIDATES)), ("deprecated", json!(include_deprecated))];
    let by_meaning = db::rows(
        &app.db,
        &format!(
            "SELECT id, vector::similarity::cosine(embedding, $q) AS s FROM wiki_chunk
             WHERE {filter} ORDER BY s DESC LIMIT $n"
        ),
        params.clone(),
    )
    .await?;
    let mut by_words = vec![];
    if let Some(w) = words {
        let mut p = params.clone();
        p.push(("words", json!(w)));
        by_words = db::rows(
            &app.db,
            &format!(
                "SELECT id, search::score(1) AS score FROM wiki_chunk
                 WHERE {filter} AND search_text @1,OR@ $words ORDER BY score DESC LIMIT $n"
            ),
            p,
        )
        .await?;
    }
    let order: Vec<Value> = fuse(&[ids(&by_meaning), ids(&by_words)]).into_iter().take(CANDIDATES).collect();
    if order.is_empty() {
        return Ok(vec![]);
    }
    let rows = db::rows(
        &app.db,
        "SELECT id, record::id(page) AS path, heading, text, page.title AS title, page.details AS details
         FROM wiki_chunk WHERE <string>id IN $ids",
        vec![("ids", json!(order))],
    )
    .await?;
    Ok(order.iter().filter_map(|id| rows.iter().find(|r| &r["id"] == id).cloned()).collect())
}

pub struct Search {
    pub query: String,
    pub limit: usize,
    pub memories: bool,
    pub wiki: bool,
    pub include_past: bool,
    pub include_deprecated: bool,
}

pub async fn search(app: &App, s: Search, caller: &Caller) -> Result<Value> {
    let mut notes: Vec<String> = vec![];
    if s.wiki {
        match wiki::sync(app, false).await {
            Ok(0) => {}
            Ok(n) => notes.push(format!("Re-indexed {n} changed wiki page(s).")),
            Err(e) => notes.push(format!("Couldn't update the wiki index, so recent edits may be missing: {e:#}")),
        }
    }

    let qvec = app.models.embed_one(models::query_text(&s.query)).await?;
    let words = keywords(&s.query);
    let memories = if s.memories { memory_candidates(app, &qvec, &words, caller, s.include_past).await? } else { vec![] };
    let chunks = if s.wiki { wiki_candidates(app, &qvec, &words, s.include_deprecated).await? } else { vec![] };

    // Plain sentences ranked better than the embedding prompt format in testing.
    let mut docs: Vec<String> = memories.iter().map(|r| r["content"].as_str().unwrap_or("").to_string()).collect();
    docs.extend(chunks.iter().map(|r| {
        models::wiki_text(r["title"].as_str().unwrap_or(""), r["heading"].as_str().unwrap_or(""), r["text"].as_str().unwrap_or(""))
    }));
    let (scores, reranked) = match app.models.rerank(&s.query, &docs).await {
        Ok(scores) => (scores, true),
        Err(e) => {
            notes.push(format!("Reranker unavailable, so results are in search order: {e:#}"));
            ((0..docs.len()).map(|i| 1.0 / (1.0 + i as f64)).collect(), false)
        }
    };

    enum Item<'a> {
        Memory(&'a Value),
        Wiki(&'a Value),
    }
    let mut items: Vec<(f64, Item, f64)> = vec![];
    for (row, score) in memories.iter().zip(&scores) {
        let similarity = row["similarity"].as_f64().unwrap_or(0.0);
        if reranked && *score < MIN_MEMORY_SCORE && similarity < MIN_MEMORY_SIMILARITY {
            continue;
        }
        // What the owner said or confirmed outranks what was inferred.
        let boost = if row["origin"] == "stated" || !row["confirmed_at"].is_null() { 1.1 } else { 1.0 };
        items.push((score * boost, Item::Memory(row), *score));
    }
    for (row, score) in chunks.iter().zip(scores.iter().skip(memories.len())) {
        if !reranked || *score >= MIN_SCORE {
            items.push((*score, Item::Wiki(row), *score));
        }
    }
    items.sort_by(|a, b| b.0.total_cmp(&a.0));

    let mut results = vec![];
    let mut per_page: HashMap<String, usize> = HashMap::new();
    for (_, item, score) in &items {
        match item {
            Item::Wiki(row) => {
                let count = per_page.entry(row["path"].as_str().unwrap_or("").to_string()).or_default();
                if *count >= 2 {
                    continue;
                }
                *count += 1;
                results.push(wiki::section_json(app, row, *score));
            }
            Item::Memory(row) => results.push(memory::memory_json(row, Some(*score))),
        }
        if results.len() >= s.limit {
            break;
        }
    }

    let recalled: Vec<Value> = results.iter().filter(|r| r["source"] == "memory").map(|r| r["id"].clone()).collect();
    if !recalled.is_empty() {
        db::run(
            &app.db,
            "FOR $i IN $ids { UPDATE type::record('memory', $i) SET last_recalled_at = time::now(), recall_count += 1; };",
            vec![("ids", json!(recalled))],
        )
        .await?;
    }

    let empty = results.is_empty();
    let mut out = json!({"results": results});
    if empty {
        out["message"] = json!("Nothing closely matches.");
    }
    if !notes.is_empty() {
        out["notes"] = json!(notes);
    }
    Ok(out)
}
