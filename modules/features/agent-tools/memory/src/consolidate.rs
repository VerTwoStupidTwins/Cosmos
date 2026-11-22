//! Consolidation: when a conversation goes quiet, the helper model reads the session's exchanges with the items they
//! touch and returns topic summaries and item changes. Everything it writes, and the mark that the session is done,
//! is one transaction, so a retry after a crash does nothing twice.

use std::collections::{BTreeSet, HashSet};

use anyhow::Result;
use serde_json::{Value, json};

use crate::App;
use crate::models::item_text;
use crate::store::{KINDS, Patch, Point, STATUSES, Store, has_status};

const PROMPT: &str = include_str!("consolidate_prompt.txt");
/// A new item this close to a kept one is the same item said again.
pub const DUPLICATE_SIMILARITY: f64 = 0.93;
/// A new item this close to a kept one of the same kind is about the same thing: it updates that one.
pub const SIMILAR_SIMILARITY: f64 = 0.80;
const MAX_EXCHANGES: i64 = 40;
const EXCHANGE_CHARS: usize = 1500;
const MAX_TOPICS: usize = 3;
const MAX_CHANGES: usize = 8;
const ITEM_CHARS: usize = 800;

fn clip(text: &str, n: usize) -> String {
    let mut out: String = text.chars().take(n).collect();
    if out.len() < text.len() {
        out.push('…');
    }
    out
}

fn schema() -> Value {
    let mut statuses: Vec<&str> = STATUSES.to_vec();
    statuses.push("none");
    json!({
        "type": "object",
        "properties": {
            "topics": { "type": "array", "items": { "type": "object", "properties": {
                "summary": { "type": "string" },
                "exchanges": { "type": "array", "items": { "type": "integer" } },
            }, "required": ["summary", "exchanges"] } },
            "changes": { "type": "array", "items": { "type": "object", "properties": {
                "action": { "enum": ["add", "update"] },
                "id": { "type": "integer" },
                "kind": { "enum": KINDS },
                "content": { "type": "string" },
                "status": { "enum": statuses },
                "links": { "type": "array", "items": { "type": "integer" } },
            }, "required": ["action", "id", "kind", "content", "status", "links"] } },
        },
        "required": ["topics", "changes"],
    })
}

#[derive(Debug, PartialEq)]
pub struct Planned {
    pub update: Option<i64>,
    pub kind: String,
    pub content: String,
    pub status: Option<String>,
    pub links: Vec<i64>,
}

/// What of the helper's answer can be used: known ids only, valid kinds and statuses, within limits.
pub fn plan(out: &Value, known: &HashSet<i64>, exchanges: &[i64]) -> (Vec<(String, Vec<i64>)>, Vec<Planned>) {
    let session: HashSet<i64> = exchanges.iter().copied().collect();
    let topics = out["topics"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|t| {
            let summary = t["summary"].as_str()?.trim();
            if summary.is_empty() {
                return None;
            }
            let mut covered: Vec<i64> =
                t["exchanges"].as_array().into_iter().flatten().filter_map(Value::as_i64).filter(|e| session.contains(e)).collect();
            if covered.is_empty() {
                covered = exchanges.to_vec();
            }
            Some((clip(summary, ITEM_CHARS), covered))
        })
        .take(MAX_TOPICS)
        .collect();
    let changes = out["changes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|c| {
            let kind = c["kind"].as_str().filter(|k| KINDS.contains(k))?;
            let content = c["content"].as_str()?.trim();
            if content.is_empty() {
                return None;
            }
            let update = match c["action"].as_str()? {
                "update" => Some(c["id"].as_i64().filter(|id| known.contains(id))?),
                "add" => None,
                _ => return None,
            };
            let status = c["status"].as_str().filter(|s| STATUSES.contains(s) && has_status(kind)).map(str::to_string);
            let links = c["links"].as_array().into_iter().flatten().filter_map(Value::as_i64).filter(|l| known.contains(l)).collect();
            Some(Planned { update, kind: kind.into(), content: clip(content, ITEM_CHARS), status, links })
        })
        .take(MAX_CHANGES)
        .collect();
    (topics, changes)
}

fn describe(p: &Point) -> String {
    let status = p.status.as_deref().map(|s| format!(", {}", s.replace('_', " "))).unwrap_or_default();
    format!("#{} {}{status} (since {}): {}", p.id, p.kind.as_deref().unwrap_or("item"), p.date(), p.content)
}

