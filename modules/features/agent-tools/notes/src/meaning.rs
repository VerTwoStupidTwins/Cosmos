//! Search by meaning. Each note is cut into sections at its headings, and each section is embedded by nabu's embedding
//! model into a Qdrant collection of the vault's own, with a BM25 keyword vector beside it (as the memory server does).
//! A search runs both, fuses them by rank and has the reranker order what comes back.
//!
//! The index holds nothing the vault doesn't, so it can be dropped and rebuilt at any time. Each section carries its
//! note's fingerprint and the embedding model's name; a sync re-embeds the notes whose fingerprint (or model) changed
//! and drops the notes that are gone. `notes index` keeps it in step as the vault changes, and each search syncs first,
//! so a note saved a moment ago is found too.

use crate::library::{Library, clip};
use crate::note::{Note, fingerprint};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;

/// Sections are cut at headings, then held between these sizes (in characters): a short one joins the next, and a
/// long one is split between paragraphs. About 50 to 600 tokens, small enough for a match to point somewhere.
const MIN_SECTION: usize = 200;
const MAX_SECTION: usize = 2400;

/// How many notes a search embeds before answering; `notes index` does the rest.
const SYNC_DURING_SEARCH: usize = 40;

#[derive(clap::Args, Clone)]
pub struct Config {
    /// Qdrant's URL; without it, there's no search by meaning.
    #[arg(long)]
    pub qdrant: Option<String>,
    /// Qdrant's read/write API key, as a file; default: the qdrant-api-key credential from systemd.
    #[arg(long)]
    pub qdrant_key_file: Option<PathBuf>,
    /// The vault's collection in Qdrant.
    #[arg(long, default_value = "notes")]
    pub collection: String,
    /// The OpenAI-style API with the embedding model and the reranker (nabu's llama-swap).
    #[arg(long, default_value = "http://nabu.netbird.cloud:8080/v1")]
    pub models: String,
    #[arg(long, default_value = "embedding")]
    pub embedding_model: String,
    #[arg(long, default_value = "reranker")]
    pub reranker_model: String,
    /// A folder (relative to the vault) to leave out of the index, such as a plugin's own files; repeatable.
    #[arg(long = "exclude")]
    pub exclude: Vec<String>,
}

pub struct Index {
    qdrant: String,
    key: String,
    collection: String,
    models: String,
    embedding: String,
    reranker: String,
    exclude: Vec<String>,
    http: ureq::Agent,
    /// The embedding's dimensions, once the collection is made to fit them.
    dims: OnceLock<usize>,
}

/// What a sync did.
#[derive(Debug, Default)]
pub struct Synced {
    pub embedded: usize,
    pub sections: usize,
    pub dropped: usize,
    /// Notes still to embed, when the sync stopped at its limit.
    pub waiting: usize,
}

impl Index {
    /// None without a Qdrant URL.
    pub fn new(config: &Config) -> Result<Option<Self>> {
        let Some(qdrant) = &config.qdrant else { return Ok(None) };
        let key_file = match &config.qdrant_key_file {
            Some(file) => file.clone(),
            None => PathBuf::from(std::env::var("CREDENTIALS_DIRECTORY").context("no --qdrant-key-file, and no systemd credentials")?)
                .join("qdrant-api-key"),
        };
        let key = std::fs::read_to_string(&key_file).with_context(|| format!("reading {}", key_file.display()))?;
        Ok(Some(Index {
            qdrant: qdrant.trim_end_matches('/').into(),
            key: key.trim().into(),
            collection: config.collection.clone(),
            models: config.models.trim_end_matches('/').into(),
            embedding: config.embedding_model.clone(),
            reranker: config.reranker_model.clone(),
            exclude: config.exclude.iter().map(|f| f.trim().trim_matches('/').to_string()).filter(|f| !f.is_empty()).collect(),
            http: ureq::AgentBuilder::new().timeout(Duration::from_secs(120)).build(),
            dims: OnceLock::new(),
        }))
    }

    // ---- nabu's models

