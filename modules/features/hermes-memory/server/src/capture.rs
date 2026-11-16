//! Capture: the helper model reads each finished chat turn in the background and keeps what the owner
//! revealed about themselves. Turns wait in the database, so a restart or a busy helper loses none.

use std::time::Duration;

use anyhow::{Context, Result};
use serde_json::{Value, json};

use crate::App;
use crate::db;
use crate::memory::{self, Caller};
use crate::models;

const CAPTURE_PROMPT: &str = include_str!("capture_prompt.txt");
pub const CAPTURE_KINDS: [&str; 4] = ["fact", "preference", "procedure", "event"];
/// Known memories shown to the helper, so it replaces or skips instead of repeating them.
const CAPTURE_CONTEXT: usize = 8;
const CAPTURE_MAX_MEMORIES: usize = 5;
const CAPTURE_ATTEMPTS: i64 = 3;
/// Long pastes are cut; the start of a message is where people say things about themselves.
const CAPTURE_USER_CHARS: usize = 6000;
const CAPTURE_REPLY_CHARS: usize = 3000;

fn cut(text: &str, n: usize) -> String {
    text.chars().take(n).collect()
}

/// Queues a finished turn for capture.
pub async fn observe(app: &App, body: &Value, caller: &Caller) -> Result<Value> {
    let text = |key: &str| match &body[key] {
        Value::Null => String::new(),
        Value::String(s) => s.trim().to_string(),
        other => other.to_string(),
    };
    let user = text("user_message");
    if user.is_empty() {
        return Ok(json!({"status": "skipped"}));
    }
    db::run(
        &app.db,
        "CREATE observation CONTENT { platform: $platform, remote: $remote, session_id: $session_id ?? NONE,
             user_message: $user, assistant_response: $reply };",
        vec![
            ("platform", json!(caller.platform)),
            ("remote", json!(caller.remote)),
            ("session_id", json!(caller.session_id)),
            ("user", json!(cut(&user, CAPTURE_USER_CHARS))),
            ("reply", json!(cut(&text("assistant_response"), CAPTURE_REPLY_CHARS))),
        ],
    )
    .await?;
    app.capture_wake.notify_one();
    Ok(json!({"status": "queued"}))
}

/// Replacing is only offered for the memories shown, and always names one of them.
pub fn capture_schema(known_ids: &[i64]) -> Value {
    let common = json!({
        "kind": {"type": "string", "enum": CAPTURE_KINDS},
        "content": {"type": "string"},
        "importance": {"type": "integer", "minimum": 1, "maximum": 5},
    });
    let with = |extra: Value| {
        let mut props = extra;
        for (k, v) in common.as_object().unwrap() {
            props[k] = v.clone();
        }
        props
    };
    let add = json!({
        "type": "object",
        "properties": with(json!({"action": {"const": "add"}})),
        "required": ["action", "kind", "content", "importance"],
    });
    let items = if known_ids.is_empty() {
        add
    } else {
        let mut ids = known_ids.to_vec();
        ids.sort();
        json!({"anyOf": [add, {
            "type": "object",
            "properties": with(json!({"action": {"const": "replace"}, "replaces": {"type": "integer", "enum": ids}})),
            "required": ["action", "replaces", "kind", "content", "importance"],
        }]})
    };
    json!({
        "type": "object",
        "properties": {"memories": {"type": "array", "maxItems": CAPTURE_MAX_MEMORIES, "items": items}},
        "required": ["memories"],
    })
}

/// The current memories closest to a turn that its chat may see, so a local-only detail never
/// turns up in a memory that chat can show.
async fn capture_context(app: &App, text: &str, caller: &Caller) -> Result<Vec<Value>> {
    let vec = app.models.embed_one(models::query_text(&cut(text, 2000))).await?;
    let (vis, mut params) = memory::visibility(caller, false);
    params.push(("q", json!(vec)));
    params.push(("n", json!(CAPTURE_CONTEXT)));
    db::rows(
        &app.db,
        &format!(
            "SELECT record::id(id) AS id, kind, content, vector::similarity::cosine(embedding, $q) AS s
             FROM memory WHERE {vis} ORDER BY s DESC LIMIT $n"
        ),
        params,
    )
    .await
}

