//! Memories: storing, revising and listing them, with what each caller may see.

use anyhow::{Result, anyhow};
use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone};
use serde_json::{Value, json};

use crate::db::{self, Database};
use crate::models::{self, Models};

pub const KINDS: [&str; 5] = ["fact", "preference", "procedure", "event", "commitment"];
/// Inferred memories rank below what the owner stated or confirmed.
pub const INFERRED_CONFIDENCE: f64 = 0.7;
/// A new memory this close to an existing one is the same memory said again.
pub const DUPLICATE_SIMILARITY: f64 = 0.93;
pub const SIMILAR_SIMILARITY: f64 = 0.80;

/// A request the caller got wrong. Routes answer it with 400 instead of 500.
#[derive(Debug)]
pub struct BadRequest(pub String);

impl std::fmt::Display for BadRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for BadRequest {}

pub fn bad(message: impl Into<String>) -> anyhow::Error {
    anyhow!(BadRequest(message.into()))
}

/// Who is asking, as the Hermes plugin decided.
#[derive(Clone, Debug)]
pub struct Caller {
    pub platform: String,
    pub remote: bool,
    pub session_id: Option<String>,
    pub actor: String,
}

impl Caller {
    pub fn from_body(body: &Value) -> Self {
        let ctx = &body["caller"];
        Caller {
            platform: ctx["platform"].as_str().filter(|s| !s.is_empty()).unwrap_or("unknown").to_string(),
            remote: ctx["remote"].as_bool().unwrap_or(true),
            session_id: ctx["session_id"].as_str().map(str::to_string),
            actor: ctx["actor"].as_str().filter(|s| !s.is_empty()).unwrap_or("hermes/main").to_string(),
        }
    }
}

/// SurrealQL that hides what this caller may not see, and its parameters.
pub fn visibility(caller: &Caller, include_past: bool) -> (&'static str, Vec<(&'static str, Value)>) {
    (
        "retracted = false
         AND ($past OR valid_until = NONE)
         AND (privacy = 'normal' OR !$remote)
         AND (array::len(platforms) = 0 OR platforms CONTAINS $platform)",
        vec![("past", json!(include_past)), ("remote", json!(caller.remote)), ("platform", json!(caller.platform))],
    )
}

/// The fields a memory is shown with, for SELECT.
pub const MEMORY_FIELDS: &str = "record::id(id) AS id, kind, content, origin, confirmed_at, importance, privacy,
    platforms, valid_from, valid_until, commitment, <-supersedes<-memory AS replaced_by";

/// A record id like "memory:8" as its number.
fn record_number(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.rsplit(':').next()?.trim_matches(|c| c == '`' || c == '⟨' || c == '⟩').parse().ok(),
        _ => None,
    }
}

fn local_time(value: &Value) -> Option<DateTime<Local>> {
    DateTime::parse_from_rfc3339(value.as_str()?).ok().map(|d| d.with_timezone(&Local))
}

fn iso_local(value: &Value) -> Option<String> {
    local_time(value).map(|d| d.format("%Y-%m-%dT%H:%M:%S%:z").to_string())
}

/// A memory as the plugin receives it.
pub fn memory_json(row: &Value, score: Option<f64>) -> Value {
    let platforms = row["platforms"].as_array().cloned().unwrap_or_default();
    let mut out = json!({
        "source": "memory",
        "id": row["id"],
        "kind": row["kind"],
        "content": row["content"],
        "origin": row["origin"],
        "confirmed": !row["confirmed_at"].is_null(),
        "importance": row["importance"],
        "privacy": row["privacy"],
        "platforms": if platforms.is_empty() { json!(["all"]) } else { json!(platforms) },
        "since": local_time(&row["valid_from"]).map(|d| d.date_naive().to_string()),
    });
    if !row["valid_until"].is_null() {
        out["until"] = json!(local_time(&row["valid_until"]).map(|d| d.date_naive().to_string()));
        out["current"] = json!(false);
        if let Some(by) = row["replaced_by"].as_array().and_then(|a| a.first()).and_then(record_number) {
            out["replaced_by"] = json!(by);
        }
    }
    if let Some(c) = row["commitment"].as_object() {
        out["commitment"] = json!({
            "status": c.get("status"),
            "due": c.get("due_at").and_then(iso_local),
            "condition": c.get("condition").cloned().unwrap_or(Value::Null),
        });
    }
    if let Some(s) = score {
        out["score"] = json!((s * 10000.0).round() / 10000.0);
    }
    out
}

