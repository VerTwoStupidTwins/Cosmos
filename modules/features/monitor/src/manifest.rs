//! What this host should be running, written by Nix from the modules that set it up (see modules/base/monitor.nix).
//!
//! It's read on every call, like the revision, so it always describes the active system.

use std::collections::BTreeMap;
use std::fs;

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::edits::Managed;

#[derive(Deserialize)]
pub struct Card {
    pub name: String,
    #[serde(default)]
    pub note: String,
    /// `vendor:device`, such as `0x1002:0x744c`.
    pub pci_id: String,
    /// The models that run on it, which make up its role.
    #[serde(default)]
    pub models: Vec<String>,
}

#[derive(Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub units: Vec<String>,
    #[serde(default)]
    pub ports: BTreeMap<String, u16>,
    /// By short name, which is also how llama-server --list-devices names them.
    #[serde(default)]
    pub cards: BTreeMap<String, Card>,
    #[serde(default)]
    pub always_loaded: Vec<String>,
    #[serde(default)]
    pub check_devices: Option<String>,
    /// Hermes' MCP servers, name → command line, on the host Hermes runs on.
    #[serde(default)]
    pub mcp_servers: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub disks: Vec<String>,
    /// Files the config manages in Hermes' home, on the host Hermes runs on.
    #[serde(default)]
    pub managed_files: Option<Managed>,
}

impl Manifest {
    pub fn read(file: &str) -> Result<Self> {
        let text = fs::read_to_string(file).with_context(|| format!("reading {file}"))?;
        serde_json::from_str(&text).with_context(|| format!("parsing {file}"))
    }

    /// A card's short name and details, by its PCI vendor and device IDs.
    pub fn card_by_pci(&self, pci_id: &str) -> Option<(&String, &Card)> {
        self.cards.iter().find(|(_, c)| c.pci_id == pci_id)
    }
}