/// What the helper model would keep from one turn, as add/replace items.
async fn extract(app: &App, obs: &Value, known: &[Value]) -> Result<Vec<Value>> {
    let known_text = if known.is_empty() {
        "(none)".to_string()
    } else {
        known
            .iter()
            .map(|m| format!("#{} ({}) {}", m["id"], m["kind"].as_str().unwrap_or(""), m["content"].as_str().unwrap_or("")))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let reply = obs["assistant_response"].as_str().filter(|s| !s.is_empty()).unwrap_or("(no reply)");
    // The labels keep the reply as context, so the model stops storing what only the assistant said.
    let prompt = format!(
        "Today is {}.\n\nKnown memories (already kept):\n{known_text}\n\n\
         The owner's message (the only source of new memories):\n{}\n\n\
         The assistant's reply (context only):\n{reply}",
        chrono::Local::now().date_naive(),
        obs["user_message"].as_str().unwrap_or(""),
    );
    let ids: Vec<i64> = known.iter().filter_map(|m| m["id"].as_i64()).collect();
    let out = app
        .models
        .chat(json!({
            "messages": [{"role": "system", "content": CAPTURE_PROMPT}, {"role": "user", "content": prompt}],
            "temperature": 0.2,
            "max_tokens": 800,
            "response_format": {"type": "json_schema", "json_schema": {"name": "memories", "schema": capture_schema(&ids)}},
        }))
        .await?;
    let content = out["choices"][0]["message"]["content"].as_str().context("the helper returned no message")?;
    let parsed: Value = serde_json::from_str(content).context("the helper's answer isn't JSON")?;
    let mut items = parsed["memories"].as_array().cloned().unwrap_or_default();
    items.truncate(CAPTURE_MAX_MEMORIES);
    Ok(items)
}

/// Stores the helper's items as inferred memories and returns how many changed something.
pub async fn apply(app: &App, items: &[Value], known_ids: &[i64], caller: &Caller) -> Result<usize> {
    let mut saved = 0;
    for item in items {
        let content = item["content"].as_str().map(str::trim).unwrap_or("");
        let kind = item["kind"].as_str().unwrap_or("");
        if content.is_empty() || !CAPTURE_KINDS.contains(&kind) {
            continue;
        }
        let replaces = item["replaces"].as_i64().filter(|id| known_ids.contains(id));
        let result = match (item["action"].as_str(), replaces) {
            (Some("replace"), Some(id)) => {
                let body = json!({"id": id, "action": "replace", "content": content, "reason": "the owner said it changed"});
                memory::revise(&app.db, &app.models, &body, caller, "inferred").await?
            }
            _ => {
                let body = json!({"kind": kind, "content": content, "importance": item["importance"].as_i64().unwrap_or(3)});
                memory::remember(&app.db, &app.models, &body, caller, "inferred").await?
            }
        };
        if matches!(result["status"].as_str(), Some("saved" | "replaced")) {
            saved += 1;
        }
    }
    if saved > 0 {
        app.schedule_export();
    }
    Ok(saved)
}

async fn capture_one(app: &App, obs: &Value) -> Result<usize> {
    let caller = Caller {
        platform: obs["platform"].as_str().unwrap_or("unknown").to_string(),
        remote: obs["remote"].as_bool().unwrap_or(true),
        session_id: obs["session_id"].as_str().map(str::to_string),
        actor: "hermes/capture".into(),
    };
    let known = capture_context(app, obs["user_message"].as_str().unwrap_or(""), &caller).await?;
    let known_ids: Vec<i64> = known.iter().filter_map(|m| m["id"].as_i64()).collect();
    let items = extract(app, obs, &known).await?;
    apply(app, &items, &known_ids, &caller).await
}

/// Works through waiting turns, oldest first. Woken by /observe, and checks every minute anyway.
pub async fn run(app: App) {
    loop {
        let _ = tokio::time::timeout(Duration::from_secs(60), app.capture_wake.notified()).await;
        loop {
            let next = db::rows(
                &app.db,
                "SELECT *, record::id(id) AS key FROM observation WHERE attempts < $max ORDER BY received_at LIMIT 1",
                vec![("max", json!(CAPTURE_ATTEMPTS))],
            )
            .await;
            let obs = match next {
                Ok(rows) => match rows.into_iter().next() {
                    Some(o) => o,
                    None => break,
                },
                Err(e) => {
                    tracing::error!("capture: reading the queue failed: {e:#}");
                    break;
                }
            };
            let id = obs["key"].clone();
            match capture_one(&app, &obs).await {
                Ok(saved) => {
                    let _ = db::run(&app.db, "DELETE type::record('observation', $id);", vec![("id", id)]).await;
                    tracing::info!("capture: a turn gave {saved} memory change(s)");
                }
                Err(e) => {
                    let attempts = db::run(
                        &app.db,
                        "RETURN (UPDATE ONLY type::record('observation', $id) SET attempts += 1).attempts;",
                        vec![("id", id.clone())],
                    )
                    .await
                    .ok()
                    .and_then(|r| r[0].as_i64())
                    .unwrap_or(CAPTURE_ATTEMPTS);
                    if attempts >= CAPTURE_ATTEMPTS {
                        let _ = db::run(&app.db, "DELETE type::record('observation', $id);", vec![("id", id)]).await;
                    }
                    tracing::warn!("capture: a turn failed (attempt {attempts}): {}", cut(&format!("{e:#}"), 300));
                    if attempts < CAPTURE_ATTEMPTS {
                        // Most failures are the helper model being busy or reloading.
                        tokio::time::sleep(Duration::from_secs(30)).await;
                        break;
                    }
                }
            }
        }
    }
}
