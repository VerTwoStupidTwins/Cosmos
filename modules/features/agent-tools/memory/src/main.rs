//! The homelab agent's long-term memory as an MCP server over stdio.
//!
//! SQLite (--data) holds everything: items (facts, preferences, ideas, plans…), topic summaries and past exchanges,
//! and a log of every change to an item. Qdrant on localhost indexes them for search by meaning and keywords, and is
//! rebuilt from SQLite whenever it is empty or the embedding model changes. The agent's code calls some tools itself
//! (indexing, consolidation, announcements); the model gets the rest (recall, get, list, remember, update, retract).

mod consolidate;
mod index;
mod models;
mod store;

use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, Implementation, ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::Mutex;

use index::Qdrant;
use models::{Models, document_text, item_text, query_text};
use store::{Patch, Point, Store};

#[derive(Parser)]
struct Args {
    /// The SQLite file.
    #[arg(long)]
    data: String,
    #[arg(long, default_value = "http://127.0.0.1:6333")]
    qdrant: String,
    /// Qdrant's read/write API key; default: the qdrant-api-key credential from systemd.
    #[arg(long)]
    qdrant_key_file: Option<String>,
    #[arg(long, default_value = "http://nabu.netbird.cloud:8080")]
    models: String,
    #[arg(long, default_value = "embedding")]
    embedding_model: String,
    #[arg(long, default_value = "reranker")]
    reranker_model: String,
    #[arg(long, default_value = "helper")]
    helper_model: String,
    /// The lowest reranker score auto-recall attaches to a message.
    #[arg(long, default_value_t = 0.05)]
    auto_min_score: f64,
    /// The most memories auto-recall attaches to a message.
    #[arg(long, default_value_t = 5)]
    auto_limit: usize,
    /// Serve MCP over HTTP at this address (such as 127.0.0.1:8095) as a long-running service, instead of over stdio.
    /// The service also consolidates conversations once they've gone quiet.
    #[arg(long)]
    listen: Option<std::net::SocketAddr>,
    /// How long a conversation stays quiet before the service consolidates it (with --listen).
    #[arg(long, default_value_t = 30)]
    quiet_minutes: i64,
    /// Word the instructions for Hermes (tools named memory_<tool>, changes in the evening digest) rather than for the
    /// Matrix agent.
    #[arg(long)]
    hermes: bool,
}

/// Reranker scores below these were unrelated in the old memory server's tests.
const MIN_SCORE: f64 = 0.02;
const MIN_ITEM_SCORE: f64 = 0.01;

const CORE_INSTRUCTIONS: &str = "You have a long-term memory database about the owner, their ideas and plans, and the \
homelab, built from past conversations. Memories relevant to the owner's message are attached to it inside \
<memories>: they are context from the past, not part of what the owner just wrote. When something may have come up \
before, or you need more, search with memory__recall before answering. The owner relies on memory being automatic and \
will not ask for it: each session is also reviewed after it goes quiet, but save what matters as it comes up. When \
the owner proposes an idea, decides or plans something, commits to something, or states a preference, call \
memory__remember right away, with the status their words give it (parked when they put it off, in_progress when \
they have started). When the conversation changes a kept item (an idea started, finished, dropped or put off), \
update it with memory__update. Use memory__retract when they say a memory is wrong. Never save secrets or \
lookups. Every change is announced to the owner in the Memory room. Refer to items by number (#12).";

/// The same for Hermes, whose tools are memory_<tool> and where changes go to an evening digest instead of a room.
const CORE_INSTRUCTIONS_HERMES: &str = "You have a long-term memory database about the owner, their ideas and plans, \
and the homelab, built from past conversations. Memories relevant to the owner's message are attached to it inside \
<memories>: they are context from the past, not part of what the owner just wrote. When something may have come up \
before, or you need more, search with memory_recall before answering. The owner relies on memory being automatic and \
will not ask for it: each conversation is also reviewed after it goes quiet, but save what matters as it comes up. \
When the owner proposes an idea, decides or plans something, commits to something, or states a preference, call \
memory_remember right away, with the status their words give it (parked when they put it off, in_progress when they \
have started). When the conversation changes a kept item (an idea started, finished, dropped or put off), update it \
with memory_update. Use memory_retract when they say a memory is wrong. Never save secrets or lookups. Every change \
is listed in the owner's evening memory digest; when they ask to undo one, find it with memory_changes and undo it \
with memory_undo_change. Refer to items by number (#12).";