/// A due date as the owner or Hermes wrote it. A date or time without an offset is lugh's local time.
pub fn parse_due(value: &Value) -> Result<Option<String>> {
    let Some(text) = value.as_str().map(str::trim).filter(|s| !s.is_empty()) else { return Ok(None) };
    let text = text.replace('Z', "+00:00");
    if let Ok(d) = DateTime::parse_from_rfc3339(&text) {
        return Ok(Some(d.to_rfc3339()));
    }
    let naive = ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"]
        .iter()
        .find_map(|f| NaiveDateTime::parse_from_str(&text, f).ok())
        .or_else(|| NaiveDate::parse_from_str(&text, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)));
    let naive = naive.ok_or_else(|| bad(format!("due isn't an ISO 8601 date: {text}")))?;
    let local = Local.from_local_datetime(&naive).earliest().ok_or_else(|| bad("due falls in a clock change"))?;
    Ok(Some(local.to_rfc3339()))
}

fn clean_platforms(value: &Value) -> Vec<String> {
    let mut out: Vec<String> = value
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();
    out.sort();
    out.dedup();
    if out.iter().any(|p| p == "all") { vec![] } else { out }
}

fn int_field(body: &Value, key: &str, default: i64) -> Result<i64> {
    match &body[key] {
        Value::Null => Ok(default),
        Value::Number(n) => n.as_f64().map(|f| f as i64).ok_or_else(|| bad(format!("{key} isn't a number"))),
        Value::String(s) => s.trim().parse().map_err(|_| bad(format!("{key} isn't a number"))),
        _ => Err(bad(format!("{key} isn't a number"))),
    }
}

fn text_field(body: &Value, key: &str) -> Option<String> {
    body[key].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The next memory number. Numbers skipped by a failed write are never reused, as with Postgres sequences.
async fn next_id(db: &Database) -> Result<i64> {
    let out = db::run(db, "RETURN (UPSERT ONLY counter:memory SET n += 1).n;", vec![]).await?;
    out[0].as_i64().ok_or_else(|| anyhow!("the memory counter returned {}", out[0]))
}

/// SurrealQL that writes a history entry; $snap_before and $snap_after may be NONE.
const RECORD: &str = "CREATE history CONTENT { memory_id: $id, action: $action, before: $snap_before,
    after: $snap_after, actor: $actor, reason: $reason ?? NONE };";
const SNAPSHOT: &str = "(SELECT kind, content, privacy, platforms, importance, valid_until, retracted
    FROM ONLY type::record('memory', $id))";

pub struct NewMemory<'a> {
    pub kind: &'a str,
    pub content: &'a str,
    pub importance: i64,
    pub privacy: &'a str,
    pub platforms: &'a [String],
    pub origin: &'a str,
    pub due: Option<String>,
    pub condition: Option<String>,
    pub reason: Option<String>,
}

