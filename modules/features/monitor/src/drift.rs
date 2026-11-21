//! Whether the host runs what its config declares, beyond the services the other checks cover: listening ports.

use std::collections::BTreeSet;
use std::fs;
use std::time::Duration;

use anyhow::Result;
use serde_json::{Map, Value, json};

use crate::manifest::Manifest;

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
    Ok(json!({ "ports": ports }))
}

/// Health report warnings for drift.
pub fn warnings(drift: &Value) -> Vec<String> {
    let mut w = Vec::new();
    if let Some(e) = drift.get("error").and_then(Value::as_str) {
        w.push(format!("Could not check the host against its config: {e}"));
        return w;
    }
    for (name, p) in drift["ports"].as_object().into_iter().flatten() {
        if p["listening"] == false {
            w.push(format!("Nothing listens on port {} for {name}", p["port"]));
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
        let drift = json!({
            "ports": { "minecraft": { "port": 25565, "listening": false }, "sshd": { "port": 22, "listening": true } },
        });
        assert_eq!(warnings(&drift), ["Nothing listens on port 25565 for minecraft"]);
        assert_eq!(warnings(&json!({ "error": "no manifest" })), ["Could not check the host against its config: no manifest"]);
    }
}