pub struct App {
    pub store: Mutex<Store>,
    pub qdrant: Qdrant,
    pub models: Models,
    ready: Mutex<Option<String>>,
    indexing: Mutex<()>,
    args: Args,
}

fn clip(text: &str, n: usize) -> String {
    let mut out: String = text.chars().take(n).collect();
    if out.len() < text.len() {
        out.push('…');
    }
    out
}

impl App {
    /// The embedding model's name and dimensions, once the collection is made to fit them.
    async fn model_key(&self) -> Result<String> {
        let mut ready = self.ready.lock().await;
        if let Some(key) = &*ready {
            return Ok(key.clone());
        }
        let dims = self.models.embed(&[query_text("probe")]).await?.remove(0).len();
        if self.qdrant.ensure(dims).await? {
            self.store.lock().await.mark_all_unindexed()?;
        }
        let key = format!("{}@{dims}", self.models.embedding);
        *ready = Some(key.clone());
        Ok(key)
    }

    /// Brings Qdrant up to date with SQLite: new and changed points embedded, retracted ones removed.
    pub async fn index_pending(&self) -> Result<usize> {
        let key = self.model_key().await?;
        let _one_at_a_time = self.indexing.lock().await;
        let mut total = 0;
        loop {
            let points = self.store.lock().await.needs_index(&key, 32)?;
            if points.is_empty() {
                return Ok(total);
            }
            let (gone, live): (Vec<&Point>, Vec<&Point>) = points.iter().partition(|p| p.retracted);
            self.qdrant.delete(&gone.iter().map(|p| p.id).collect::<Vec<_>>()).await?;
            let vectors = self.models.embed(&live.iter().map(|p| document_text(p)).collect::<Vec<_>>()).await?;
            self.qdrant.upsert(&live.into_iter().zip(vectors).collect::<Vec<_>>()).await?;
            let done: Vec<(i64, i64)> = points.iter().map(|p| (p.id, p.version)).collect();
            self.store.lock().await.mark_indexed(&done, &key)?;
            total += points.len();
        }
    }

    /// Search by meaning and keywords, fused, then ordered by the reranker. Returns hits with their score (None when
    /// the reranker is down) and a note when something didn't work.
    async fn search(&self, query: &str, filter: &Value, rerank_top: usize) -> Result<(Vec<(Point, Option<f64>)>, Option<String>)> {
        if let Err(e) = self.index_pending().await {
            eprintln!("memory: indexing before a search failed: {e:#}");
        }
        let dense = self.models.embed(&[query_text(query)]).await?.remove(0);
        let ids = self.qdrant.hybrid(&dense, query, filter, 30).await?;
        let mut points = self.store.lock().await.get_many(&ids)?;
        points.truncate(rerank_top);
        let docs: Vec<String> = points.iter().map(|p| clip(&p.content, 1500)).collect();
        match self.models.rerank(query, &docs).await {
            Ok(scores) => {
                let mut hits: Vec<(Point, Option<f64>)> = points.into_iter().zip(scores.into_iter().map(Some)).collect();
                hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                Ok((hits, None))
            }
            Err(e) => Ok((points.into_iter().map(|p| (p, None)).collect(), Some(format!("unranked, the reranker failed: {e:#}")))),
        }
    }

    async fn write<T>(&self, f: impl FnOnce(&rusqlite::Transaction) -> Result<T>) -> Result<T> {
        let result = {
            let mut store = self.store.lock().await;
            let tx = store.transaction()?;
            let result = f(&tx)?;
            tx.commit()?;
            result
        };
        if let Err(e) = self.index_pending().await {
            eprintln!("memory: indexing failed (retried later): {e:#}");
        }
        Ok(result)
    }

    async fn change_json(&self, change: i64) -> Result<Value> {
        let c = self.store.lock().await.change(change)?.context("change vanished")?;
        Ok(json!({ "change": c.change, "item": c.item, "action": c.action, "now": c.after, "notice": c.notice_text }))
    }
}

