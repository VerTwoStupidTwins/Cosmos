//! A one-time import of memories from JSON, keeping their numbers, replacement links and history.
//! dump-postgres.sql writes this file from the Python service's database. A memory without an embedding is
//! embedded again with the same model.
//!
//! {"memories": [{"id": 12, "kind": "fact", "content": "...", ...}], "history": [{"memory_id": 12, ...}],
//!  "observations": [...], "last_id": 13}
//! Fields other than id, kind and content are optional and take the schema's defaults.

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::db::{self, Database};
use crate::models::{self, Models};

/// Fields copied as they are when present.
const PLAIN: [&str; 7] = ["origin", "confidence", "importance", "privacy", "platforms", "retracted", "recall_count"];
/// Datetimes, cast from their text.
const TIMES: [&str; 6] = ["valid_from", "valid_until", "confirmed_at", "created_at", "updated_at", "last_recalled_at"];

fn present(v: &Value) -> bool {
    !v.is_null()
}

pub async fn import(db: &Database, models: &Models, data: &Value) -> Result<String> {
    let existing = db::run(db, "RETURN count(SELECT id FROM memory);", vec![]).await?;
    if existing[0].as_i64().unwrap_or(0) > 0 {
        bail!("the database already holds memories; import only into an empty one");
    }
    let memories = data["memories"].as_array().context("no 'memories' list")?;
    let missing: Vec<usize> = (0..memories.len()).filter(|&i| !memories[i]["embedding"].is_array()).collect();
    let texts: Vec<String> = missing
        .iter()
        .map(|&i| &memories[i])
        .map(|m| models::memory_text(m["kind"].as_str().unwrap_or("fact"), m["content"].as_str().unwrap_or("")))
        .collect();
    let mut made = if texts.is_empty() { vec![] } else { models.embed(&texts).await? }.into_iter();
    let vectors: Vec<Value> = memories
        .iter()
        .map(|m| if m["embedding"].is_array() { m["embedding"].clone() } else { json!(made.next()) })
        .collect();

    let mut max_id = 0;
    for (m, vector) in memories.iter().zip(vectors) {
        let id = m["id"].as_i64().context("a memory without an id")?;
        max_id = max_id.max(id);
        let mut content = json!({"kind": m["kind"], "content": m["content"], "embedding": vector});
        for key in PLAIN {
            if present(&m[key]) {
                content[key] = m[key].clone();
            }
        }
        db::run(
            db,
            "CREATE type::record('memory', $id) CONTENT $content;",
            vec![("id", json!(id)), ("content", content)],
        )
        .await
        .with_context(|| format!("memory #{id}"))?;
        for key in TIMES.into_iter().filter(|k| present(&m[*k])) {
            db::run(
                db,
                &format!("UPDATE type::record('memory', $id) SET {key} = <datetime>$t;"),
                vec![("id", json!(id)), ("t", m[key].clone())],
            )
            .await
            .with_context(|| format!("memory #{id}: {key}"))?;
        }
        for source in m["sources"].as_array().into_iter().flatten() {
            db::run(
                db,
                "UPDATE type::record('memory', $id) SET sources += {
                     platform: $s.platform ?? NONE, session_id: $s.session_id ?? NONE,
                     said_at: IF $s.said_at = NULL OR $s.said_at = NONE { time::now() } ELSE { <datetime>$s.said_at } };",
                vec![("id", json!(id)), ("s", source.clone())],
            )
            .await
            .with_context(|| format!("memory #{id}: sources"))?;
        }
        let c = &m["commitment"];
        if c.is_object() {
            db::run(
                db,
                "UPDATE type::record('memory', $id) SET commitment = { status: $c.status ?? 'open' };
                 IF $c.due_at != NULL AND $c.due_at != NONE { UPDATE type::record('memory', $id) SET commitment.due_at = <datetime>$c.due_at; };
                 IF $c.condition != NULL AND $c.condition != NONE { UPDATE type::record('memory', $id) SET commitment.condition = $c.condition; };
                 IF $c.resolved_at != NULL AND $c.resolved_at != NONE { UPDATE type::record('memory', $id) SET commitment.resolved_at = <datetime>$c.resolved_at; };",
                vec![("id", json!(id)), ("c", c.clone())],
            )
            .await
            .with_context(|| format!("memory #{id}: commitment"))?;
        }
    }
    let mut links = 0;
    for m in memories {
        if let (Some(old), Some(new)) = (m["id"].as_i64(), m["superseded_by"].as_i64()) {
            db::run(
                db,
                "RELATE (type::record('memory', $new))->supersedes->(type::record('memory', $old));",
                vec![("new", json!(new)), ("old", json!(old))],
            )
            .await
            .with_context(|| format!("link #{new} -> #{old}"))?;
            links += 1;
        }
    }
    let history = data["history"].as_array().cloned().unwrap_or_default();
    for h in &history {
        db::run(
            db,
            "CREATE history CONTENT { memory_id: $h.memory_id, action: $h.action, before: $h.before ?? NONE,
                 after: $h.after ?? NONE, actor: $h.actor ?? 'imported', reason: $h.reason ?? NONE,
                 at: IF $h.at = NULL OR $h.at = NONE { time::now() } ELSE { <datetime>$h.at } };",
            vec![("h", h.clone())],
        )
        .await
        .context("a history entry")?;
    }
    let observations = data["observations"].as_array().cloned().unwrap_or_default();
    for o in &observations {
        db::run(
            db,
            "CREATE observation CONTENT { platform: $o.platform, remote: $o.remote, session_id: $o.session_id ?? NONE,
                 user_message: $o.user_message, assistant_response: $o.assistant_response ?? '',
                 received_at: <datetime>$o.received_at, attempts: $o.attempts ?? 0 };",
            vec![("o", o.clone())],
        )
        .await
        .context("a waiting turn")?;
    }
    // New memories continue after the highest number ever given, so none is reused.
    let last = max_id.max(data["last_id"].as_i64().unwrap_or(0));
    db::run(db, "UPSERT counter:memory SET n = $n;", vec![("n", json!(last))]).await?;
    Ok(format!(
        "imported {} memories ({} embedded again), {links} replacement links, {} history entries and {} waiting \
         turns; next number {}",
        memories.len(),
        missing.len(),
        history.len(),
        observations.len(),
        last + 1
    ))
}