pub async fn run(app: &App, room: &str) -> Result<Value> {
    app.index_pending().await?;
    let exchanges = app.store.lock().await.unconsolidated(room, MAX_EXCHANGES)?;
    let Some(last) = exchanges.last().map(|e| e.id) else {
        return Ok(json!({ "exchanges": 0, "topics": [], "changes": 0 }));
    };
    let ids: Vec<i64> = exchanges.iter().map(|e| e.id).collect();

    // The kept items nearest to each exchange, so the helper updates instead of repeating them.
    let items_only = json!({ "must": [{ "key": "type", "match": { "value": "item" } }] });
    // Items saved or changed during the session, which the helper must check, then the kept items nearest each exchange.
    // An item saved while an answer was written predates that exchange, which is stored after the answer.
    let first = exchanges
        .first()
        .and_then(|e| chrono::DateTime::parse_from_rfc3339(&e.created).ok())
        .map(|t| (t - chrono::Duration::minutes(15)).with_timezone(&chrono::Utc).to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_default();
    let mut near: BTreeSet<i64> = app.store.lock().await.items_changed_since(&first, 10)?.into_iter().collect();
    for id in &ids {
        for (item, _) in app.qdrant.near_point(*id, &items_only, 4).await? {
            near.insert(item);
        }
        if near.len() >= 15 {
            break;
        }
    }
    let mut known_points = app.store.lock().await.get_many(&near.into_iter().collect::<Vec<_>>())?;
    let known: HashSet<i64> = known_points.iter().map(|p| p.id).collect();

    let known_text =
        if known_points.is_empty() { "(none)".to_string() } else { known_points.iter().map(describe).collect::<Vec<_>>().join("\n") };
    let session_text = exchanges
        .iter()
        .map(|e| format!("[{}] {}\n{}", e.id, e.created.replace('T', " ").trim_end_matches('Z'), clip(&e.content, EXCHANGE_CHARS)))
        .collect::<Vec<_>>()
        .join("\n\n");
    let user = format!("Known items:\n{known_text}\n\nThe session, exchange by exchange:\n\n{session_text}");
    let out = app.models.chat_json(PROMPT, &user, schema()).await?;
    let (topics, mut changes) = plan(&out, &known, &ids);

    // A new item that says what a kept one already says is dropped; one close to a kept item of the same kind is that
    // item, updated (the helper often adds where it should update, such as an idea saved during the chat).
    let mut kept = Vec::new();
    for mut c in changes.drain(..) {
        if c.update.is_none() {
            let v = app.models.embed(&[item_text(&c.kind, &c.content)]).await?.remove(0);
            if let Some((id, sim)) = app.qdrant.similar(&v, &items_only, 1).await?.first().copied() {
                if sim >= DUPLICATE_SIMILARITY {
                    eprintln!("memory: dropped a new {} that repeats #{id} ({sim:.2}): {}", c.kind, c.content);
                    continue;
                }
                let same_kind = app.store.lock().await.get(id)?.filter(|p| p.kind.as_deref() == Some(c.kind.as_str()));
                if sim >= SIMILAR_SIMILARITY && let Some(existing) = same_kind {
                    eprintln!("memory: a new {} is close to #{id} ({sim:.2}), so it updates it", c.kind);
                    c.update = Some(id);
                    c.links.retain(|l| *l != id);
                    if !known_points.iter().any(|p| p.id == id) {
                        known_points.push(existing);
                    }
                }
            }
        }
        kept.push(c);
    }

    let written = {
        let mut store = app.store.lock().await;
        let tx = store.transaction()?;
        for (summary, covered) in &topics {
            Store::insert_topic(&tx, room, summary, covered)?;
        }
        let mut written = 0;
        for c in &kept {
            match c.update {
                None => {
                    Store::create_item(&tx, &c.kind, &c.content, c.status.as_deref(), false, &c.links, Some(room), "session")?;
                    written += 1;
                }
                Some(id) => {
                    let existing = known_points.iter().find(|p| p.id == id);
                    let mut links: Vec<i64> = existing.map(|p| p.links.clone()).unwrap_or_default();
                    links.extend(c.links.iter().filter(|l| **l != id));
                    links.sort_unstable();
                    links.dedup();
                    let patch = Patch {
                        kind: Some(c.kind.clone()),
                        status: c.status.clone(),
                        core: None,
                        content: Some(c.content.clone()),
                        links: Some(links),
                    };
                    if Store::update_item(&tx, id, &patch, "session", None)?.is_some() {
                        written += 1;
                    }
                }
            }
        }
        Store::mark_consolidated(&tx, room, last)?;
        tx.commit()?;
        written
    };
    if let Err(e) = app.index_pending().await {
        eprintln!("memory: indexing after consolidation failed (retried later): {e:#}");
    }
    Ok(json!({
        "exchanges": ids.len(),
        "topics": topics.iter().map(|(s, _)| s).collect::<Vec<_>>(),
        "changes": written,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_only_what_is_valid() {
        let out = json!({
            "topics": [{ "summary": "Cooling the P100s.", "exchanges": [11, 999] }, { "summary": " ", "exchanges": [] }],
            "changes": [
                { "action": "add", "id": 0, "kind": "idea", "content": "Separate ducts per P100.", "status": "open", "links": [4, 77] },
                { "action": "update", "id": 4, "kind": "plan", "content": "Print the ducts.", "status": "in_progress", "links": [] },
                { "action": "update", "id": 55, "kind": "idea", "content": "Unknown id.", "status": "open", "links": [] },
                { "action": "add", "id": 0, "kind": "fact", "content": "nabu has two P100s.", "status": "open", "links": [] },
                { "action": "add", "id": 0, "kind": "mood", "content": "Tired.", "status": "none", "links": [] },
            ],
        });
        let known: HashSet<i64> = [4].into_iter().collect();
        let (topics, changes) = plan(&out, &known, &[11, 12]);
        assert_eq!(topics, vec![("Cooling the P100s.".to_string(), vec![11])]);
        assert_eq!(changes.len(), 3);
        assert_eq!(changes[0].links, vec![4]);
        assert_eq!(changes[1].update, Some(4));
        assert_eq!(changes[2].status, None, "a fact has no status");
    }
}