fn hit_json(p: &Point, score: Option<f64>) -> Value {
    json!({
        "id": p.id, "type": p.kind_of, "kind": p.kind, "status": p.status, "core": p.core, "date": p.date(), "tags": p.tags,
        "content": clip(&p.content, 800), "score": score.map(|s| (s * 1000.0).round() / 1000.0),
    })
}

fn kept(p: &Point, score: Option<f64>) -> bool {
    match score {
        None => true,
        Some(s) => s >= if p.kind_of == "item" { MIN_ITEM_SCORE } else { MIN_SCORE },
    }
}

fn filter(types: &[String], kinds: &[String], statuses: &[String], since: Option<i64>, must_not: Vec<Value>) -> Value {
    let mut must = Vec::new();
    for (key, values) in [("type", types), ("kind", kinds), ("status", statuses)] {
        if !values.is_empty() {
            must.push(json!({ "key": key, "match": { "any": values } }));
        }
    }
    if let Some(since) = since {
        must.push(json!({ "key": "at", "range": { "gte": since } }));
    }
    let mut f = serde_json::Map::new();
    if !must.is_empty() {
        f.insert("must".into(), json!(must));
    }
    if !must_not.is_empty() {
        f.insert("must_not".into(), json!(must_not));
    }
    if f.is_empty() { Value::Null } else { Value::Object(f) }
}

fn days_ago(text: &str) -> Result<i64> {
    let days: i64 = text.trim().trim_end_matches('d').parse().context("since is a number of days, such as 30 or 30d")?;
    Ok(chrono::Utc::now().timestamp() - days * 86400)
}

fn ok(value: Value) -> CallToolResult {
    CallToolResult::structured(value)
}

fn or_error(result: Result<Value>) -> CallToolResult {
    result.map_or_else(|e| ok(json!({ "error": format!("{e:#}") })), ok)
}

#[derive(Clone)]
struct Memory {
    app: Arc<App>,
    tool_router: ToolRouter<Self>,
}

fn default_limit() -> usize {
    8
}

