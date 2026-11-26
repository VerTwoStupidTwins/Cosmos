//! A read-only MCP server over the homelab's observability stack on lugh: Prometheus metrics, Alertmanager's firing
//! alerts and Loki's logs from every host. It only reads, from services on localhost, and shapes the answers to be
//! short enough for a model to reason over.

mod shape;

use std::time::Duration;

use anyhow::{Context, Result, bail};
use chrono::Utc;
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

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "http://127.0.0.1:9090")]
    prometheus: String,
    #[arg(long, default_value = "http://127.0.0.1:9093")]
    alertmanager: String,
    #[arg(long, default_value = "http://127.0.0.1:3100")]
    loki: String,
}

fn ok(value: Value) -> CallToolResult {
    CallToolResult::structured(value)
}

fn or_error(result: Result<Value>) -> CallToolResult {
    result.map_or_else(|e| ok(json!({ "error": format!("{e:#}") })), ok)
}

#[derive(Clone)]
struct Observe {
    args: std::sync::Arc<Args>,
    http: reqwest::Client,
    tool_router: ToolRouter<Self>,
}

impl Observe {
    async fn get(&self, url: String, query: &[(&str, String)]) -> Result<Value> {
        let response = self.http.get(&url).query(query).send().await.with_context(|| format!("can't reach {url}"))?;
        let status = response.status();
        let body: Value = response.json().await.with_context(|| format!("{url} answered {status} without JSON"))?;
        if !status.is_success() {
            bail!("{status}: {}", body["error"].as_str().unwrap_or(&body.to_string()));
        }
        Ok(body)
    }

    async fn prometheus(&self, path: &str, query: &[(&str, String)]) -> Result<Value> {
        let body = self.get(format!("{}/api/v1/{path}", self.args.prometheus), query).await?;
        Ok(body["data"].clone())
    }
}

#[derive(Deserialize, schemars::JsonSchema)]
struct QueryRequest {
    /// A PromQL expression, such as `node_hwmon_temp_celsius{host="nabu"}` or
    /// `100 * (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes)`. Every series has a `host` label.
    query: String,
}

fn default_range() -> String {
    "6h".into()
}

#[derive(Deserialize, schemars::JsonSchema)]
struct RangeRequest {
    /// A PromQL expression.
    query: String,
    /// How far back, such as 30m, 6h, 2d (up to 90d).
    #[serde(default = "default_range")]
    range: String,
}

fn default_since() -> String {
    "1h".into()
}
fn default_limit() -> i64 {
    100
}

#[derive(Deserialize, schemars::JsonSchema)]
struct LogsRequest {
    /// A LogQL query. Streams have the labels host, unit (such as nginx.service), level and identifier. For example
    /// `{host="lugh", unit="hermes-agent.service"}` or `{host="nabu"} |~ "(?i)error|fail"`.
    query: String,
    /// How far back, such as 30m, 6h, 2d (up to 30d).
    #[serde(default = "default_since")]
    since: String,
    /// The most lines to return (the newest), up to 200.
    #[serde(default = "default_limit")]
    limit: i64,
}

#[tool_router]
impl Observe {
    /// The current value of a PromQL expression across the homelab's hosts (lugh, nabu, tenjin): temperatures, disk
    /// use, memory, GPU power, scrape health. Returns up to 50 series.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn query(&self, Parameters(req): Parameters<QueryRequest>) -> CallToolResult {
        or_error(async { shape::instant(&self.prometheus("query", &[("query", req.query)]).await?) }.await)
    }

    /// How a PromQL expression behaved over a time range, summarised per series as first, last, min, max and mean.
    /// Use it for trends: "is the disk filling", "how hot did the GPUs get today".
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn query_range(&self, Parameters(req): Parameters<RangeRequest>) -> CallToolResult {
        or_error(
            async {
                let range = shape::parse_duration(&req.range)?.min(90 * 86400);
                let end = Utc::now().timestamp();
                // About 200 points, never finer than the 30-second scrape interval.
                let step = (range / 200).max(30);
                let data = self
                    .prometheus(
                        "query_range",
                        &[
                            ("query", req.query),
                            ("start", (end - range).to_string()),
                            ("end", end.to_string()),
                            ("step", step.to_string()),
                        ],
                    )
                    .await?;
                let mut out = shape::summarise_range(&data)?;
                out["range"] = json!(req.range);
                out["step_seconds"] = json!(step);
                Ok(out)
            }
            .await,
        )
    }

    /// The alerts firing now (not silenced), with their labels, summary and how long they've been firing.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn alerts(&self) -> CallToolResult {
        or_error(
            async {
                let url = format!("{}/api/v2/alerts", self.args.alertmanager);
                let list = self
                    .get(url, &[("active", "true".into()), ("silenced", "false".into()), ("inhibited", "false".into())])
                    .await?;
                Ok(shape::alerts(&list, Utc::now()))
            }
            .await,
        )
    }

    /// Every target Prometheus scrapes (exporters on each host, HTTPS and ping probes), unhealthy ones first, with the
    /// last scrape error.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn targets(&self) -> CallToolResult {
        or_error(async { Ok(shape::targets(&self.prometheus("targets", &[("state", "active".into())]).await?)) }.await)
    }

    /// Log lines from any host's journal, collected in Loki: the newest matches of a LogQL query, oldest first.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn logs(&self, Parameters(req): Parameters<LogsRequest>) -> CallToolResult {
        or_error(
            async {
                let since = shape::parse_duration(&req.since)?.min(30 * 86400);
                let limit = req.limit.clamp(1, 200) as usize;
                let end = Utc::now().timestamp();
                let url = format!("{}/loki/api/v1/query_range", self.args.loki);
                let body = self
                    .get(
                        url,
                        &[
                            ("query", req.query),
                            ("start", format!("{}000000000", end - since)),
                            ("end", format!("{end}000000000")),
                            ("limit", limit.to_string()),
                            ("direction", "backward".into()),
                        ],
                    )
                    .await?;
                Ok(shape::log_lines(&body["data"], limit))
            }
            .await,
        )
    }

    /// Which hosts and units have logs in Loki over the last day, to build `logs` queries from.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn log_streams(&self) -> CallToolResult {
        or_error(
            async {
                let end = Utc::now().timestamp();
                let url = format!("{}/loki/api/v1/series", self.args.loki);
                let body = self
                    .get(
                        url,
                        &[
                            ("match[]", r#"{host=~".+"}"#.into()),
                            ("start", format!("{}000000000", end - 86400)),
                            ("end", format!("{end}000000000")),
                        ],
                    )
                    .await?;
                Ok(shape::streams(&body["data"]))
            }
            .await,
        )
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Observe {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("observe", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Read-only metrics, alerts and logs for the whole homelab, collected on lugh. alerts says what's \
                 firing, targets what can't be scraped, query and query_range read Prometheus (every series has a \
                 host label), and logs reads any host's journal through Loki (log_streams lists hosts and units). \
                 Nothing here can change anything.",
            )
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let http = reqwest::Client::builder().timeout(Duration::from_secs(30)).build()?;
    let observe = Observe { args: std::sync::Arc::new(args), http, tool_router: Observe::tool_router() };
    observe.serve(stdio()).await?.waiting().await?;
    Ok(())
}
