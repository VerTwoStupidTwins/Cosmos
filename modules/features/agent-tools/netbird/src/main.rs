//! A read-only MCP server over the NetBird mesh's access settings: who may reach what (policies), which peers are in
//! each group, each peer's address and whether it's connected, and how all that differs from what the repo declares.
//! The token belongs to the CosmosAuditor service user (Auditor role: NetBird refuses its writes), so this can only
//! look.

mod access;

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::Parser;
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, Implementation, ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::json;

const API: &str = "https://api.netbird.io/api";

#[derive(Parser)]
struct Args {
    /// A file holding the read-only API token.
    #[arg(long)]
    token_file: PathBuf,
    /// modules/netbird-policies.nix as JSON, for the drift view.
    #[arg(long)]
    declared: Option<PathBuf>,
}

#[derive(Deserialize, schemars::JsonSchema, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum View {
    /// Who may reach what: source group -> destination group, protocol, ports.
    Policies,
    /// Which peers are in each group.
    Groups,
    /// Each device's NetBird IP, DNS name, whether it's connected, its groups.
    Peers,
    /// The live settings checked against the repo's (modules/netbird-policies.nix).
    Drift,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct AccessRequest {
    view: View,
}

#[derive(Clone)]
struct Netbird {
    args: std::sync::Arc<Args>,
    agent: ureq::Agent,
    tool_router: ToolRouter<Self>,
}

impl Netbird {
    fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        // Read on every call, so a renewed token (same sops key) works without a restart.
        let token = std::fs::read_to_string(&self.args.token_file)
            .with_context(|| format!("reading the token in {}", self.args.token_file.display()))?;
        match self
            .agent
            .get(&format!("{API}/{path}"))
            .set("authorization", &format!("Token {}", token.trim()))
            .set("accept", "application/json")
            .call()
        {
            Ok(response) => response
                .into_json()
                .with_context(|| format!("NetBird's {path} wasn't the JSON expected")),
            Err(ureq::Error::Status(401, _)) => {
                bail!("NetBird refused the token (expired? it was due 2027-11-22)")
            }
            Err(ureq::Error::Status(code, _)) => bail!("NetBird API {path}: {code}"),
            Err(e) => Err(e).with_context(|| format!("can't reach NetBird's API ({path})")),
        }
    }

    fn view(&self, view: View) -> Result<String> {
        Ok(match view {
            View::Policies => access::policies(&self.get::<Vec<access::Policy>>("policies")?),
            View::Groups => access::groups(&self.get::<Vec<access::Group>>("groups")?),
            View::Peers => access::peers(&self.get::<Vec<access::Peer>>("peers")?),
            View::Drift => {
                let file = self
                    .args
                    .declared
                    .as_ref()
                    .context("the repo's NetBird declaration wasn't given")?;
                let raw = std::fs::read_to_string(file)
                    .with_context(|| format!("reading {}", file.display()))?;
                let declared: access::Declared =
                    serde_json::from_str(&raw).context("the repo's declaration")?;
                access::drift(
                    &declared,
                    &self.get::<Vec<_>>("policies")?,
                    &self.get::<Vec<_>>("groups")?,
                    &self.get::<Vec<_>>("peers")?,
                )
            }
        })
    }
}

#[tool_router]
impl Netbird {
    /// The NetBird mesh's live access settings (read-only). `policies`: who may reach what (NetBird drops anything no
    /// policy allows). `groups`: which peers are in each group. `peers`: each device's NetBird IP, DNS name, whether
    /// it's connected and its groups. `drift`: the live settings checked against the repo's declared ones
    /// (modules/netbird-policies.nix): missing, extra or changed policies, groups and peer addresses. Use it for who or
    /// what can reach a host or service over NetBird; the homelab map has the declared policies with their reasons.
    #[tool(annotations(
        read_only_hint = true,
        destructive_hint = false,
        idempotent_hint = true,
        open_world_hint = true
    ))]
    async fn access(&self, Parameters(req): Parameters<AccessRequest>) -> CallToolResult {
        let this = self.clone();
        let result = tokio::task::spawn_blocking(move || this.view(req.view)).await;
        CallToolResult::structured(match result.map_err(anyhow::Error::from).and_then(|r| r) {
            Ok(text) => json!({ "view": text }),
            Err(e) => json!({ "error": format!("{e:#}") }),
        })
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Netbird {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("netbird", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "The NetBird mesh's access settings, read-only: policies, groups, peers, and drift from the repo. \
                 Nothing here can change anything.",
            )
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(20))
        .build();
    let netbird = Netbird {
        args: std::sync::Arc::new(args),
        agent,
        tool_router: Netbird::tool_router(),
    };
    netbird.serve(stdio()).await?.waiting().await?;
    Ok(())
}