#[derive(Deserialize, schemars::JsonSchema)]
struct RecallRequest {
    /// What to look for, in words: "the duct idea for the P100s", "what did we decide about backups".
    query: String,
    /// Only these: item (facts, ideas, plans…), topic (summaries of past sessions), exchange (past messages).
    #[serde(default)]
    types: Vec<String>,
    /// Only items of these kinds: fact, preference, procedure, idea, plan, decision, commitment.
    #[serde(default)]
    kinds: Vec<String>,
    /// Only items with these statuses: open, parked, in_progress, done, dropped.
    #[serde(default)]
    statuses: Vec<String>,
    /// Only from the last this many days.
    since_days: Option<String>,
    #[serde(default = "default_limit")]
    limit: usize,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct IdRequest {
    /// The item's number.
    id: i64,
}

fn default_list_limit() -> i64 {
    50
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ListRequest {
    kind: Option<String>,
    status: Option<String>,
    /// Only core items (true) or only the others (false).
    core: Option<bool>,
    #[serde(default = "default_list_limit")]
    limit: i64,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct RememberRequest {
    /// fact, preference, procedure, idea, plan, decision or commitment.
    kind: String,
    /// One or two self-contained sentences about the owner or the homelab that make sense months later.
    content: String,
    /// For ideas, plans and commitments, from the owner's words: open (default), parked (put off, "not now", "until
    /// …"), in_progress (started), done, dropped.
    status: Option<String>,
    /// Core items are in every conversation's prompt. Only when the owner asks; keep them few.
    #[serde(default)]
    core: bool,
    /// Numbers of related items.
    #[serde(default)]
    links: Vec<i64>,
    /// Where it comes from, when that's a part of the owner's life with its own label: "campaign" and the campaign's
    /// name for D&D campaign ideas. Leave empty otherwise.
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct UpdateRequest {
    id: i64,
    /// The whole new text, if it changes.
    content: Option<String>,
    kind: Option<String>,
    status: Option<String>,
    core: Option<bool>,
    /// Replaces the item's links.
    links: Option<Vec<i64>>,
    /// Replaces the item's tags.
    tags: Option<Vec<String>>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct AutoRecallRequest {
    message: String,
    previous: Option<String>,
    /// The room the message is in: its recent exchanges are already in the conversation.
    room: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ExchangeRequest {
    room: String,
    /// The owner's Matrix event: the same event twice is stored once.
    event: String,
    message: String,
    previous: Option<String>,
    answer: String,
    /// Labels for the conversation it was in ("campaign" in a campaign chat); items made from it get them too.
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct RoomRequest {
    room: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct AnnouncedRequest {
    change: i64,
    event: String,
}

fn default_change_days() -> i64 {
    1
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ChangesRequest {
    /// How many days back: 1 (default) is the last 24 hours.
    #[serde(default = "default_change_days")]
    days: i64,
    #[serde(default = "default_list_limit")]
    limit: i64,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ChangeRequest {
    /// The change's number, from memory changes.
    change: i64,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct EventRequest {
    /// A Memory room notice's Matrix event.
    event: String,
}

#[tool_router]
impl Memory {
    /// Search the long-term memory by meaning and keywords: items (facts, preferences, ideas, plans, decisions…),
    /// summaries of past sessions, and past exchanges. Use it whenever something may have come up before.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn recall(&self, Parameters(req): Parameters<RecallRequest>) -> CallToolResult {
        or_error(
            async {
                let since = req.since_days.as_deref().map(days_ago).transpose()?;
                let f = filter(&req.types, &req.kinds, &req.statuses, since, vec![]);
                let (hits, mut note) = self.app.search(&req.query, &f, 20).await?;
                let mut shown: Vec<Value> =
                    hits.iter().filter(|(p, s)| kept(p, *s)).take(req.limit.clamp(1, 20)).map(|(p, s)| hit_json(p, *s)).collect();
                // The small reranker misses loose wording ("on hold" for "parked"): an explicit search gets its best few
                // anyway, marked weak, rather than nothing.
                if shown.is_empty() && !hits.is_empty() {
                    shown = hits.iter().take(3).map(|(p, s)| hit_json(p, *s)).collect();
                    note = Some("no strong matches; these are the closest, possibly unrelated. Try other words, or list by kind and status.".into());
                }
                Ok(json!({ "hits": shown, "note": note }))
            }
            .await,
        )
    }

    /// One item with its links and the history of its changes.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn get(&self, Parameters(req): Parameters<IdRequest>) -> CallToolResult {
        or_error(
            async {
                let store = self.app.store.lock().await;
                let p = store.get(req.id)?.with_context(|| format!("there is no #{}", req.id))?;
                let links: Vec<Value> = store.get_many(&p.links)?.iter().map(|l| hit_json(l, None)).collect();
                let history = if p.kind_of == "item" { store.history(p.id)? } else { vec![] };
                Ok(json!({ "item": p, "links": links, "history": history }))
            }
            .await,
        )
    }

    /// Kept items, newest change first, by kind, status or core.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn list(&self, Parameters(req): Parameters<ListRequest>) -> CallToolResult {
        or_error(
            async {
                let items = self.app.store.lock().await.items(req.kind.as_deref(), req.status.as_deref(), req.core, req.limit.clamp(1, 200))?;
                Ok(json!({ "items": items.iter().map(|p| hit_json(p, None)).collect::<Vec<_>>() }))
            }
            .await,
        )
    }

    /// Store a new item as soon as the owner proposes an idea, decides or plans something, commits to something or
    /// states a preference: they rely on this happening without asking. One that repeats a kept item is refused with
    /// that item's number: update it instead. Every change is announced to the owner.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn remember(&self, Parameters(req): Parameters<RememberRequest>) -> CallToolResult {
        or_error(
            async {
                let v = self.app.models.embed(&[item_text(&req.kind, &req.content)]).await?.remove(0);
                self.app.index_pending().await?;
                let items = filter(&["item".into()], &[], &[], None, vec![]);
                if let Some((id, sim)) = self.app.qdrant.similar(&v, &items, 1).await?.first()
                    && *sim >= consolidate::DUPLICATE_SIMILARITY
                {
                    return Ok(json!({ "error": format!("#{id} already says this ({sim:.2}); update it instead"), "existing": id }));
                }
                let change = self
                    .app
                    .write(|tx| Store::create_item(tx, &req.kind, &req.content, req.status.as_deref(), req.core, &req.links, &req.tags, None, "chat"))
                    .await?;
                self.app.change_json(change).await
            }
            .await,
        )
    }

    /// Change an item: its text, kind, status, core flag or links. Announced to the owner.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn update(&self, Parameters(req): Parameters<UpdateRequest>) -> CallToolResult {
        or_error(
            async {
                let patch = Patch { kind: req.kind, status: req.status, core: req.core, content: req.content, links: req.links, tags: req.tags };
                match self.app.write(|tx| Store::update_item(tx, req.id, &patch, "chat", None)).await? {
                    Some(change) => self.app.change_json(change).await,
                    None => Ok(json!({ "unchanged": req.id })),
                }
            }
            .await,
        )
    }

    /// Retract an item that is wrong or no longer wanted. It stays in the history and can be restored.
    #[tool(annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = true, open_world_hint = false))]
    async fn retract(&self, Parameters(req): Parameters<IdRequest>) -> CallToolResult {
        or_error(
            async {
                let change = self.app.write(|tx| Store::set_retracted(tx, req.id, true, "chat", None)).await?;
                self.app.change_json(change).await
            }
            .await,
        )
    }

    /// Open threads gone quiet: ideas, plans and commitments still open or parked that nobody has touched for a month,
    /// oldest first, at most 7. Each is shown once a month at most: what it returns is marked as shown.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn stale_threads(&self) -> CallToolResult {
        or_error(
            async {
                let items = self.app.store.lock().await.stale_threads(30, 30, 7)?;
                let today = chrono::Utc::now().date_naive();
                let rows: Vec<Value> = items
                    .iter()
                    .map(|p| {
                        let updated = chrono::DateTime::parse_from_rfc3339(&p.updated).map(|t| t.date_naive()).unwrap_or(today);
                        json!({ "id": p.id, "kind": p.kind, "status": p.status, "content": p.content, "since": p.date(),
                                "untouched_days": (today - updated).num_days() })
                    })
                    .collect();
                Ok(json!({ "threads": rows }))
            }
            .await,
        )
    }

    /// Recent changes to memory, oldest first, each with its number: what was saved, changed, retracted or undone, and
    /// by whom (chat, the session review, undo). For the evening digest, and to find a change the owner wants undone.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn changes(&self, Parameters(req): Parameters<ChangesRequest>) -> CallToolResult {
        or_error(
            async {
                let since = (chrono::Utc::now() - chrono::Duration::days(req.days.clamp(1, 90)))
                    .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
                let changes = self.app.store.lock().await.changes_since(&since, req.limit.clamp(1, 200))?;
                let rows: Vec<Value> = changes
                    .iter()
                    .map(|c| json!({ "change": c.change, "item": c.item, "action": c.action, "by": c.origin, "at": c.at,
                                     "undoes": c.undoes, "text": c.notice_text }))
                    .collect();
                Ok(json!({ "changes": rows }))
            }
            .await,
        )
    }

    /// Undo one change by its number, when the owner asks: a new item is retracted, a retraction restored, an edit put
    /// back. The undo is a change of its own, in the history.
    #[tool(annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn undo_change(&self, Parameters(req): Parameters<ChangeRequest>) -> CallToolResult {
        or_error(
            async {
                let undo = self.app.store.lock().await.undo(req.change)?;
                if let Err(e) = self.app.index_pending().await {
                    eprintln!("memory: indexing after an undo failed (retried later): {e:#}");
                }
                self.app.change_json(undo).await
            }
            .await,
        )
    }

    // ---- for the agent's code

    /// (Agent) Memories for an incoming message, above the auto-recall score.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn auto_recall(&self, Parameters(req): Parameters<AutoRecallRequest>) -> CallToolResult {
        or_error(
            async {
                let query = match &req.previous {
                    Some(prev) if req.message.chars().count() < 80 => format!("{}\n{}", clip(prev, 300), req.message),
                    _ => req.message.clone(),
                };
                // The room's own exchanges of the last six hours are still in the conversation.
                let mut must_not = vec![];
                if let Some(room) = &req.room {
                    must_not.push(json!({ "must": [
                        { "key": "type", "match": { "value": "exchange" } },
                        { "key": "room", "match": { "value": room } },
                        { "key": "at", "range": { "gte": chrono::Utc::now().timestamp() - 6 * 3600 } },
                    ] }));
                }
                let f = filter(&[], &[], &[], None, must_not);
                let (hits, note) = self.app.search(&query, &f, 12).await?;
                let hits: Vec<Value> = hits
                    .iter()
                    .filter(|(_, s)| s.is_some_and(|s| s >= self.app.args.auto_min_score))
                    .take(self.app.args.auto_limit)
                    .map(|(p, s)| hit_json(p, *s))
                    .collect();
                Ok(json!({ "hits": hits, "note": note }))
            }
            .await,
        )
    }

    /// (Agent) The memory prompt section: how memory works, and the core items.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn core_block(&self) -> CallToolResult {
        or_error(
            async {
                let items = self.app.store.lock().await.items(None, None, Some(true), 30)?;
                let core = if items.is_empty() {
                    "(none yet)".to_string()
                } else {
                    items.iter().map(|p| format!("- #{} ({}): {}", p.id, p.kind.as_deref().unwrap_or("item"), p.content)).collect::<Vec<_>>().join("\n")
                };
                let instructions = if self.app.args.hermes { CORE_INSTRUCTIONS_HERMES } else { CORE_INSTRUCTIONS };
                Ok(json!({ "text": format!("{instructions}\n\nCore items:\n{core}") }))
            }
            .await,
        )
    }

    /// (Agent) Store one answered exchange.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn index_exchange(&self, Parameters(req): Parameters<ExchangeRequest>) -> CallToolResult {
        or_error(
            async {
                let mut content = String::new();
                if let Some(prev) = req.previous.as_deref().filter(|p| !p.trim().is_empty()) {
                    content.push_str(&format!("(Before that, the owner said: {})\n", clip(prev, 300)));
                }
                content.push_str(&format!("Owner: {}\nAssistant: {}", clip(&req.message, 3000), clip(&req.answer, 2500)));
                let (id, new) = self.app.store.lock().await.add_exchange(&req.room, &req.event, &content, &req.tags, None)?;
                if let Err(e) = self.app.index_pending().await {
                    eprintln!("memory: indexing an exchange failed (retried later): {e:#}");
                }
                Ok(json!({ "id": id, "new": new }))
            }
            .await,
        )
    }

