//! What lugh should be running, written by Nix from the modules that set it up (see modules/base/monitor.nix).
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
    pub units: Vec<String>,
    pub ports: BTreeMap<String, u16>,
    /// By short name, which is also how llama-server --list-devices names them.
    pub cards: BTreeMap<String, Card>,
    pub always_loaded: Vec<String>,
    pub check_devices: Option<String>,
    /// Name → command.
    pub mcp_servers: BTreeMap<String, String>,
    pub disks: Vec<String>,
    pub managed_files: Managed,
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
