//! The local models behind llama-swap: embeddings and reranking now, the helper for capture later.

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

#[derive(Clone)]
pub enum Models {
    LlamaSwap { client: reqwest::Client, url: String, embedding: String, reranker: String, capture: String },
    /// Tests: embeddings from word counts, so the same words give the same vector without a GPU.
    Fake,
}

pub type Vector = Vec<f32>;

impl Models {
    pub fn llama_swap(url: &str, embedding: &str, reranker: &str, capture: &str) -> Self {
        Models::LlamaSwap {
            client: reqwest::Client::new(),
            url: url.trim_end_matches('/').to_string(),
            embedding: embedding.into(),
            reranker: reranker.into(),
            capture: capture.into(),
        }
    }

    async fn post(&self, path: &str, body: Value, timeout_secs: u64) -> Result<Value> {
        let Models::LlamaSwap { client, url, .. } = self else { bail!("no model server in tests") };
        let response = client
            .post(format!("{url}{path}"))
            .json(&body)
            .timeout(std::time::Duration::from_secs(timeout_secs))
            .send()
            .await
            .with_context(|| format!("calling {path}"))?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            bail!("{path} returned {status}: {}", text.chars().take(300).collect::<String>());
        }
        Ok(serde_json::from_str(&text)?)
    }

    pub async fn embed(&self, texts: &[String]) -> Result<Vec<Vector>> {
        let Models::LlamaSwap { embedding, .. } = self else { return Ok(texts.iter().map(|t| fake_vector(t)).collect()) };
        let mut vectors = Vec::with_capacity(texts.len());
        for batch in texts.chunks(16) {
            let out = self.post("/v1/embeddings", json!({"model": embedding, "input": batch}), 120).await?;
            let mut data: Vec<(u64, Vector)> = out["data"]
                .as_array()
                .context("no embeddings returned")?
                .iter()
                .map(|d| {
                    let v = d["embedding"].as_array().map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect());
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

    pub async fn embed_one(&self, text: String) -> Result<Vector> {
        Ok(self.embed(&[text]).await?.remove(0))
    }

    /// Relevance scores in the documents' order.
    pub async fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f64>> {
        if documents.is_empty() {
            return Ok(vec![]);
        }
        let Models::LlamaSwap { reranker, .. } = self else { bail!("no reranker in tests") };
        let out = self.post("/v1/rerank", json!({"model": reranker, "query": query, "documents": documents}), 60).await?;
        let mut scores = vec![0.0; documents.len()];
        for r in out["results"].as_array().context("no rerank results")? {
            if let (Some(i), Some(s)) = (r["index"].as_u64(), r["relevance_score"].as_f64()) {
                if let Some(slot) = scores.get_mut(i as usize) {
                    *slot = s;
                }
            }
        }
        Ok(scores)
    }

    /// The helper model's chat completion, for capture.
    pub async fn chat(&self, body: Value) -> Result<Value> {
        let Models::LlamaSwap { capture, .. } = self else { bail!("no helper in tests") };
        let mut body = body;
        body["model"] = json!(capture);
        self.post("/v1/chat/completions", body, 300).await
    }
}

fn fake_vector(text: &str) -> Vector {
    let mut v = vec![0f32; 256];
    for word in text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
        let h = word.bytes().fold(5381u32, |h, b| h.wrapping_mul(33) ^ b as u32);
        v[(h % 256) as usize] += 1.0;
    }
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-6);
    v.iter().map(|x| x / norm).collect()
}

// EmbeddingGemma's own prompts for retrieval.
pub fn query_text(query: &str) -> String {
    format!("task: search result | query: {query}")
}

pub fn memory_text(kind: &str, content: &str) -> String {
    format!("title: {kind} | text: {content}")
}

pub fn wiki_text(title: &str, heading: &str, text: &str) -> String {
    let label = if !heading.is_empty() && heading != title { format!("{title} - {heading}") } else { title.to_string() };
    format!("title: {} | text: {text}", if label.is_empty() { "none" } else { &label })
}
