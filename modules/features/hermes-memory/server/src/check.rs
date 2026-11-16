//! `--check`: looks for anything half-written or inconsistent, as a crash or a bad import could leave.

use anyhow::Result;
use serde_json::{Value, json};

use crate::db::{self, Database};

/// Problems found, empty when the database is sound.
pub async fn check(db: &Database) -> Result<(Vec<String>, Value)> {
    let mut problems = vec![];
    let memories = db::rows(
        db,
        "SELECT record::id(id) AS id, kind, content, array::len(embedding) AS dims, valid_until, retracted,
             commitment, (<-supersedes<-memory).len() AS replacers, (->supersedes->memory).len() AS replaces
         FROM memory ORDER BY id",
        vec![],
    )
    .await?;
    let created: Vec<i64> = db::rows(db, "SELECT VALUE memory_id FROM history WHERE action = 'create'", vec![])
        .await?
        .iter()
        .filter_map(Value::as_i64)
        .collect();
    let counter = db::run(db, "RETURN (SELECT VALUE n FROM ONLY counter:memory) ?? 0;", vec![]).await?[0].as_i64().unwrap_or(0);
    let dims = memories.first().and_then(|m| m["dims"].as_i64());

    for m in &memories {
        let id = m["id"].as_i64().unwrap_or(-1);
        if id > counter {
            problems.push(format!("#{id} is above the counter ({counter}), so its number could be given again"));
        }
        if !created.contains(&id) {
            problems.push(format!("#{id} has no 'create' history entry"));
        }
        if m["dims"].as_i64() != dims || dims == Some(0) {
            problems.push(format!("#{id} has a {}-number embedding, others {dims:?}", m["dims"]));
        }
        if (m["kind"] == "commitment") != m["commitment"].is_object() {
            problems.push(format!("#{id} is a {} but its commitment details are {}", m["kind"], m["commitment"]));
        }
        if m["replacers"].as_i64().unwrap_or(0) > 1 {
            problems.push(format!("#{id} is replaced by more than one memory"));
        }
        if m["replacers"].as_i64().unwrap_or(0) > 0 && m["valid_until"].is_null() {
            problems.push(format!("#{id} was replaced but is still current"));
        }
        // The keyword index must agree with the table: each memory is found by its own longest word.
        let word = m["content"]
            .as_str()
            .unwrap_or("")
            .split(|c: char| !c.is_alphanumeric())
            .max_by_key(|w| w.len())
            .unwrap_or("")
            .to_lowercase();
        if word.len() > 3 {
            let found = db::rows(
                db,
                "SELECT VALUE record::id(id) FROM memory WHERE content @1,OR@ $w",
                vec![("w", json!(word))],
            )
            .await?;
            if !found.contains(&json!(id)) {
                problems.push(format!("#{id} isn't found by keyword search for '{word}'"));
            }
        }
    }
    let edges = db::run(
        db,
        "RETURN count(SELECT id FROM supersedes WHERE in.id = NONE OR out.id = NONE);",
        vec![],
    )
    .await?[0]
        .as_i64()
        .unwrap_or(0);
    if edges > 0 {
        problems.push(format!("{edges} replacement link(s) point at missing memories"));
    }
    let summary = db::run(
        db,
        "RETURN {
             memories: count(SELECT id FROM memory),
             current: count(SELECT id FROM memory WHERE valid_until = NONE),
             links: count(SELECT id FROM supersedes),
             history: count(SELECT id FROM history),
             turns_waiting: count(SELECT id FROM observation),
             wiki_pages: count(SELECT id FROM wiki_page),
             wiki_sections: count(SELECT id FROM wiki_chunk)
         };",
        vec![],
    )
    .await?
    .remove(0);
    let mut summary = summary;
    summary["counter"] = json!(counter);
    Ok((problems, summary))
}
