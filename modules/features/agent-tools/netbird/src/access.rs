//! NetBird's access settings as the API returns them, shaped into short lines, and checked against what the repo
//! declares (modules/netbird-policies.nix, as JSON): missing, extra or changed policies, groups and peer addresses.

use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize, Default)]
pub struct Named {
    pub name: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct PortRange {
    pub start: u32,
    pub end: u32,
}

#[derive(Deserialize, Default)]
pub struct Rule {
    #[serde(default)]
    pub sources: Option<Vec<Named>>,
    #[serde(default)]
    pub destinations: Option<Vec<Named>>,
    #[serde(default)]
    pub bidirectional: bool,
    pub protocol: Option<String>,
    #[serde(default)]
    pub ports: Option<Vec<String>>,
    #[serde(default)]
    pub port_ranges: Option<Vec<PortRange>>,
}

#[derive(Deserialize)]
pub struct Policy {
    pub name: String,
    pub description: Option<String>,
    pub enabled: bool,
    #[serde(default)]
    pub rules: Vec<Rule>,
}

#[derive(Deserialize)]
pub struct Group {
    pub name: String,
    pub peers_count: Option<u32>,
    #[serde(default)]
    pub peers: Option<Vec<Named>>,
}

#[derive(Deserialize)]
pub struct Peer {
    pub name: String,
    pub ip: String,
    #[serde(default)]
    pub dns_label: String,
    #[serde(default)]
    pub connected: bool,
    #[serde(default)]
    pub groups: Option<Vec<Named>>,
    pub os: Option<String>,
}

/// What the repo says should be set.
#[derive(Deserialize)]
pub struct Declared {
    #[serde(default)]
    pub peers: BTreeMap<String, DeclaredPeer>,
    #[serde(default)]
    pub groups: BTreeMap<String, DeclaredGroup>,
    #[serde(default)]
    pub policies: BTreeMap<String, DeclaredPolicy>,
}

#[derive(Deserialize)]
pub struct DeclaredPeer {
    pub ip: String,
}

#[derive(Deserialize)]
pub struct DeclaredGroup {
    /// None: someone else's group, or a built-in one, checked for existence only.
    pub members: Option<Vec<String>>,
}

#[derive(Deserialize)]
pub struct DeclaredPolicy {
    pub from: Vec<String>,
    pub to: Vec<String>,
    pub protocol: String,
    #[serde(default)]
    pub ports: Vec<String>,
    #[serde(default)]
    pub bidirectional: bool,
    /// Why it's deliberately broader than it could be, when it is.
    pub broad: Option<String>,
}

fn names(list: &Option<Vec<Named>>) -> Vec<String> {
    list.iter()
        .flatten()
        .map(|n| n.name.clone().unwrap_or_else(|| "?".into()))
        .collect()
}

fn rule_ports(rule: &Rule) -> Vec<String> {
    let mut ports: Vec<String> = rule.ports.clone().unwrap_or_default();
    ports.extend(
        rule.port_ranges
            .iter()
            .flatten()
            .map(|r| format!("{}-{}", r.start, r.end)),
    );
    ports
}

fn same(a: &[String], b: &[String]) -> bool {
    let (mut a, mut b) = (a.to_vec(), b.to_vec());
    a.sort();
    b.sort();
    a == b
}

fn list(a: &[String]) -> String {
    if a.is_empty() {
        "all".into()
    } else {
        a.join(",")
    }
}

/// One line per rule, as the dashboard lists them.
pub fn policies(list: &[Policy]) -> String {
    let mut lines = Vec::new();
    for p in list {
        for r in &p.rules {
            let ports = rule_ports(r);
            let mut line = format!(
                "{}  {}: {} {} {}  {} {}",
                if p.enabled { "on " } else { "off" },
                p.name,
                names(&r.sources).join(", "),
                if r.bidirectional { "<->" } else { "->" },
                names(&r.destinations).join(", "),
                r.protocol.as_deref().unwrap_or("all").to_uppercase(),
                if ports.is_empty() {
                    "all ports".into()
                } else {
                    ports.join(",")
                },
            );
            if let Some(d) = p
                .description
                .as_deref()
                .map(str::trim)
                .filter(|d| !d.is_empty())
            {
                line.push_str(&format!(
                    "  # {}",
                    d.split_whitespace().collect::<Vec<_>>().join(" ")
                ));
            }
            lines.push(line);
        }
    }
    lines.join("\n")
}

pub fn groups(list: &[Group]) -> String {
    list.iter()
        .map(|g| {
            format!(
                "{} ({} peers): {}",
                g.name,
                g.peers_count.unwrap_or(0),
                names(&g.peers).join(", ")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn peers(list: &[Peer]) -> String {
    list.iter()
        .map(|p| {
            format!(
                "{}  {}  {}  {}  [{}]{}",
                p.name,
                p.ip,
                p.dns_label,
                if p.connected { "connected" } else { "offline" },
                names(&p.groups).join(", "),
                p.os.as_deref()
                    .map(|os| format!("  {os}"))
                    .unwrap_or_default(),
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The live settings checked against the declared ones.
pub fn drift(declared: &Declared, live: &[Policy], groups: &[Group], peers: &[Peer]) -> String {
    let mut lines = Vec::new();

    // The owner's peers' addresses: private web sites allow by them, so a changed one locks that device out.
    for (name, want) in &declared.peers {
        match peers.iter().find(|p| &p.name == name) {
            None => lines.push(format!("MISSING peer {name} ({}): not in NetBird", want.ip)),
            Some(have) if have.ip != want.ip => lines.push(format!(
                "CHANGED peer {name}: NetBird IP {} (repo: {}; private sites allow by it)",
                have.ip, want.ip
            )),
            Some(_) => {}
        }
    }

    for (name, want) in &declared.policies {
        let Some(have) = live.iter().find(|p| &p.name == name) else {
            lines.push(format!(
                "MISSING policy {name}: the repo has it ({} -> {} {} {}), NetBird doesn't",
                want.from.join(","),
                want.to.join(","),
                want.protocol,
                list(&want.ports)
            ));
            continue;
        };
        let mut changes = Vec::new();
        if !have.enabled {
            changes.push("it is disabled".to_string());
        }
        if have.rules.len() != 1 {
            changes.push(format!(
                "it has {} rules, the repo describes one",
                have.rules.len()
            ));
        }
        if let Some(rule) = have.rules.first() {
            let (from, to, ports) = (
                names(&rule.sources),
                names(&rule.destinations),
                rule_ports(rule),
            );
            if !same(&from, &want.from) {
                changes.push(format!(
                    "sources {} (repo: {})",
                    from.join(","),
                    want.from.join(",")
                ));
            }
            if !same(&to, &want.to) {
                changes.push(format!(
                    "destinations {} (repo: {})",
                    to.join(","),
                    want.to.join(",")
                ));
            }
            let protocol = rule.protocol.as_deref().unwrap_or("all");
            if protocol != want.protocol {
                changes.push(format!("protocol {protocol} (repo: {})", want.protocol));
            }
            if !same(&ports, &want.ports) {
                changes.push(format!(
                    "ports {} (repo: {})",
                    list(&ports),
                    list(&want.ports)
                ));
            }
            if rule.bidirectional != want.bidirectional {
                let way = |b: bool| if b { "two-way" } else { "one-way" };
                changes.push(format!(
                    "{} (repo: {})",
                    way(rule.bidirectional),
                    way(want.bidirectional)
                ));
            }
        }
        if !changes.is_empty() {
            lines.push(format!("CHANGED policy {name}: {}", changes.join("; ")));
        }
    }
    for p in live
        .iter()
        .filter(|p| !declared.policies.contains_key(&p.name))
    {
        let shown = policies(std::slice::from_ref(p));
        let shown = shown
            .split_once(char::is_whitespace)
            .map_or(shown.as_str(), |(_, rest)| rest.trim_start());
        lines.push(format!(
            "EXTRA policy {}: in NetBird ({shown}), not in the repo",
            p.name
        ));
    }

    for (name, want) in &declared.groups {
        let Some(have) = groups.iter().find(|g| &g.name == name) else {
            lines.push(format!("MISSING group {name}"));
            continue;
        };
        let Some(wanted) = &want.members else {
            continue;
        };
        let members = names(&have.peers);
        let lacking: Vec<_> = wanted
            .iter()
            .filter(|m| !members.contains(m))
            .cloned()
            .collect();
        let added: Vec<_> = members
            .iter()
            .filter(|m| !wanted.contains(m))
            .cloned()
            .collect();
        if !lacking.is_empty() || !added.is_empty() {
            let mut line = format!("CHANGED group {name}:");
            if !lacking.is_empty() {
                line.push_str(&format!(" lacks {}", lacking.join(", ")));
            }
            if !added.is_empty() {
                line.push_str(&format!(" also has {}", added.join(", ")));
            }
            lines.push(line);
        }
    }
    for g in groups
        .iter()
        .filter(|g| !declared.groups.contains_key(&g.name))
    {
        lines.push(format!(
            "EXTRA group {} ({} peers), not in the repo",
            g.name,
            g.peers_count.unwrap_or(0)
        ));
    }

    let mut out = if lines.is_empty() {
        format!(
            "No drift: NetBird matches the repo ({} policies, {} groups, {} peers' addresses).",
            declared.policies.len(),
            declared.groups.len(),
            declared.peers.len()
        )
    } else {
        format!(
            "{} difference(s) between the repo (modules/netbird-policies.nix) and NetBird:\n{}",
            lines.len(),
            lines.join("\n")
        )
    };
    let broad: Vec<_> = declared
        .policies
        .iter()
        .filter_map(|(n, p)| p.broad.as_ref().map(|why| format!("{n} ({why})")))
        .collect();
    if !broad.is_empty() {
        out.push_str(&format!(
            "\nDeliberately broad (known): {}",
            broad.join("; ")
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse<T: serde::de::DeserializeOwned>(v: serde_json::Value) -> T {
        serde_json::from_value(v).unwrap()
    }

    fn declared() -> Declared {
        parse(json!({
            "peers": { "tenjin": { "ip": "100.1.0.2" } },
            "groups": {
                "CosmosInfra": { "members": ["lugh"], "owner": "me", "description": "" },
                "All": { "members": null, "owner": "netbird", "description": "" }
            },
            "policies": {
                "CosmosModels": { "from": ["CosmosInfra"], "to": ["CosmosModels"], "protocol": "tcp", "ports": ["8080"],
                                  "bidirectional": false, "owner": "me", "why": "", "broad": null },
                "Homelab Access": { "from": ["Olympus"], "to": ["Olympus"], "protocol": "all", "ports": [],
                                    "bidirectional": true, "owner": "brother", "why": "", "broad": "his NFS" }
            }
        }))
    }

    fn live_policies() -> Vec<Policy> {
        parse(json!([
            { "name": "CosmosModels", "enabled": true, "rules": [
                { "sources": [{"name": "CosmosInfra"}], "destinations": [{"name": "CosmosModels"}],
                  "protocol": "tcp", "ports": ["8080"], "bidirectional": false } ] },
            { "name": "Homelab Access", "enabled": true, "description": "brother's\n  mesh", "rules": [
                { "sources": [{"name": "Olympus"}], "destinations": [{"name": "Olympus"}],
                  "protocol": "all", "bidirectional": true } ] }
        ]))
    }

    fn live_groups() -> Vec<Group> {
        parse(json!([
            { "name": "CosmosInfra", "peers_count": 1, "peers": [{"name": "lugh"}] },
            { "name": "All", "peers_count": 5, "peers": [] }
        ]))
    }

    fn live_peers() -> Vec<Peer> {
        parse(
            json!([{ "name": "tenjin", "ip": "100.1.0.2", "dns_label": "tenjin.netbird.cloud", "connected": true,
                        "groups": [{"name": "CosmosOwner"}], "os": "NixOS" }]),
        )
    }

    #[test]
    fn matching_settings_have_no_drift() {
        let out = drift(&declared(), &live_policies(), &live_groups(), &live_peers());
        assert!(
            out.starts_with(
                "No drift: NetBird matches the repo (2 policies, 2 groups, 1 peers' addresses)."
            ),
            "{out}"
        );
        assert!(
            out.ends_with("Deliberately broad (known): Homelab Access (his NFS)"),
            "{out}"
        );
    }

    #[test]
    fn differences_are_listed() {
        let mut live = live_policies();
        live[0].rules[0].ports = Some(vec!["8080".into(), "9000".into()]);
        live[1].enabled = false;
        live.push(parse(json!({ "name": "Stray", "enabled": true, "rules": [
            { "sources": [{"name": "All"}], "destinations": [{"name": "All"}], "protocol": "all" } ] })));
        let mut groups = live_groups();
        groups[0].peers = Some(vec![Named {
            name: Some("nabu".into()),
        }]);
        groups.push(parse(json!({ "name": "Old", "peers_count": 0 })));
        let mut peers = live_peers();
        peers[0].ip = "100.1.0.9".into();

        let out = drift(&declared(), &live, &groups, &peers);
        assert!(out.starts_with("6 difference(s)"), "{out}");
        assert!(out.contains("CHANGED peer tenjin: NetBird IP 100.1.0.9 (repo: 100.1.0.2"));
        assert!(out.contains("CHANGED policy CosmosModels: ports 8080,9000 (repo: 8080)"));
        assert!(out.contains("CHANGED policy Homelab Access: it is disabled"));
        assert!(
            out.contains(
                "EXTRA policy Stray: in NetBird (Stray: All -> All  ALL all ports), not in the repo"
            ),
            "{out}"
        );
        assert!(out.contains("CHANGED group CosmosInfra: lacks lugh also has nabu"));
        assert!(out.contains("EXTRA group Old (0 peers), not in the repo"));
    }

    #[test]
    fn a_missing_policy_and_peer_are_reported() {
        let out = drift(&declared(), &live_policies()[1..], &live_groups(), &[]);
        assert!(out.contains(
            "MISSING policy CosmosModels: the repo has it (CosmosInfra -> CosmosModels tcp 8080)"
        ));
        assert!(out.contains("MISSING peer tenjin (100.1.0.2): not in NetBird"));
    }

    #[test]
    fn views_are_one_line_each() {
        assert_eq!(
            policies(&live_policies()),
            "on   CosmosModels: CosmosInfra -> CosmosModels  TCP 8080\non   Homelab Access: Olympus <-> Olympus  ALL all ports  # brother's mesh"
        );
        assert_eq!(
            groups(&live_groups()),
            "CosmosInfra (1 peers): lugh\nAll (5 peers): "
        );
        assert_eq!(
            peers(&live_peers()),
            "tenjin  100.1.0.2  tenjin.netbird.cloud  connected  [CosmosOwner]  NixOS"
        );
    }
}
