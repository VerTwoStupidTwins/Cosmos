//! Hermes' memory service: durable memories and the wiki index, in an embedded SurrealDB, behind a Unix socket.
//!
//! The Hermes plugin is its only client, and the routes and JSON match the Python service it replaces.

mod capture;
mod check;
mod db;
mod export;
mod import;
mod memory;
mod models;
mod recall;
mod wiki;

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use anyhow::{Context, Result};
use std::future::Future;
use std::pin::Pin;
use std::time::Instant;

use axum::body::Bytes;
use axum::extract::{Path as UrlPath, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::Parser;
use serde_json::{Value, json};
use tokio::net::UnixListener;

use memory::{BadRequest, Caller};

#[derive(Parser, Debug, Clone)]
struct Args {
    /// The Unix socket to listen on.
    #[arg(long, required_unless_present_any = ["import", "check"])]
    socket: Option<PathBuf>,
    /// Check the database for anything half-written or inconsistent, then exit (1 if anything is wrong).
    #[arg(long)]
    check: bool,
    /// Import memories from this JSON file into an empty database, then exit.
    #[arg(long)]
    import: Option<PathBuf>,
    /// The database directory.
    #[arg(long)]
    data: PathBuf,
    #[arg(long, default_value = "http://127.0.0.1:8080")]
    llama_swap_url: String,
    #[arg(long, required_unless_present_any = ["import", "check"])]
    wiki: Option<PathBuf>,
    /// Inside the wiki; never indexed.
    #[arg(long, required_unless_present_any = ["import", "check"])]
    export_dir: Option<PathBuf>,
    #[arg(long, default_value = "embedding")]
    embedding_model: String,
    #[arg(long, default_value = "reranker")]
    reranker_model: String,
    #[arg(long, default_value = "helper")]
    capture_model: String,
    /// Where nightly SurrealQL backups go. Without it there are none.
    #[arg(long)]
    backup_dir: Option<PathBuf>,
}

#[derive(Clone)]
pub struct App {
    pub db: db::Database,
    pub models: models::Models,
    pub wiki: PathBuf,
    pub export_dir: PathBuf,
    /// When the wiki files were last compared with the index. Holding it also keeps two syncs from overlapping.
    pub wiki_checked: std::sync::Arc<tokio::sync::Mutex<Option<Instant>>>,
    /// Wakes the capture loop when a turn arrives.
    pub capture_wake: std::sync::Arc<tokio::sync::Notify>,
    /// Bumped by each change; an export runs only if no later change arrived while it waited.
    pub export_ticket: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub backup_dir: Option<PathBuf>,
}

impl App {
    pub fn new(db: db::Database, models: models::Models, wiki: PathBuf, export_dir: PathBuf, backup_dir: Option<PathBuf>) -> Self {
        App {
            db,
            models,
            wiki,
            export_dir,
            backup_dir,
            wiki_checked: Default::default(),
            capture_wake: Default::default(),
            export_ticket: Default::default(),
        }
    }

    pub fn schedule_export(&self) {
        export::schedule(self);
    }
}

fn limit(body: &Value, default: i64, max: i64) -> usize {
    body["limit"].as_i64().unwrap_or(default).clamp(1, max) as usize
}

fn flag(body: &Value, key: &str, default: bool) -> bool {
    body[key].as_bool().unwrap_or(default)
}

fn query(body: &Value) -> anyhow::Result<String> {
    match &body["query"] {
        Value::String(q) => Ok(q.clone()),
        Value::Null => Err(memory::bad("'query' is missing")),
        other => Ok(other.to_string()),
    }
}

type Reply = Pin<Box<dyn Future<Output = anyhow::Result<Value>> + Send>>;

/// The POST routes, by path. Each takes the request body.
fn route(app: &App, path: &str, body: Value) -> Option<Reply> {
    let app = app.clone();
    Some(match path {
        "remember" => Box::pin(async move {
            let out = memory::remember(&app.db, &app.models, &body, &Caller::from_body(&body), "stated").await?;
            app.schedule_export();
            Ok(out)
        }),
        "revise" => Box::pin(async move {
            let out = memory::revise(&app.db, &app.models, &body, &Caller::from_body(&body), "stated").await?;
            app.schedule_export();
            Ok(out)
        }),
        "observe" => Box::pin(async move { capture::observe(&app, &body, &Caller::from_body(&body)).await }),
        "export" => Box::pin(async move {
            export::export(&app).await?;
            Ok(json!({"status": "exported"}))
        }),
        "backup" => Box::pin(async move { Ok(json!({"status": "backed up", "path": export::backup(&app).await?})) }),
        "list" => Box::pin(async move { memory::list(&app.db, &body, &Caller::from_body(&body)).await }),
        "recall" => Box::pin(async move {
            let search = recall::Search {
                query: query(&body)?,
                limit: limit(&body, 8, 25),
                memories: true,
                wiki: flag(&body, "include_wiki", true),
                include_past: flag(&body, "include_past", false),
                include_deprecated: false,
            };
            recall::search(&app, search, &Caller::from_body(&body)).await
        }),
        "wiki/search" => Box::pin(async move {
            let search = recall::Search {
                query: query(&body)?,
                limit: limit(&body, 6, 20),
                memories: false,
                wiki: true,
                include_past: false,
                include_deprecated: flag(&body, "include_deprecated", false),
            };
            recall::search(&app, search, &Caller::from_body(&body)).await
        }),
        "wiki/related" => Box::pin(async move { wiki::related(&app, &body).await }),
        _ => return None,
    })
}

async fn post_route(State(app): State<App>, UrlPath(path): UrlPath<String>, body: Bytes) -> impl IntoResponse {
    let started = Instant::now();
    let parsed: Result<Value, _> = if body.is_empty() { Ok(json!({})) } else { serde_json::from_slice(&body) };
    let (status, reply) = match parsed {
        Err(e) => (StatusCode::BAD_REQUEST, json!({"error": format!("Bad request: {e}")})),
        Ok(body) => match route(&app, &path, body) {
            None => (StatusCode::NOT_FOUND, json!({"error": "not found"})),
            Some(reply) => match reply.await {
                Ok(v) => (StatusCode::OK, v),
                Err(e) if e.downcast_ref::<BadRequest>().is_some() => {
                    (StatusCode::BAD_REQUEST, json!({"error": format!("Bad request: {e}")}))
                }
                Err(e) => {
                    tracing::error!("/{path} failed: {e:#}");
                    (StatusCode::INTERNAL_SERVER_ERROR, json!({"error": format!("{e:#}")}))
                }
            },
        },
    };
    // Never logs what was asked or stored.
    tracing::info!("/{path} {} in {:.2}s", status.as_u16(), started.elapsed().as_secs_f64());
    (status, Json(reply))
}

async fn health(State(app): State<App>) -> impl IntoResponse {
    let counts = db::run(
        &app.db,
        "RETURN count(SELECT id FROM memory WHERE valid_until = NONE);
         RETURN count(SELECT id FROM observation);",
        vec![],
    )
    .await;
    match counts {
        Ok(c) => (StatusCode::OK, Json(json!({"status": "ok", "memories": c[0], "turns_waiting": c[1]}))),
        Err(e) => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({"status": "error", "error": e.to_string()}))),
    }
}