    fn post_model(&self, path: &str, body: Value) -> Result<Value> {
        match self.http.post(&format!("{}{path}", self.models)).send_json(body) {
            Ok(response) => Ok(response.into_json()?),
            Err(ureq::Error::Status(code, response)) => {
                bail!("{path} answered {code}: {}", clip(&response.into_string().unwrap_or_default(), 300).0)
            }
            Err(e) => Err(e).with_context(|| format!("can't reach the models at {}", self.models)),
        }
    }

    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut vectors = Vec::with_capacity(texts.len());
        for batch in texts.chunks(16) {
            let out = self.post_model("/embeddings", json!({ "model": self.embedding, "input": batch }))?;
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
    fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f64>> {
        let out = self.post_model("/rerank", json!({ "model": self.reranker, "query": query, "documents": documents }))?;
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

    // ---- Qdrant

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<(u16, Value)> {
        let request = self.http.request(method, &format!("{}{path}", self.qdrant)).set("api-key", &self.key);
        let response = match body {
            Some(body) => request.send_json(body),
            None => request.call(),
        };
        match response {
            Ok(r) => Ok((r.status(), r.into_json().unwrap_or(Value::Null))),
            Err(ureq::Error::Status(code, r)) => Ok((code, r.into_json().unwrap_or(Value::Null))),
            Err(e) => Err(e).with_context(|| format!("can't reach Qdrant at {}", self.qdrant)),
        }
    }

    fn ok(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        let (status, value) = self.call(method, path, body)?;
        if !(200..300).contains(&status) {
            bail!("Qdrant {path}: {status} {}", value["status"]["error"].as_str().map(String::from).unwrap_or(value.to_string()));
        }
        Ok(value["result"].clone())
    }

    fn path(&self, rest: &str) -> String {
        format!("/collections/{}{rest}", self.collection)
    }

    /// Makes the collection fit the embedding model's vectors, once per process.
    fn ensure(&self) -> Result<()> {
        if self.dims.get().is_some() {
            return Ok(());
        }
        let dims = self.embed(&[query_text("probe")])?.remove(0).len();
        let (status, info) = self.call("GET", &self.path(""), None)?;
        let fits = status == 200 && info["result"]["config"]["params"]["vectors"]["text"]["size"].as_u64() == Some(dims as u64);
        if !fits {
            if status == 200 {
                eprintln!("notes: {} has vectors of another size; rebuilding it for {dims}", self.collection);
                self.ok("DELETE", &self.path(""), None)?;
            } else if status != 404 {
                bail!("Qdrant {}: {status} {info}", self.path(""));
            }
            self.ok(
                "PUT",
                &self.path(""),
                Some(json!({
                    "vectors": { "text": { "size": dims, "distance": "Cosine" } },
                    "sparse_vectors": { "words": { "modifier": "idf" } },
                })),
            )?;
            for field in ["path", "folders"] {
                self.ok("PUT", &self.path("/index?wait=true"), Some(json!({ "field_name": field, "field_schema": "keyword" })))?;
            }
            eprintln!("notes: created the Qdrant collection {} ({dims} dimensions)", self.collection);
        }
        let _ = self.dims.set(dims);
        Ok(())
    }

    /// Every indexed note: its fingerprint and model, and its sections' point ids.
    fn indexed(&self) -> Result<HashMap<String, Indexed>> {
        let mut notes: HashMap<String, Indexed> = HashMap::new();
        let mut offset = Value::Null;
        loop {
            let page = self.ok(
                "POST",
                &self.path("/points/scroll"),
                Some(json!({ "limit": 1000, "offset": offset, "with_vector": false,
                             "with_payload": ["path", "fingerprint", "model"] })),
            )?;
            for point in page["points"].as_array().into_iter().flatten() {
                let (Some(id), Some(path)) = (point["id"].as_u64(), point["payload"]["path"].as_str()) else { continue };
                let note = notes.entry(path.into()).or_default();
                note.ids.push(id);
                note.fingerprint = point["payload"]["fingerprint"].as_str().unwrap_or("").into();
                note.model = point["payload"]["model"].as_str().unwrap_or("").into();
            }
            offset = page["next_page_offset"].clone();
            if offset.is_null() {
                return Ok(notes);
            }
        }
    }

    fn delete(&self, ids: &[u64]) -> Result<()> {
        for batch in ids.chunks(500) {
            self.ok("POST", &self.path("/points/delete?wait=true"), Some(json!({ "points": batch })))?;
        }
        Ok(())
    }

    /// Brings the collection in step with the vault, embedding at most `limit` notes.
    pub fn sync(&self, library: &Library, limit: Option<usize>) -> Result<Synced> {
        self.ensure()?;
        // Notes in an excluded folder count as gone, so excluding one drops what was indexed from it.
        let disk: BTreeMap<String, String> = library
            .notes_under(&library.root)?
            .into_iter()
            .filter(|found| !excluded(&found.rel, &self.exclude))
            .map(|found| (found.rel, found.raw))
            .collect();
        let indexed = self.indexed()?;
        let plan = plan(&disk, &indexed, &self.embedding);
        let mut synced = Synced::default();

        let gone: Vec<u64> = plan.drop.iter().flat_map(|path| indexed[path].ids.iter().copied()).collect();
        self.delete(&gone)?;
        synced.dropped = plan.drop.len();

        let limit = limit.unwrap_or(usize::MAX);
        synced.waiting = plan.embed.len().saturating_sub(limit);
        for path in plan.embed.iter().take(limit) {
            let raw = &disk[path];
            let fingerprint = fingerprint(raw.as_bytes());
            let parts = sections(path, raw);
            let vectors = self.embed(&parts.iter().map(|s| document_text(path, s)).collect::<Vec<_>>())?;
            let folders = folders(path);
            let mut ids = HashSet::new();
            let points: Vec<Value> = parts
                .iter()
                .zip(vectors)
                .enumerate()
                .map(|(i, (section, dense))| {
                    let id = point_id(path, i);
                    ids.insert(id);
                    let (indices, values) = document_words(&format!("{} {} {}", title(path), section.heading, section.text));
                    json!({
                        "id": id,
                        "vector": { "text": dense, "words": { "indices": indices, "values": values } },
                        "payload": { "path": path, "folders": folders, "heading": section.heading, "text": section.text,
                                     "section": i, "fingerprint": fingerprint, "model": self.embedding },
                    })
                })
                .collect();
            self.ok("PUT", &self.path("/points?wait=true"), Some(json!({ "points": points })))?;
            // A note with fewer sections than before leaves its old last ones behind otherwise.
            let stale: Vec<u64> =
                indexed.get(path).map(|old| old.ids.iter().copied().filter(|id| !ids.contains(id)).collect()).unwrap_or_default();
            self.delete(&stale)?;
            synced.embedded += 1;
            synced.sections += parts.len();
        }
        Ok(synced)
    }

    /// Notes whose sections best match a question by meaning, best first.
    pub fn search(&self, library: &Library, query: &str, folder: &str, limit: usize) -> Result<Value> {
        let query = query.trim();
        if query.is_empty() {
            bail!("say what you're looking for");
        }
        let folder = library.show(&library.resolve(folder)?);
        let mut notes = Vec::new();
        match self.sync(library, Some(SYNC_DURING_SEARCH)) {
            Ok(s) if s.waiting > 0 => notes.push(format!("{} notes changed lately aren't indexed yet; search by words finds them", s.waiting)),
            Ok(_) => {}
            Err(e) => {
                if self.dims.get().is_none() {
                    return Err(e.context("the index isn't ready"));
                }
                notes.push(format!("the index may be behind, as syncing failed: {e:#}"));
            }
        }

        let filter = if folder.is_empty() { json!({}) } else { json!({ "must": [{ "key": "folders", "match": { "value": folder } }] }) };
        let dense = self.embed(&[query_text(query)])?.remove(0);
        let (indices, values) = query_words(query);
        let mut prefetch = vec![json!({ "query": dense, "using": "text", "limit": 40, "filter": filter })];
        if !indices.is_empty() {
            prefetch.push(json!({ "query": { "indices": indices, "values": values }, "using": "words", "limit": 40, "filter": filter }));
        }
        let found = self.ok(
            "POST",
            &self.path("/points/query"),
            Some(json!({ "prefetch": prefetch, "query": { "fusion": "rrf" }, "limit": 25, "with_payload": true })),
        )?;
        let hits: Vec<Hit> = found["points"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| {
                let payload = &p["payload"];
                Some(Hit {
                    path: payload["path"].as_str()?.into(),
                    heading: payload["heading"].as_str().unwrap_or("").into(),
                    text: payload["text"].as_str().unwrap_or("").into(),
                    score: None,
                })
            })
            .collect();

        let documents: Vec<String> = hits.iter().map(|h| clip(&format!("{}\n{}", h.label(), h.text), MAX_SECTION).0).collect();
        let ranked = if documents.is_empty() {
            hits
        } else {
            match self.rerank(query, &documents) {
                Ok(scores) => {
                    let mut hits: Vec<Hit> = hits.into_iter().zip(scores).map(|(h, s)| Hit { score: Some(s), ..h }).collect();
                    hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
                    hits
                }
                Err(e) => {
                    notes.push(format!("unranked, as the reranker failed: {e:#}"));
                    hits
                }
            }
        };

        Ok(json!({
            "query": query,
            "notes": best_per_note(ranked, limit.clamp(1, 20)),
            "note": if notes.is_empty() { Value::Null } else { json!(notes.join("; ")) },
        }))
    }
}

#[derive(Default)]
struct Indexed {
    fingerprint: String,
    model: String,
    ids: Vec<u64>,
}

struct Hit {
    path: String,
    heading: String,
    text: String,
    score: Option<f64>,
}

impl Hit {
    fn label(&self) -> String {
        if self.heading.is_empty() { title(&self.path) } else { format!("{} › {}", title(&self.path), self.heading) }
    }
}

/// One entry per note, at its best section, with the headings of its other matching sections.
fn best_per_note(hits: Vec<Hit>, limit: usize) -> Vec<Value> {
    let mut order: Vec<String> = Vec::new();
    let mut by_note: HashMap<String, (Hit, Vec<String>)> = HashMap::new();
    for hit in hits {
        match by_note.get_mut(&hit.path) {
            Some((_, more)) => {
                if !hit.heading.is_empty() && !more.contains(&hit.heading) {
                    more.push(hit.heading);
                }
            }
            None => {
                order.push(hit.path.clone());
                by_note.insert(hit.path.clone(), (hit, Vec::new()));
            }
        }
    }
    order
        .into_iter()
        .take(limit)
        .map(|path| {
            let (best, more) = by_note.remove(&path).unwrap();
            let mut entry = json!({ "path": best.path, "excerpt": clip(best.text.trim(), 400).0 });
            if !best.heading.is_empty() {
                entry["section"] = json!(best.heading);
            }
            if let Some(score) = best.score {
                entry["relevance"] = json!((score * 100.0).round() / 100.0);
            }
            if !more.is_empty() {
                entry["also_in"] = json!(more);
            }
            entry
        })
        .collect()
}

/// Which notes to embed (new, changed, or embedded by another model) and which to drop (gone from the vault).
struct Plan {
    embed: Vec<String>,
    drop: Vec<String>,
}

fn plan(disk: &BTreeMap<String, String>, indexed: &HashMap<String, Indexed>, model: &str) -> Plan {
    let embed = disk
        .iter()
        .filter(|(path, raw)| {
            indexed.get(*path).is_none_or(|old| old.model != model || old.fingerprint != fingerprint(raw.as_bytes()))
        })
        .map(|(path, _)| path.clone())
        .collect();
    let mut drop: Vec<String> = indexed.keys().filter(|path| !disk.contains_key(*path)).cloned().collect();
    drop.sort();
    Plan { embed, drop }
}

// ---- sections

#[derive(Debug, PartialEq)]
pub struct Section {
    /// The headings above it, outermost first, joined with " › "; empty before the first heading.
    pub heading: String,
    pub text: String,
}

/// A note cut at its headings (outside code blocks), then held between MIN_SECTION and MAX_SECTION. Its tags lead
/// the first section. A note with no text is one section of its name.
pub fn sections(path: &str, raw: &str) -> Vec<Section> {
    let note = Note::parse(raw);
    let mut cut: Vec<Section> = Vec::new();
    let mut stack: Vec<(usize, String)> = Vec::new();
    let mut current = Section { heading: String::new(), text: String::new() };
    let mut fence = false;
    for line in note.body.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fence = !fence;
        }
        let level = trimmed.chars().take_while(|&c| c == '#').count();
        let is_heading = !fence && (1..=6).contains(&level) && trimmed[level..].starts_with([' ', '\t']);
        if is_heading {
            if !current.text.trim().is_empty() {
                cut.push(current);
            }
            stack.retain(|(l, _)| *l < level);
            stack.push((level, trimmed[level..].trim().trim_end_matches('#').trim().to_string()));
            current = Section { heading: stack.iter().map(|(_, h)| h.as_str()).collect::<Vec<_>>().join(" › "), text: String::new() };
        }
        current.text.push_str(line);
        current.text.push('\n');
    }
    if !current.text.trim().is_empty() {
        cut.push(current);
    }