/// Writes run one at a time, as Postgres' row locks made them: each reads what it changes and then writes,
/// and two replaces of one memory must not both find it current. Writes come at the pace of a conversation.
static WRITES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Creates a memory with its source and history, and returns its number. `then` is more SurrealQL for the same
/// transaction, with `extra` parameters; $new_id is the new memory's number.
async fn insert(
    db: &Database,
    models: &Models,
    caller: &Caller,
    new: NewMemory<'_>,
    then: &str,
    extra: Vec<(&'static str, Value)>,
) -> Result<i64> {
    let vec = models.embed_one(models::memory_text(new.kind, new.content)).await?;
    let id = next_id(db).await?;
    let mut params = vec![
        ("new_id", json!(id)),
        ("kind", json!(new.kind)),
        ("content", json!(new.content)),
        ("embedding", json!(vec)),
        ("importance", json!(new.importance)),
        ("privacy", json!(new.privacy)),
        ("platforms", json!(new.platforms)),
        ("origin", json!(new.origin)),
        ("confidence", json!(if new.origin == "inferred" { INFERRED_CONFIDENCE } else { 1.0 })),
        ("platform", json!(caller.platform)),
        ("session_id", json!(caller.session_id)),
        ("due", json!(new.due)),
        ("condition", json!(new.condition)),
        ("actor", json!(caller.actor)),
        ("new_reason", json!(new.reason)),
    ];
    params.extend(extra);
    db::run(
        db,
        &format!(
            "BEGIN;
             CREATE type::record('memory', $new_id) CONTENT {{
                 kind: $kind, content: $content, embedding: $embedding, importance: $importance,
                 privacy: $privacy, platforms: $platforms, origin: $origin, confidence: $confidence,
                 sources: [{{ platform: $platform, session_id: $session_id ?? NONE, said_at: time::now() }}]
             }};
             IF $kind = 'commitment' {{
                 UPDATE type::record('memory', $new_id) SET commitment = {{ status: 'open' }};
                 IF $due != NULL {{ UPDATE type::record('memory', $new_id) SET commitment.due_at = <datetime>$due; }};
                 IF $condition != NULL {{ UPDATE type::record('memory', $new_id) SET commitment.condition = $condition; }};
             }};
             CREATE history CONTENT {{ memory_id: $new_id, action: 'create', before: NONE,
                 after: (SELECT kind, content, privacy, platforms, importance, valid_until, retracted
                         FROM ONLY type::record('memory', $new_id)),
                 actor: $actor, reason: $new_reason ?? NONE }};
             {then}
             COMMIT;"
        ),
        params,
    )
    .await?;
    Ok(id)
}

pub async fn remember(db: &Database, models: &Models, body: &Value, caller: &Caller, origin: &str) -> Result<Value> {
    let kind = body["kind"].as_str().unwrap_or("fact");
    if !KINDS.contains(&kind) {
        return Err(bad(format!("kind must be one of {}", KINDS.join(", "))));
    }
    let content = text_field(body, "content").ok_or_else(|| bad("content is empty"))?;
    let privacy = body["privacy"].as_str().unwrap_or("normal");
    if !["normal", "local_only"].contains(&privacy) {
        return Err(bad("privacy must be normal or local_only"));
    }
    let importance = int_field(body, "importance", 3)?.clamp(1, 5);
    let platforms = clean_platforms(&body["platforms"]);
    let due = parse_due(&body["due"])?;
    let condition = text_field(body, "condition");

    let _write = WRITES.lock().await;
    let vec = models.embed_one(models::memory_text(kind, &content)).await?;
    let near = db::rows(
        db,
        "SELECT record::id(id) AS id, kind, content, vector::similarity::cosine(embedding, $vec) AS similarity
         FROM memory WHERE valid_until = NONE AND retracted = false ORDER BY similarity DESC LIMIT 3",
        vec![("vec", json!(vec))],
    )
    .await?;
    let brief = |n: &Value| json!({"id": n["id"], "kind": n["kind"], "content": n["content"]});
    let similarity = |n: &Value| n["similarity"].as_f64().unwrap_or(0.0);
    if let Some(first) = near.first().filter(|n| similarity(n) >= DUPLICATE_SIMILARITY) {
        return Ok(json!({
            "status": "duplicate",
            "existing": brief(first),
            "message": "A near-identical memory already exists. Use memory_revise to change it.",
        }));
    }

    let id = insert(
        db,
        models,
        caller,
        NewMemory {
            kind,
            content: &content,
            importance,
            privacy,
            platforms: &platforms,
            origin,
            due,
            condition,
            reason: None,
        },
        "",
        vec![],
    )
    .await?;

    let mut out = json!({"status": "saved", "id": id});
    let similar: Vec<Value> = near.iter().filter(|n| similarity(n) >= SIMILAR_SIMILARITY).map(brief).collect();
    if !similar.is_empty() {
        out["similar"] = json!(similar);
        out["message"] = json!("Check these related memories. If the new one changes or contradicts one, revise it.");
    }
    Ok(out)
}

pub async fn revise(db: &Database, models: &Models, body: &Value, caller: &Caller, origin: &str) -> Result<Value> {
    let id = match &body["id"] {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().trim_start_matches('#').parse().ok(),
        _ => None,
    }
    .ok_or_else(|| bad("id must be a memory's number"))?;
    let action = body["action"].as_str().unwrap_or("");
    let reason = text_field(body, "reason");

    let _write = WRITES.lock().await;
    let (vis, mut params) = visibility(caller, true);
    params.push(("id", json!(id)));
    let current = db::rows(
        db,
        &format!("SELECT {MEMORY_FIELDS} FROM type::record('memory', $id) WHERE {vis}"),
        params,
    )
    .await?;
    let Some(current) = current.into_iter().next() else {
        return Ok(json!({"error": format!("No memory #{id} that you can change.")}));
    };
    let base = |action: &str| {
        vec![
            ("id", json!(id)),
            ("action", json!(action)),
            ("actor", json!(caller.actor)),
            ("reason", json!(reason)),
        ]
    };

    let result = match action {
        "forget" => {
            db::run(
                db,
                &format!(
                    "BEGIN;
                     DELETE type::record('memory', $id);
                     -- Earlier records keep their dates and actions but lose the forgotten content.
                     UPDATE history SET before = NONE, after = NONE WHERE memory_id = $id;
                     LET $snap_before = NONE;
                     LET $snap_after = NONE;
                     {RECORD}
                     COMMIT;"
                ),
                base("forget"),
            )
            .await?;
            json!({"status": "forgotten", "id": id})
        }
        "confirm" => {
            db::run(
                db,
                &format!(
                    "BEGIN;
                     LET $snap_before = {SNAPSHOT};
                     LET $snap_after = NONE;
                     UPDATE type::record('memory', $id) SET confirmed_at = time::now(), updated_at = time::now();
                     {RECORD}
                     COMMIT;"
                ),
                base("confirm"),
            )
            .await?;
            json!({"status": "confirmed", "id": id})
        }
        "complete" | "cancel" => {
            if current["kind"] != "commitment" {
                return Ok(json!({"error": format!("#{id} isn't a commitment.")}));
            }
            let status = if action == "complete" { "done" } else { "cancelled" };
            let mut params = base(action);
            params.push(("status", json!(status)));
            db::run(
                db,
                &format!(
                    "BEGIN;
                     LET $snap_before = {SNAPSHOT};
                     LET $snap_after = NONE;
                     UPDATE type::record('memory', $id) SET commitment.status = $status,
                         commitment.resolved_at = time::now(), valid_until = time::now(), updated_at = time::now();
                     {RECORD}
                     COMMIT;"
                ),
                params,
            )
            .await?;
            json!({"status": status, "id": id})
        }
        "replace" | "retract" => {
            if !current["valid_until"].is_null() {
                return Ok(json!({"error": format!("#{id} is no longer current, so it can't be replaced.")}));
            }
            let content = text_field(body, "content");
            if content.is_none() && action == "replace" {
                return Ok(json!({"error": "replace needs the new content."}));
            }
            let mut params = base(action);
            params.push(("retracted", json!(action == "retract")));
            // Ending the old memory goes in the same transaction as creating its replacement, so a crash
            // can't leave both current.
            let end_old = format!(
                "LET $snap_before = {SNAPSHOT};
                 IF $new_id != NONE {{
                     RELATE (type::record('memory', $new_id))->supersedes->(type::record('memory', $id));
                 }};
                 -- A retracted memory was never true, so recall leaves it out even when asked about the past.
                 UPDATE type::record('memory', $id) SET valid_until = time::now(), retracted = $retracted,
                     updated_at = time::now();
                 LET $snap_after = {SNAPSHOT};
                 {RECORD}"
            );
            let mut new_id = None;
            if let Some(content) = &content {
                let kind = current["kind"].as_str().unwrap_or("fact");
                let platforms: Vec<String> = current["platforms"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                    .unwrap_or_default();
                let old_commitment = &current["commitment"];
                let due = match parse_due(&body["due"])? {
                    Some(d) => Some(d),
                    None => old_commitment["due_at"].as_str().map(str::to_string),
                };
                let condition = text_field(body, "condition").or_else(|| old_commitment["condition"].as_str().map(str::to_string));
                new_id = Some(
                    insert(
                        db,
                        models,
                        caller,
                        NewMemory {
                            kind,
                            content,
                            importance: current["importance"].as_i64().unwrap_or(3),
                            privacy: current["privacy"].as_str().unwrap_or("normal"),
                            platforms: &platforms,
                            origin,
                            due,
                            condition,
                            reason: Some(format!("replaces #{id}")),
                        },
                        &end_old,
                        params,
                    )
                    .await?,
                );
            } else {
                db::run(db, &format!("BEGIN; LET $new_id = NONE; {end_old} COMMIT;"), params).await?;
            }
            let mut out = json!({"status": if action == "replace" { "replaced" } else { "retracted" }, "id": id});
            if let Some(n) = new_id {
                out["new_id"] = json!(n);
            }
            out
        }
        _ => return Err(bad("action must be replace, retract, confirm, complete, cancel or forget")),
    };
    Ok(result)
}

pub async fn list(db: &Database, body: &Value, caller: &Caller) -> Result<Value> {
    let kind = body["kind"].as_str();
    if let Some(k) = kind {
        if !KINDS.contains(&k) {
            return Err(bad(format!("kind must be one of {}", KINDS.join(", "))));
        }
    }
    let status = body["status"].as_str();
    let limit = int_field(body, "limit", 30)?.clamp(1, 100) as usize;
    let (vis, mut params) = visibility(caller, body["include_past"].as_bool().unwrap_or(false));
    let mut filters = String::new();
    if let Some(k) = kind {
        filters.push_str(" AND kind = $kind");
        params.push(("kind", json!(k)));
    }
    if let Some(s) = status {
        filters.push_str(" AND commitment.status = $status");
        params.push(("status", json!(s)));
    }
    let mut rows = db::rows(
        db,
        &format!("SELECT {MEMORY_FIELDS}, updated_at FROM memory WHERE {vis}{filters}"),
        params,
    )
    .await?;
    // Commitments by due date, those without one last; everything else newest first.
    rows.sort_by(|a, b| {
        let due = |r: &Value| r["commitment"]["due_at"].as_str().map(str::to_string);
        match (due(a), due(b)) {
            (Some(x), Some(y)) => x.cmp(&y),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }
        .then_with(|| b["updated_at"].as_str().cmp(&a["updated_at"].as_str()))
    });
    rows.truncate(limit);
    Ok(json!({"memories": rows.iter().map(|r| memory_json(r, None)).collect::<Vec<_>>()}))
}