    /// (Agent) Turn a room's exchanges since the last consolidation into topics and item changes.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn consolidate(&self, Parameters(req): Parameters<RoomRequest>) -> CallToolResult {
        or_error(consolidate::run(&self.app, &req.room).await)
    }

    /// (Agent) What memory holds, read-only, for the owner's status page.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn status(&self) -> CallToolResult {
        or_error(async { self.app.store.lock().await.status(15) }.await)
    }

    /// (Agent) Changes not announced yet, oldest first.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn unannounced(&self) -> CallToolResult {
        or_error(async { Ok(json!({ "changes": self.app.store.lock().await.unannounced()? })) }.await)
    }

    /// (Agent) Record the notice that announced a change.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn announced(&self, Parameters(req): Parameters<AnnouncedRequest>) -> CallToolResult {
        or_error(
            async {
                self.app.store.lock().await.announced(req.change, &req.event)?;
                Ok(json!({ "ok": true }))
            }
            .await,
        )
    }

    /// (Agent) The change a Memory room notice announced, with its item now.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn notice(&self, Parameters(req): Parameters<EventRequest>) -> CallToolResult {
        or_error(
            async {
                let store = self.app.store.lock().await;
                let Some(c) = store.change_by_notice(&req.event)? else { return Ok(json!({ "change": null })) };
                let item = store.get(c.item)?;
                Ok(json!({ "change": c, "item": item }))
            }
            .await,
        )
    }

    /// (Agent) Undo the change a Memory room notice announced.
    #[tool(annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn undo(&self, Parameters(req): Parameters<EventRequest>) -> CallToolResult {
        or_error(
            async {
                let change = self.app.store.lock().await.change_by_notice(&req.event)?.context("that notice isn't a memory change")?;
                let undo = self.app.store.lock().await.undo(change.change)?;
                if let Err(e) = self.app.index_pending().await {
                    eprintln!("memory: indexing after an undo failed (retried later): {e:#}");
                }
                self.app.change_json(undo).await
            }
            .await,
        )
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Memory {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("memory", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "The owner's long-term memory: recall searches items, past session summaries and past exchanges; get \
                 and list show items; remember, update and retract change them, and every change is announced to the \
                 owner. Tools marked (Agent) are for the agent's own code.",
            )
    }
}