    let tags = note.list("tags");
    if !tags.is_empty() {
        let line = format!("tags: {}\n", tags.join(", "));
        match cut.first_mut() {
            Some(first) => first.text.insert_str(0, &line),
            None => cut.push(Section { heading: String::new(), text: line }),
        }
    }
    if cut.is_empty() {
        return vec![Section { heading: String::new(), text: title(path) }];
    }

    // A short section joins the one after it, keeping its own heading.
    let mut joined: Vec<Section> = Vec::new();
    for section in cut {
        match joined.last_mut() {
            Some(last) if last.text.trim().chars().count() < MIN_SECTION => last.text.push_str(&section.text),
            _ => joined.push(section),
        }
    }
    joined.into_iter().flat_map(split).collect()
}

/// A section over MAX_SECTION, split between paragraphs (or, for one long paragraph, anywhere).
fn split(section: Section) -> Vec<Section> {
    if section.text.chars().count() <= MAX_SECTION {
        return vec![section];
    }
    let mut pieces: Vec<String> = Vec::new();
    let mut piece = String::new();
    for paragraph in section.text.split_inclusive("\n\n") {
        if !piece.is_empty() && piece.chars().count() + paragraph.chars().count() > MAX_SECTION {
            pieces.push(std::mem::take(&mut piece));
        }
        piece.push_str(paragraph);
        while piece.chars().count() > MAX_SECTION {
            let at = piece.char_indices().nth(MAX_SECTION).map_or(piece.len(), |(i, _)| i);
            let rest = piece.split_off(at);
            pieces.push(std::mem::replace(&mut piece, rest));
        }
    }
    if !piece.trim().is_empty() {
        pieces.push(piece);
    }
    pieces.into_iter().map(|text| Section { heading: section.heading.clone(), text }).collect()
}

