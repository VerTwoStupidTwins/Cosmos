//! The owner's Obsidian vault on lugh (/var/lib/notes/vault, kept in step by Obsidian Sync, notes.nix).
//!
//! `notes serve` is the agent's note tools, an MCP server over stdio: list, read and search, read-only. Paths are
//! relative to the vault and never leave it. The vault's own rules for how it's organised are a note in it,
//! `Reference/How this vault works.md`.
//!
//! `notes watch` is the transcriber service: it turns each handwritten Excalidraw drawing into an inbox note.

mod library;
mod note;
mod transcribe;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use library::Library;
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, Implementation, ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Parser)]
#[command(about)]
struct Cli {
    /// The vault.
    #[arg(long, env = "NOTES", default_value = "/var/lib/notes/vault", global = true)]
    vault: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// The agent's note tools, as an MCP server over stdio.
    Serve,
    /// Transcribe drawings into inbox notes as they're exported.
    Watch {
        /// A folder of the service's own, outside the vault.
        #[arg(long, env = "STATE")]
        state: PathBuf,
        /// OpenAI-style chat completions URL.
        #[arg(long, env = "API")]
        api: String,
        #[arg(long, env = "MODEL", default_value = "vision")]
        model: String,
        /// The system prompt, as a file.
        #[arg(long, env = "PROMPT")]
        prompt: PathBuf,
        /// The text sent with each image, as a file.
        #[arg(long, env = "REQUEST")]
        request: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve => tokio::runtime::Runtime::new()?.block_on(serve(cli.vault)),
        Command::Watch { state, api, model, prompt, request } => {
            let read = |path: &PathBuf| fs::read_to_string(path).with_context(|| format!("reading {}", path.display()));
            let model = transcribe::Http::new(api, model, read(&prompt)?, read(&request)?);
            let vault = transcribe::Vault { root: cli.vault, seen: state.join("transcribed") };
            transcribe::watch(&vault, &model)
        }
    }
}

fn or_error(result: Result<Value>) -> CallToolResult {
    CallToolResult::structured(result.unwrap_or_else(|e| json!({ "error": format!("{e:#}") })))
}

#[derive(Clone)]
struct Notes {
    library: Arc<Library>,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ListRequest {
    /// A folder, relative to the vault: "" for the top, or Inbox, Daily, Ideas, Projects, Reference, Archive, or one
    /// inside them such as "Projects/Cosmos".
    #[serde(default)]
    folder: String,
    /// Include everything in its subfolders too.
    #[serde(default)]
    recursive: bool,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ReadRequest {
    /// The note: a path relative to the vault ("Ideas/Duct fan.md"; ".md" optional), or just its name ("Duct fan"),
    /// as in an Obsidian [[link]].
    note: String,
}

fn default_limit() -> usize {
    10
}

#[derive(Deserialize, schemars::JsonSchema)]
struct SearchRequest {
    /// Words to find, in any case; a note must contain all of them (in its name, properties or text).
    query: String,
    /// Only search this folder (and its subfolders); "" for the whole vault.
    #[serde(default)]
    folder: String,
    /// The most notes to return, up to 50.
    #[serde(default = "default_limit")]
    limit: usize,
}

#[tool_router]
impl Notes {
    /// What's in a folder of the owner's Obsidian vault: its subfolders, and its notes newest first with their type,
    /// status and tags. The vault's layout: Inbox (new, unfiled), Daily (YYYY-MM-DD), Ideas, Projects (a folder each),
    /// Reference, Archive, _attachments, _templates. "Reference/How this vault works" has its rules.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn list(&self, Parameters(req): Parameters<ListRequest>) -> CallToolResult {
        or_error(self.library.list(&req.folder, req.recursive))
    }

    /// One note from the owner's vault: its properties (type, status, tags, created…), its text, its #tags, the notes
    /// it links to, and the notes that link to it. Say which note you drew on when you answer from it.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn read(&self, Parameters(req): Parameters<ReadRequest>) -> CallToolResult {
        or_error(self.library.read(&req.note))
    }

    /// Find notes in the owner's vault by words (all must appear), best matches first, with the lines that match.
    /// Use it for "what did I write about…"; then read the notes that look right. Try other words, or fewer, if
    /// nothing comes up.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn search(&self, Parameters(req): Parameters<SearchRequest>) -> CallToolResult {
        or_error(self.library.search(&req.query, &req.folder, req.limit))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Notes {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("notes", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "The owner's Obsidian vault, read-only: list folders, read notes, search them. Paths are relative to \
                 the vault.",
            )
    }
}

async fn serve(vault: PathBuf) -> Result<()> {
    let notes = Notes { library: Arc::new(Library { root: vault }), tool_router: Notes::tool_router() };
    notes.serve(stdio()).await?.waiting().await?;
    Ok(())
}
