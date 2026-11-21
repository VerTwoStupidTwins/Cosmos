//! A read-only MCP server that reports a homelab host's health and lets clients look up the host's NixOS config.
//!
//! The health tools read status from /proc, /sys, systemd and the journal. The config tools read the commit the host
//! was built from and the copy of the config that commit holds. None of them runs a shell or changes anything, and
//! logs come only from listed services. tenjin's homelab plate runs it over SSH for health_report.

mod drift;
mod hardware;
mod manifest;
mod probes;
mod repo;

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
    /// The host's name.
    #[arg(long)]
    host: String,
    #[arg(long)]
    systemctl: String,
    #[arg(long)]
    journalctl: String,
    /// A file holding the commit the running system was built from.
    #[arg(long)]
    revision_file: String,
    /// A directory holding the config the running system was built from.
    #[arg(long)]
    config_source: String,
    /// A JSON file of what the running system should be running, written by Nix.
    #[arg(long)]
    manifest: String,
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
    host: String,
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
    /// A file inside the config, such as modules/features/monitor.nix.
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

    /// Uptime, load, memory, CPU and NVMe temperatures, disk usage, and when the host was last rebuilt and from which commit.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn system_status(&self) -> CallToolResult {
        ok(safely(probes::system_info(&self.cfg)).await)
    }

    /// Trouble below the services: kernel faults, hardware errors, storage errors, out-of-memory kills and crashed
    /// processes since boot and in the previous boot, whether the previous boot shut down cleanly, btrfs error
    /// counters, and NVMe health.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn hardware_status(&self) -> CallToolResult {
        ok(safely(hardware::hardware_info(&self.cfg)).await)
    }

    /// The state, restart count and last-24-hour error count of the host's key services, and any failed unit.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn service_status(&self) -> CallToolResult {
        ok(safely(probes::services_info(&self.cfg)).await)
    }

    /// Recent log lines from one of the host's key services.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn service_logs(&self, Parameters(req): Parameters<LogsRequest>) -> CallToolResult {
        let units = match self.cfg.manifest() {
            Ok(m) => m.units,
            Err(e) => return error(e),
        };
        if !units.contains(&req.unit) {
            return error(format!("Unknown unit. Choose one of: {}", units.join(", ")));
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

    /// Every check at once, with a list of anything that needs attention. Use this for a daily health summary.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn health_report(&self) -> CallToolResult {
        ok(probes::health_report(&self.cfg).await)
    }

    /// Whether the host runs what its config declares beyond its services: every declared port listening.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_drift(&self) -> CallToolResult {
        match self.cfg.manifest() {
            Ok(m) => or_error(drift::drift(&m).await),
            Err(e) => error(e),
        }
    }

    // ---- config

    /// The commit of the Cosmos repository the host's running system was built from, and whether it had uncommitted changes.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn deployed_revision(&self) -> CallToolResult {
        ok(repo::deployed_revision(&self.cfg.revision_file, &self.cfg.config_source))
    }

    /// The files in the host's running NixOS config, optionally under one directory.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_files(&self, Parameters(req): Parameters<FilesRequest>) -> CallToolResult {
        or_error(repo::list(&self.cfg.config_source, &req.path))
    }

    /// Searches the host's running NixOS config line by line. Comments in it explain why things are set up the way they are.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_search(&self, Parameters(req): Parameters<SearchRequest>) -> CallToolResult {
        let max = clamp(req.max_results, repo::MAX_MATCHES);
        or_error(repo::search(&self.cfg.config_source, &req.pattern, &req.path, req.ignore_case, max))
    }

    /// Reads part of one file of the host's running NixOS config, with line numbers.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn config_read(&self, Parameters(req): Parameters<ReadRequest>) -> CallToolResult {
        let start = req.start_line.max(1) as usize;
        or_error(repo::read(&self.cfg.config_source, &req.path, start, clamp(req.lines, repo::MAX_READ_LINES)))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Monitor {
    fn get_info(&self) -> ServerConfig {
        let host = &self.host;
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new(format!("{host}-monitor"), env!("CARGO_PKG_VERSION")))
            .with_instructions(format!(
                "Read-only checks for {host}. Use health_report for a summary and the other health tools for \
                 detail. To explain why {host} is set up a certain way, or what it's configured to do, use \
                 config_search and config_read on its NixOS config: the comments there give the reasons. \
                 deployed_revision says which commit is running, and config_drift whether {host} runs what that \
                 config declares. Nothing here can change the system."
            ))
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let cfg = Config {
        systemctl: args.systemctl,
        journalctl: args.journalctl,
        revision_file: args.revision_file,
        config_source: args.config_source,
        manifest: args.manifest,
    };
    let monitor = Monitor { host: args.host, cfg, tool_router: Monitor::tool_router() };
    monitor.serve(stdio()).await?.waiting().await?;
    Ok(())
}