/// A note's name: its file name without ".md".
fn title(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.strip_suffix(".md").unwrap_or(name).to_string()
}

/// Whether a note is in one of the excluded folders (or below it).
fn excluded(path: &str, folders: &[String]) -> bool {
    folders.iter().any(|f| path.strip_prefix(f.as_str()).is_some_and(|rest| rest.starts_with('/')))
}

/// Every folder a note is in, outermost first: "Worlds/Vantle/Skerry.md" is in "Worlds" and "Worlds/Vantle".
fn folders(path: &str) -> Vec<String> {
    let parts: Vec<&str> = path.split('/').collect();
    (1..parts.len()).map(|n| parts[..n].join("/")).collect()
}

/// A section's point id: the same note and place always get the same one, so syncs that overlap agree. 63 bits, as
/// some JSON readers lose the 64th.
fn point_id(path: &str, section: usize) -> u64 {
    let digest = Sha256::digest(format!("{path}\n{section}").as_bytes());
    u64::from_be_bytes(digest[..8].try_into().unwrap()) >> 1
}

// EmbeddingGemma's own prompts for retrieval.
fn query_text(query: &str) -> String {
    format!("task: search result | query: {query}")
}

fn document_text(path: &str, section: &Section) -> String {
    let title = if section.heading.is_empty() { title(path) } else { format!("{} › {}", title(path), section.heading) };
    format!("title: {title} | text: {}", section.text.trim())
}

