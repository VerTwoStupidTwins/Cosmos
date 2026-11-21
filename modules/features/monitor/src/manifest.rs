//! What this host should be running, written by Nix from the modules that set it up (see modules/base/monitor.nix).
//!
//! It's read on every call, like the revision, so it always describes the active system.

use std::collections::BTreeMap;
use std::fs;

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub units: Vec<String>,
    #[serde(default)]
    pub ports: BTreeMap<String, u16>,
    #[serde(default)]
    pub disks: Vec<String>,
    /// Where a root timer saves each NVMe drive's health as JSON, since reading it needs root.
    #[serde(default)]
    pub nvme_health_dir: Option<String>,
}

impl Manifest {
    pub fn read(file: &str) -> Result<Self> {
        let text = fs::read_to_string(file).with_context(|| format!("reading {file}"))?;
        serde_json::from_str(&text).with_context(|| format!("parsing {file}"))
    }
}