fn qdrant_key(args: &Args) -> Result<String> {
    let path = match &args.qdrant_key_file {
        Some(path) => path.clone(),
        None => format!("{}/qdrant-api-key", std::env::var("CREDENTIALS_DIRECTORY").context("no --qdrant-key-file or CREDENTIALS_DIRECTORY")?),
    };
    Ok(std::fs::read_to_string(&path).with_context(|| format!("reading {path}"))?.trim().to_string())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let app = Arc::new(App {
        store: Mutex::new(Store::open(&args.data)?),
        qdrant: Qdrant::new(&args.qdrant, qdrant_key(&args)?),
        models: Models::new(&args.models, &args.embedding_model, &args.reranker_model, &args.helper_model),
        ready: Mutex::new(None),
        indexing: Mutex::new(()),
        args,
    });
    // Catch up on anything left unindexed (or a wiped collection) without holding up the first call.
    let background = app.clone();
    tokio::spawn(async move {
        match background.index_pending().await {
            Ok(0) => {}
            Ok(n) => eprintln!("memory: indexed {n} points"),
            Err(e) => eprintln!("memory: indexing at start failed (retried on the next write): {e:#}"),
        }
    });
    match app.args.listen {
        None => {
            Memory { app, tool_router: Memory::tool_router() }.serve(stdio()).await?.waiting().await?;
        }
        Some(addr) => serve_http(app, addr).await?,
    }
    Ok(())
}