// ---- keyword vectors (as in the memory server's index.rs)

const STOP_WORDS: &[&str] = &[
    "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been", "being",
    "but", "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her", "here", "him",
    "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "me", "more", "my", "no", "not", "now", "of",
    "on", "one", "or", "our", "out", "she", "so", "some", "than", "that", "the", "their", "them", "then", "there",
    "these", "they", "this", "to", "too", "up", "us", "very", "was", "we", "were", "what", "when", "where", "which",
    "who", "why", "will", "with", "would", "you", "your",
];

/// Lowercase words without stop words, with plurals folded ("fans" → "fan").
fn tokens(text: &str) -> Vec<String> {
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

/// BM25's term-frequency part for a section (k1 1.2, b 0.75, a typical length of 150 words).
fn document_words(text: &str) -> (Vec<u32>, Vec<f32>) {
    let words = tokens(text);
    let length = words.len().max(1) as f32;
    let mut counts: BTreeMap<u32, f32> = BTreeMap::new();
    for w in &words {
        *counts.entry(term(w)).or_default() += 1.0;
    }
    let norm = 1.2 * (0.25 + 0.75 * length / 150.0);
    counts.into_iter().map(|(t, tf)| (t, tf * 2.2 / (tf + norm))).unzip()
}

/// A query weighs each of its words once.
fn query_words(text: &str) -> (Vec<u32>, Vec<f32>) {
    let mut terms: Vec<u32> = tokens(text).iter().map(|w| term(w)).collect();
    terms.sort_unstable();
    terms.dedup();
    let values = vec![1.0; terms.len()];
    (terms, values)
}

// ---- keeping the index in step

/// Syncs, then again whenever a note changes (events settle for five seconds) and at least hourly. While nabu or
/// Qdrant is down, it retries each minute.
pub fn watch(library: &Library, index: &Index) -> Result<()> {
    use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode};
    let (tx, rx) = std::sync::mpsc::channel();
    let mut debouncer = new_debouncer(Duration::from_secs(5), tx)?;
    // Watching first, so nothing saved during the first sync is missed.
    debouncer.watcher().watch(&library.root, RecursiveMode::Recursive)?;
    let mut due = true;
    loop {
        if due {
            match index.sync(library, None) {
                Ok(s) => {
                    if s.embedded + s.dropped > 0 {
                        eprintln!("notes: embedded {} notes ({} sections), dropped {}", s.embedded, s.sections, s.dropped);
                    }
                    due = false;
                }
                Err(e) => eprintln!("notes: syncing the index failed, retrying in a minute: {e:#}"),
            }
        }
        let wait = if due { Duration::from_secs(60) } else { Duration::from_secs(3600) };
        match rx.recv_timeout(wait) {
            Ok(Ok(events)) => due |= events.iter().any(|e| is_note_change(&library.root, &e.path)),
            Ok(Err(e)) => eprintln!("notes: watching the vault: {e}"),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => due = true,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => bail!("the vault watcher stopped"),
        }
    }
}

/// A visible Markdown file (or a folder, which may have been moved with notes in it), not Obsidian's own files.
fn is_note_change(root: &std::path::Path, path: &std::path::Path) -> bool {
    let Ok(rel) = path.strip_prefix(root) else { return false };
    if rel.components().any(|c| c.as_os_str().to_string_lossy().starts_with('.')) {
        return false;
    }
    let name = rel.to_string_lossy();
    name.ends_with(".md") || path.extension().is_none()
}

#[cfg(test)]
#[path = "meaning_tests.rs"]
mod tests;
