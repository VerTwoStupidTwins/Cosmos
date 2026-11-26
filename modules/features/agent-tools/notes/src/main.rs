//! The owner's Obsidian vaults on lugh (under /var/lib/notes, kept in step by Obsidian Sync, notes.nix).
//!
//! `notes serve` is the agent's note tools for one vault, an MCP server over stdio: list, read and search, and
//! (unless --read-only) create in the inbox, edit and move, never delete (write.rs). With --filing, also file the inbox
//! notes the owner accepted and delete the ones they rejected (inbox.rs). Paths are relative to the vault
//! and never leave it. Each vault keeps its own rules for how it's organised in a note.
//!
//! `notes watch` is the transcriber service: it turns each handwritten Excalidraw drawing into an inbox note.
//!
//! `notes index` keeps the vault's index for search by meaning in step with it (meaning.rs); with --qdrant, `serve`
//! searches that index too.

mod inbox;
mod library;
mod meaning;
mod note;
mod transcribe;
mod write;

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
    Serve {
        /// The folder new notes go in, relative to the vault.
        #[arg(long, default_value = "Inbox")]
        inbox: String,
        /// Read only: no create, edit or move tools.
        #[arg(long)]
        read_only: bool,
        /// New notes only: create, but no edit or move, so nothing already in the vault can be changed.
        #[arg(long)]
        create_only: bool,
        /// File reviewed inbox notes: the file_note and discard_note tools.
        #[arg(long)]
        filing: bool,
        /// Where filed notes' to-dos go, relative to the vault.
        #[arg(long, default_value = "Reference/Tasks.md")]
        tasks_note: String,
        #[command(flatten)]
        meaning: meaning::Config,
    },
    /// Keep the vault's index for search by meaning in step with it.
    Index {
        #[command(flatten)]
        meaning: meaning::Config,
    },
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
        Command::Serve { inbox, read_only, create_only, filing, tasks_note, meaning } => {
            let index = meaning::Index::new(&meaning)?.map(Arc::new);
            let filing = (filing && !read_only && !create_only).then_some(tasks_note);
            tokio::runtime::Runtime::new()?.block_on(serve(cli.vault, inbox, read_only, create_only, filing, index))
        }
        Command::Index { meaning } => {
            let index = meaning::Index::new(&meaning)?.context("--qdrant is needed")?;
            meaning::watch(&Library { root: cli.vault }, &index)
        }
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
    /// The index for search by meaning, when there is one.
    index: Option<Arc<meaning::Index>>,
    inbox: String,
    read_only: bool,
    /// The tasks note, when filing is on.
    tasks_note: Option<String>,
    // One write at a time: the model can call several tools at once, and two edits of a note mustn't interleave.
    writing: Arc<std::sync::Mutex<()>>,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ListRequest {
    /// A folder, relative to the vault: "" for the top, or one inside it such as "Inbox" or "Projects/Cosmos".
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

#[derive(Deserialize, schemars::JsonSchema)]
struct MeaningRequest {
    /// What you're looking for, in your own words: a question or a description ("how loud the server closet fan
    /// was", "who wants the harbour closed"). The exact words needn't be in the note.
    query: String,
    /// Only search this folder (and its subfolders); "" for the whole vault.
    #[serde(default)]
    folder: String,
    /// The most notes to return, up to 20.
    #[serde(default = "default_limit")]
    limit: usize,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct FileRequest {
    /// The inbox note: its path or name.
    note: String,
    /// Where it goes: folder and a clear new name, following the vault's rules ("Ideas/Quieter server fan",
    /// "Projects/Homelab/Game servers", "Reference/Ignition certification").
    to: String,
    /// idea, project or reference.
    #[serde(rename = "type")]
    kind: String,
    /// For an idea or project: open, parked, in-progress, done or dropped.
    #[serde(default)]
    status: Option<String>,
    /// Its tags, for ongoing topics (homelab, health…): the vault's existing tags where they fit. Keep "handwritten"
    /// on a transcription.
    #[serde(default)]
    tags: Vec<String>,
    /// The day it was written, YYYY-MM-DD; default: the day it was transcribed.
    #[serde(default)]
    created: Option<String>,
    /// Existing notes it relates to (paths or names), linked from it.
    #[serde(default)]
    related: Vec<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct DiscardRequest {
    /// The inbox note marked review: delete: its path or name.
    note: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct CreateRequest {
    /// The new note's name, without a folder: it goes in the vault's inbox. Names are unique across the vault.
    name: String,
    /// The whole note in Markdown, its properties (--- frontmatter ---) included, following the vault's rules and
    /// the matching template.
    content: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct EditRequest {
    /// The note: a path relative to the vault, or its name.
    note: String,
    /// The exact text to replace, copied from the note as it is now; it must appear exactly once, so include enough
    /// around it.
    old: String,
    /// What replaces it ("" to remove it).
    new: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct MoveRequest {
    /// The note: a path relative to the vault, or its name.
    note: String,
    /// Its new path relative to the vault, with its name (".md" optional): "Worlds/Vantle/Places/Skerry". Folders
    /// are made as needed. A new name renames it, and links to it follow.
    to: String,
}

impl Notes {
    /// Runs a write, unless the vault is read-only here, while no other write runs.
    fn write(&self, f: impl FnOnce(&Library) -> Result<Value>) -> CallToolResult {
        if self.read_only {
            return or_error(Err(anyhow::anyhow!("this vault is read-only here")));
        }
        let _turn = self.writing.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        or_error(f(&self.library))
    }
}

#[tool_router]
impl Notes {
    /// What's in a folder of the vault: its subfolders, and its notes newest first with their type, status and tags.
    /// The vault's rules note says how it's organised.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn list(&self, Parameters(req): Parameters<ListRequest>) -> CallToolResult {
        or_error(self.library.list(&req.folder, req.recursive))
    }

    /// One note from the vault: its properties (type, status, tags, created…), its text, its #tags, the notes it
    /// links to, and the notes that link to it. Say which note you drew on when you answer from it.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn read(&self, Parameters(req): Parameters<ReadRequest>) -> CallToolResult {
        or_error(self.library.read(&req.note))
    }

    /// Find notes in the vault by exact words (all must appear), best matches first, with the lines that match. Good
    /// for names, tags and phrases you know are there; for a topic or a question, search_by_meaning finds notes that
    /// put it in other words. Read the notes that look right.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn search(&self, Parameters(req): Parameters<SearchRequest>) -> CallToolResult {
        or_error(self.library.search(&req.query, &req.folder, req.limit))
    }

    /// Find notes about something, however they word it: by meaning, not exact words, best first. Each comes with the
    /// section that matched (and its other matching sections), an excerpt and a relevance from 0 to 1 (under about
    /// 0.1 is likely unrelated). Use it first for "what did I write about…" and questions; then read the notes that
    /// look right, and say which ones you drew on.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn search_by_meaning(&self, Parameters(req): Parameters<MeaningRequest>) -> CallToolResult {
        let (Some(index), library) = (self.index.clone(), self.library.clone()) else {
            return or_error(Err(anyhow::anyhow!("search by meaning isn't set up for this vault")));
        };
        let result = tokio::task::spawn_blocking(move || index.search(&library, &req.query, &req.folder, req.limit)).await;
        or_error(result.map_err(anyhow::Error::from).and_then(|r| r))
    }

    /// File an inbox note the owner accepted (review: accept), or one with no review mark: it gets the vault's
    /// properties, its open to-dos move into the tasks note, links to related notes are added, and it moves to its
    /// place. Its text stays as the owner wrote it. No approval needed: their accept is the approval. A note still
    /// marked pending is refused.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn file_note(&self, Parameters(req): Parameters<FileRequest>) -> CallToolResult {
        let Some(tasks) = self.tasks_note.clone() else {
            return or_error(Err(anyhow::anyhow!("filing isn't on for this vault")));
        };
        let filing = inbox::Filing {
            inbox: &self.inbox,
            tasks: &tasks,
            note: &req.note,
            to: &req.to,
            kind: req.kind.trim(),
            status: req.status.as_deref(),
            tags: &req.tags,
            created: req.created.as_deref(),
            related: &req.related,
        };
        self.write(|lib| lib.file(&filing))
    }

    /// Delete an inbox note the owner marked review: delete, with its drawing. Refused for any other note.
    #[tool(annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn discard_note(&self, Parameters(req): Parameters<DiscardRequest>) -> CallToolResult {
        if self.tasks_note.is_none() {
            return or_error(Err(anyhow::anyhow!("filing isn't on for this vault")));
        }
        self.write(|lib| lib.discard(&self.inbox, &req.note))
    }

    /// Write a new note into the vault's inbox, or the folder this server files new notes in (never over an existing
    /// one). Read the vault's rules and the
    /// matching template first, and fill the template in rather than copying it. Give the owner the note's name.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn create(&self, Parameters(req): Parameters<CreateRequest>) -> CallToolResult {
        self.write(|lib| lib.create(&self.inbox, &req.name, &req.content))
    }

    /// Change a note by replacing one exact piece of its text. Read the note first and copy the text exactly. The
    /// owner sees the change and approves it before it's made.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn edit(&self, Parameters(req): Parameters<EditRequest>) -> CallToolResult {
        self.write(|lib| lib.edit(&req.note, &req.old, &req.new))
    }

    /// Move or rename a note (out of the inbox into its place, or into the archive: nothing is ever deleted). Links
    /// to it are fixed. The owner approves it before it's made.
    #[tool(name = "move", annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn move_note(&self, Parameters(req): Parameters<MoveRequest>) -> CallToolResult {
        self.write(|lib| lib.move_note(&req.note, &req.to))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Notes {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("notes", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "An Obsidian vault: list folders, read notes, search them by words or by meaning, write new notes into \
                 its inbox, edit and move notes. Paths are relative to the vault. Nothing is ever deleted.",
            )
    }
}

async fn serve(
    vault: PathBuf,
    inbox: String,
    read_only: bool,
    create_only: bool,
    tasks_note: Option<String>,
    index: Option<Arc<meaning::Index>>,
) -> Result<()> {
    let mut tool_router = Notes::tool_router();
    if create_only {
        tool_router.remove_route("edit");
        tool_router.remove_route("move");
    }
    if index.is_none() {
        tool_router.remove_route("search_by_meaning");
    }
    if tasks_note.is_none() {
        tool_router.remove_route("file_note");
        tool_router.remove_route("discard_note");
    }
    let notes =
        Notes { library: Arc::new(Library { root: vault }), index, inbox, read_only, tasks_note, writing: Arc::default(), tool_router };
    notes.serve(stdio()).await?.waiting().await?;
    Ok(())
}