/// The long-running service: MCP over HTTP at /mcp, without sessions (each request stands alone, answered as JSON),
/// so Hermes and its memory plugin can both call it. Only loopback Host headers are accepted.
async fn serve_http(app: Arc<App>, addr: std::net::SocketAddr) -> Result<()> {
    use rmcp::transport::streamable_http_server::{
        StreamableHttpServerConfig, StreamableHttpService, session::never::NeverSessionManager,
    };
    tokio::spawn(consolidate_quiet(app.clone()));
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_sse_keep_alive(None);
    let service = StreamableHttpService::new(
        move || Ok(Memory { app: app.clone(), tool_router: Memory::tool_router() }),
        Arc::new(NeverSessionManager::default()),
        config,
    );
    let router = axum::Router::new().nest_service("/mcp", service);
    let listener = tokio::net::TcpListener::bind(addr).await.with_context(|| format!("binding {addr}"))?;
    eprintln!("memory: serving MCP on http://{addr}/mcp");
    axum::serve(listener, router).await?;
    Ok(())
}

/// Every five minutes, each conversation that has gone quiet (no exchange for --quiet-minutes) and has exchanges not
/// consolidated yet is turned into topics and item changes. It lives here, not in Hermes, so a restart loses nothing.
async fn consolidate_quiet(app: Arc<App>) {
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(300));
    loop {
        tick.tick().await;
        let before = (chrono::Utc::now() - chrono::Duration::minutes(app.args.quiet_minutes))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let rooms = match app.store.lock().await.quiet_rooms(&before) {
            Ok(rooms) => rooms,
            Err(e) => {
                eprintln!("memory: finding quiet conversations failed: {e:#}");
                continue;
            }
        };
        for room in rooms {
            match consolidate::run(&app, &room).await {
                Ok(result) => eprintln!("memory: consolidated {room}: {result}"),
                Err(e) => eprintln!("memory: consolidating {room} failed (tried again later): {e:#}"),
            }
        }
    }
}
