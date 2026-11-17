//! Whether lugh runs what its config declares, beyond the services and models the other checks cover: listening
//! ports, Hermes' MCP servers, the order the cards are numbered in, and cards that should hold models but don't.

use std::collections::BTreeSet;
use std::fs;
use std::time::Duration;

use anyhow::Result;
use serde_json::{Map, Value, json};

use crate::manifest::Manifest;

/// A card with an always-loaded model counts as empty below this much memory in use.
const EMPTY_CARD_MIB: i64 = 512;

/// TCP ports in the LISTEN state, from /proc/net/tcp and tcp6.
fn listening_ports() -> BTreeSet<u16> {
    ["/proc/net/tcp", "/proc/net/tcp6"]
        .iter()
        .filter_map(|f| fs::read_to_string(f).ok())
        .flat_map(|text| parse_listening(&text))
        .collect()
}

fn parse_listening(text: &str) -> Vec<u16> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            // st 0A is LISTEN. local_address is ADDRESS:PORT in hex.
            if fields.get(3) != Some(&"0A") {
                return None;
            }
            u16::from_str_radix(fields.get(1)?.rsplit(':').next()?, 16).ok()
        })
        .collect()
}

/// The program each running process was started as, and its arguments.
fn command_lines() -> Vec<Vec<String>> {
    let Ok(procs) = fs::read_dir("/proc") else { return Vec::new() };
    procs
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit()))
        .filter_map(|e| fs::read(e.path().join("cmdline")).ok())
        .filter(|raw| !raw.is_empty())
        .map(|raw| raw.split(|b| *b == 0).filter(|a| !a.is_empty()).map(|a| String::from_utf8_lossy(a).into_owned()).collect())
        .collect()
}

fn base_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Whether some process runs this MCP server. A wrapper script that execs its server, as github's does, leaves the
/// server's own name, which starts with the wrapper's.
fn server_running(command: &str, processes: &[Vec<String>]) -> bool {
    // A script written straight into the store is named after its hash, as in /nix/store/<hash>-github-mcp.
    let name = base_name(command);
    let wrapper = match name.split_once('-') {
        Some((hash, rest)) if hash.len() == 32 => rest,
        _ => name,
    };
    processes.iter().any(|argv| {
        argv.iter().any(|a| a == command) || argv.first().is_some_and(|p| base_name(p).starts_with(wrapper))
    })
}

async fn device_order(script: Option<&str>) -> Value {
    let Some(script) = script else { return json!({ "checked": false }) };
    let run = tokio::process::Command::new(script).kill_on_drop(true).output();
    match tokio::time::timeout(Duration::from_secs(90), run).await {
        Err(_) => json!({ "checked": true, "ok": false, "detail": "the check took longer than 90 seconds" }),
        Ok(Err(e)) => json!({ "checked": true, "ok": false, "detail": format!("couldn't run the check: {e}") }),
        Ok(Ok(out)) if out.status.success() => json!({ "checked": true, "ok": true }),
        Ok(Ok(out)) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let first = stderr.lines().next().unwrap_or("the check failed").to_owned();
            json!({ "checked": true, "ok": false, "detail": first })
        }
    }
}

/// Whether something accepts connections on a local port. Podman forwards a container's ports with firewall rules
/// instead of a listening socket, so /proc/net/tcp alone misses them.
async fn accepts(port: u16) -> bool {
    let connect = tokio::net::TcpStream::connect(("127.0.0.1", port));
    matches!(tokio::time::timeout(Duration::from_secs(2), connect).await, Ok(Ok(_)))
}

pub async fn drift(manifest: &Manifest) -> Result<Value> {
    let listening = listening_ports();
    let mut ports = Map::new();
    for (name, port) in &manifest.ports {
        let up = listening.contains(port) || accepts(*port).await;
        ports.insert(name.clone(), json!({ "port": port, "listening": up }));
    }

    let processes = command_lines();
    let mcp: Map<String, Value> = manifest
        .mcp_servers
        .iter()
        .map(|(name, command)| (name.clone(), json!({ "running": server_running(command, &processes) })))
        .collect();

    Ok(json!({
        "ports": ports,
        "mcp_servers": mcp,
        "card_order": device_order(manifest.check_devices.as_deref()).await,
    }))
}

