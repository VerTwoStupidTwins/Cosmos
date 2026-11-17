//! A read-only MCP server that reports lugh's health to Hermes and lets it look up lugh's NixOS config.
//!
//! The health tools read status from /proc, /sys, systemd, the journal, llama-swap and the memory service. The
//! config tools read the commit lugh was built from and the copy of the config that commit holds. None of them
//! runs a shell or changes anything, and logs come only from listed services.

mod edits;
mod http;
mod probes;
mod repo;

use std::collections::BTreeMap;

use anyhow::Result;
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

use probes::{Config, safely};

#[derive(Parser)]
struct Args {
    #[arg(long)]
    llama_server: String,
    #[arg(long)]
    systemctl: String,
    #[arg(long)]
    journalctl: String,
    #[arg(long)]
    llama_swap_url: String,
    #[arg(long)]
    memory_socket: String,
    /// Services to watch, comma-separated.
    #[arg(long)]
    units: String,
    /// Mount points to watch, comma-separated.
    #[arg(long)]
    disks: String,
    /// Models that should always be loaded, comma-separated.
    #[arg(long)]
    always_loaded: String,
    /// JSON object of card short name to role.
    #[arg(long)]
    roles: String,
    /// A file holding the commit the running system was built from.
    #[arg(long)]
    revision_file: String,
    /// A directory holding the config the running system was built from.
    #[arg(long)]
    config_source: String,
    /// A JSON file naming the files the config manages in Hermes' home, and where switches save Hermes' edits.
    #[arg(long)]
    managed_files: String,
}

fn list(s: &str) -> Vec<String> {
    s.split(',').filter(|x| !x.is_empty()).map(str::to_owned).collect()
}

fn ok(value: Value) -> CallToolResult {
    CallToolResult::structured(value)
}

fn error(message: impl std::fmt::Display) -> CallToolResult {
    ok(json!({ "error": format!("{message:#}") }))
}

fn or_error(result: Result<Value>) -> CallToolResult {
    result.map_or_else(error, ok)
}

#[derive(Clone)]
struct Monitor {
    cfg: Config,
    tool_router: ToolRouter<Self>,
}

fn default_lines() -> i64 {
    50
}
fn default_priority() -> String {
    "warning".into()
}
fn default_hours() -> i64 {
    24
}

#[derive(Deserialize, schemars::JsonSchema)]
struct LogsRequest {
    /// One of the services service_status lists.
    unit: String,
    /// How many of the newest lines to return, up to 200.
    #[serde(default = "default_lines")]
    lines: i64,
    /// The least severe level to include: err, warning or info.
    #[serde(default = "default_priority")]
    priority: String,
    /// How far back to look, in hours, up to 168.
    #[serde(default = "default_hours")]
    hours: i64,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct FilesRequest {
    /// A directory inside the config, such as modules/features. Leave it empty for everything.
    #[serde(default)]
    path: String,
}

fn default_max_results() -> i64 {
    50
}
fn default_true() -> bool {
    true
}

#[derive(Deserialize, schemars::JsonSchema)]
struct SearchRequest {
    /// A regular expression to look for, line by line, such as `B50` or `port = \d+`.
    pattern: String,
    /// Only search under this file or directory, such as modules/features. Leave it empty for everything.
    #[serde(default)]
    path: String,
    /// Match regardless of case.
    #[serde(default = "default_true")]
    ignore_case: bool,
    /// The most matching lines to return, up to 200.
    #[serde(default = "default_max_results")]
    max_results: i64,
}

fn default_start() -> i64 {
    1
}
fn default_read_lines() -> i64 {
    200
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ReadRequest {
    /// A file inside the config, such as modules/features/llm.nix.
    path: String,
    /// The first line to show, counting from 1.
    #[serde(default = "default_start")]
    start_line: i64,
    /// How many lines to show, up to 500.
    #[serde(default = "default_read_lines")]
    lines: i64,
}

fn clamp(n: i64, max: usize) -> usize {
    n.clamp(1, max as i64) as usize
}

#[tool_router]
impl Monitor {
    // ---- health

    /// Uptime, load, memory, CPU and NVMe temperatures, disk usage, and when lugh was last rebuilt and from which commit.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn system_status(&self) -> CallToolResult {
        ok(safely(probes::system_info(&self.cfg)).await)
    }

    /// Each GPU's role, free and total memory, temperatures and power draw.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn gpu_status(&self) -> CallToolResult {
        ok(json!({ "gpus": safely(probes::gpu_info(&self.cfg)).await }))
    }