fn main() -> Result<()> {
    // SurrealDB's query engine recurses deeply, and the default 2 MB thread stack can overflow.
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_stack_size(16 * 1024 * 1024)
        .build()?
        .block_on(serve())
}

async fn serve() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .without_time()
        .init();
    let args = Args::parse();
    let database = db::open(&args.data).await?;
    let models = models::Models::llama_swap(&args.llama_swap_url, &args.embedding_model, &args.reranker_model, &args.capture_model);
    if let Some(file) = &args.import {
        let data: Value = serde_json::from_slice(&std::fs::read(file)?).context("reading the import file")?;
        let summary = import::import(&database, &models, &data).await;
        database.shutdown().await?;
        tracing::info!("{}", summary?);
        return Ok(());
    }
    if args.check {
        let result = check::check(&database).await;
        database.shutdown().await?;
        let (problems, summary) = result?;
        println!("{summary}");
        for p in &problems {
            println!("PROBLEM: {p}");
        }
        if !problems.is_empty() {
            std::process::exit(1);
        }
        println!("ok");
        return Ok(());
    }
    let socket = args.socket.clone().expect("clap requires --socket");
    let wiki = args.wiki.clone().expect("clap requires --wiki");
    let export_dir = args.export_dir.clone().expect("clap requires --export-dir");
    let app = App::new(database.clone(), models, wiki, export_dir, args.backup_dir.clone());
    let startup = app.clone();
    tokio::spawn(async move {
        match wiki::sync(&startup, true).await {
            Ok(n) => tracing::info!("wiki index: {n} page(s) changed"),
            Err(e) => tracing::error!("wiki sync failed: {e:#}"),
        }
        if let Err(e) = export::export(&startup).await {
            tracing::error!("export failed: {e:#}");
        }
    });
    tokio::spawn(capture::run(app.clone()));
    tokio::spawn(export::nightly(app.clone()));

    let router = Router::new()
        .route("/health", get(health))
        .route("/{*path}", post(post_route))
        .with_state(app);

    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).with_context(|| format!("binding {}", socket.display()))?;
    // Hermes runs as the same user. The hermes group, which twins is in, may connect too.
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o660))?;
    tracing::info!("listening on {}", socket.display());
    axum::serve(listener, router).with_graceful_shutdown(stop_signal()).await?;
    // Lets SurrealDB finish its background work and flush, so the next start opens a clean database.
    database.shutdown().await?;
    let _ = std::fs::remove_file(&socket);
    tracing::info!("stopped");
    Ok(())
}

/// systemd stops services with SIGTERM; Ctrl-C sends SIGINT.
async fn stop_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("installing the SIGTERM handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod memory_tests;

#[cfg(test)]
mod recall_tests;

#[cfg(test)]
mod capture_tests;

#[cfg(test)]
mod migrate_tests;