/// Health report warnings for drift, including cards that should hold an always-loaded model but are nearly empty.
pub fn warnings(drift: &Value, gpus: &Value, manifest: Option<&Manifest>) -> Vec<String> {
    let mut w = Vec::new();
    if let Some(e) = drift.get("error").and_then(Value::as_str) {
        w.push(format!("Could not check lugh against its config: {e}"));
        return w;
    }
    for (name, p) in drift["ports"].as_object().into_iter().flatten() {
        if p["listening"] == false {
            w.push(format!("Nothing listens on port {} for {name}", p["port"]));
        }
    }
    for (name, s) in drift["mcp_servers"].as_object().into_iter().flatten() {
        if s["running"] == false {
            w.push(format!("Hermes' MCP server {name} isn't running"));
        }
    }
    if drift["card_order"]["ok"] == false {
        w.push(format!(
            "The cards aren't numbered the way llm.nix expects, so a model may be on the wrong card: {}",
            drift["card_order"]["detail"].as_str().unwrap_or_default()
        ));
    }
    let Some(manifest) = manifest else { return w };
    for g in gpus.as_array().into_iter().flatten() {
        let Some(short) = g["short"].as_str() else { continue };
        let Some(card) = manifest.cards.get(short) else { continue };
        let expected: Vec<&String> = card.models.iter().filter(|m| manifest.always_loaded.contains(m)).collect();
        let (Some(total), Some(free)) = (g["vram_total_mib"].as_i64(), g["vram_free_mib"].as_i64()) else { continue };
        if !expected.is_empty() && total - free < EMPTY_CARD_MIB {
            let names: Vec<&str> = expected.iter().map(|s| s.as_str()).collect();
            w.push(format!("{} has almost nothing loaded, though {} should be", card.name, names.join(", ")));
        }
    }
    w
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_listening_ports() {
        let text = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   \
                    0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000   989        0 1 1\n   \
                    1: 0100007F:22B0 0100007F:B2A4 01 00000000:00000000 00:00000000 00000000   989        0 2 1\n";
        assert_eq!(parse_listening(text), [8080]);
    }

    #[test]
    fn warns_about_drift() {
        let manifest: Manifest = serde_json::from_value(json!({
            "units": [], "ports": {}, "always_loaded": ["helper"], "check_devices": null, "mcp_servers": {}, "disks": [],
            "cards": { "B580": { "name": "Arc B580", "pci_id": "0x8086:0xe20b", "models": ["helper", "image"] } },
            "managed_files": { "home": "/h", "saved": "/s", "files": {} },
        }))
        .unwrap();
        let drift = json!({
            "ports": { "kokoro": { "port": 8880, "listening": false }, "llama-swap": { "port": 8080, "listening": true } },
            "mcp_servers": { "github": { "running": false } },
            "card_order": { "checked": true, "ok": false, "detail": "Expected B580 on SYCL1." },
        });
        let gpus = json!([{ "short": "B580", "vram_total_mib": 12216, "vram_free_mib": 12000 }]);
        assert_eq!(
            warnings(&drift, &gpus, Some(&manifest)),
            [
                "Nothing listens on port 8880 for kokoro",
                "Hermes' MCP server github isn't running",
                "The cards aren't numbered the way llm.nix expects, so a model may be on the wrong card: Expected B580 on SYCL1.",
                "Arc B580 has almost nothing loaded, though helper should be",
            ]
        );
        let busy = json!([{ "short": "B580", "vram_total_mib": 12216, "vram_free_mib": 3000 }]);
        assert_eq!(warnings(&json!({ "ports": {}, "mcp_servers": {}, "card_order": { "ok": true } }), &busy, Some(&manifest)).len(), 0);
    }

    #[test]
    fn recognises_mcp_servers() {
        let processes = vec![
            vec!["/nix/store/aaaa-lugh-monitor-0.1.0/bin/lugh-monitor".to_owned(), "--manifest".to_owned()],
            vec!["/nix/store/bbbb-github-mcp-server-1.0/bin/github-mcp-server".to_owned(), "stdio".to_owned()],
        ];
        assert!(server_running("/nix/store/aaaa-lugh-monitor-0.1.0/bin/lugh-monitor", &processes));
        let wrapper = format!("/nix/store/{}-github-mcp", "3".repeat(32));
        assert!(server_running(&wrapper, &processes));
        assert!(!server_running("/nix/store/cccc-other/bin/other", &processes));
    }
}