    /// The models llama-swap has loaded, and any that should always be loaded but aren't.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn model_status(&self) -> CallToolResult {
        ok(safely(probes::model_info(&self.cfg)).await)
    }

    /// The state, restart count and last-24-hour error count of lugh's key services, and any failed unit.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn service_status(&self) -> CallToolResult {
        ok(safely(probes::services_info(&self.cfg)).await)
    }

    /// Recent log lines from one of lugh's key services.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn service_logs(&self, Parameters(req): Parameters<LogsRequest>) -> CallToolResult {
        if !self.cfg.units.contains(&req.unit) {
            return error(format!("Unknown unit. Choose one of: {}", self.cfg.units.join(", ")));
        }
        if !["err", "warning", "info"].contains(&req.priority.as_str()) {
            return error("priority must be err, warning or info");
        }
        let (lines, hours) = (clamp(req.lines, 200), clamp(req.hours, 168) as u32);
        or_error(
            probes::journal(&self.cfg, &req.unit, &req.priority, hours, Some(lines), "short-iso")
                .await
                .map(|l| json!({ "unit": req.unit, "lines": l })),
        )
    }

    /// Whether the memory service answers, and how many memories it holds.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn memory_status(&self) -> CallToolResult {
        ok(safely(probes::memory_info(&self.cfg)).await)
    }

    /// Every check at once, with a list of anything that needs attention. Use this for a daily health summary.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn health_report(&self) -> CallToolResult {
        ok(probes::health_report(&self.cfg).await)
    }

    /// Edits Hermes made to files the NixOS config manages, such as the llm-wiki skill: ones made since the last
    /// switch, and ones saved before a switch replaced them. Both need bringing into the repo to last.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn hermes_edits(&self) -> CallToolResult {
        or_error(edits::edits(&self.cfg.managed_files, &self.cfg.config_source))
    }

    // ---- config

    /// The commit of the Cosmos repository lugh's running system was built from, and whether it had uncommitted changes.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn deployed_revision(&self) -> CallToolResult {
        ok(repo::deployed_revision(&self.cfg.revision_file, &self.cfg.config_source))
    }

    /// The files in lugh's running NixOS config, optionally under one directory.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_files(&self, Parameters(req): Parameters<FilesRequest>) -> CallToolResult {
        or_error(repo::list(&self.cfg.config_source, &req.path))
    }

    /// Searches lugh's running NixOS config line by line. Comments in it explain why things are set up the way they are.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_search(&self, Parameters(req): Parameters<SearchRequest>) -> CallToolResult {
        let max = clamp(req.max_results, repo::MAX_MATCHES);
        or_error(repo::search(&self.cfg.config_source, &req.pattern, &req.path, req.ignore_case, max))
    }

    /// Reads part of one file of lugh's running NixOS config, with line numbers.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_read(&self, Parameters(req): Parameters<ReadRequest>) -> CallToolResult {
        let start = req.start_line.max(1) as usize;
        or_error(repo::read(&self.cfg.config_source, &req.path, start, clamp(req.lines, repo::MAX_READ_LINES)))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Monitor {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("lugh-monitor", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Read-only checks for lugh, the server Hermes runs on. Use health_report for a summary and the other \
                 health tools for detail. To explain why lugh is set up a certain way, or what it's configured to \
                 do, use config_search and config_read on its NixOS config: the comments there give the reasons. \
                 deployed_revision says which commit is running. Nothing here can change the system.",
            )
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let roles: BTreeMap<String, String> = serde_json::from_str(&args.roles)?;
    let monitor = Monitor {
        cfg: Config {
            llama_server: args.llama_server,
            systemctl: args.systemctl,
            journalctl: args.journalctl,
            llama_swap_url: args.llama_swap_url,
            memory_socket: args.memory_socket,
            units: list(&args.units),
            disks: list(&args.disks),
            always_loaded: list(&args.always_loaded),
            roles,
            revision_file: args.revision_file,
            config_source: args.config_source,
            managed_files: args.managed_files,
        },
        tool_router: Monitor::tool_router(),
    };
    monitor.serve(stdio()).await?.waiting().await?;
    Ok(())
}
