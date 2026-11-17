//! Edits Hermes made to files the NixOS config manages in its home, such as the llm-wiki skill.
//!
//! The config rewrites those files on every switch, so an edit lasts only until then. Each switch first saves an
//! edited file to a folder outside Hermes' home. This finds edits made since the last switch, by comparing each live
//! file with the repo's copy, and lists the saved ones, so both can be brought into the repo.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
pub struct Managed {
    /// Hermes' home, which the live files' paths are relative to.
    home: String,
    /// Where each switch saves edited files before replacing them.
    saved: String,
    /// Live path relative to `home` → its source, relative to the repo root.
    files: std::collections::BTreeMap<String, String>,
}

impl Managed {
    pub fn read(file: &str) -> Result<Self> {
        let text = fs::read_to_string(file).with_context(|| format!("reading {file}"))?;
        serde_json::from_str(&text).with_context(|| format!("parsing {file}"))
    }
}

fn saved_files(dir: &Path, out: &mut Vec<Value>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = entries.filter_map(|e| e.ok()).collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let path = entry.path();
        // .installed holds the copies of what each switch installed, which are the comparison base, not edits.
        if entry.file_name() == ".installed" {
            continue;
        }
        if path.is_dir() {
            saved_files(&path, out);
        } else {
            let at = entry
                .metadata()
                .and_then(|m| m.modified())
                .map(|t| chrono::DateTime::<chrono::Local>::from(t).format("%Y-%m-%d %H:%M").to_string())
                .ok();
            out.push(json!({ "path": path.to_string_lossy(), "saved_at": at }));
        }
    }
}

pub fn edits(managed_file: &str, source: &str) -> Result<Value> {
    let m = Managed::read(managed_file)?;
    let files: Vec<Value> = m
        .files
        .iter()
        .map(|(live, repo)| {
            let live_path = Path::new(&m.home).join(live);
            let status = match (fs::read(&live_path), fs::read(Path::new(source).join(repo))) {
                (Err(_), _) => "missing",
                (_, Err(_)) => "not in the config copy",
                (Ok(a), Ok(b)) if a == b => "unchanged",
                _ => "edited",
            };
            json!({ "file": live_path.to_string_lossy(), "repo_path": repo, "status": status })
        })
        .collect();
    let mut saved = Vec::new();
    saved_files(Path::new(&m.saved), &mut saved);
    Ok(json!({ "files": files, "saved_before_switch": saved }))
}

/// Health report warnings for edits that aren't in the repo yet.
pub fn warnings(edits: &Value) -> Vec<String> {
    let mut w = Vec::new();
    if let Some(e) = edits.get("error").and_then(Value::as_str) {
        w.push(format!("Could not check Hermes' edits: {e}"));
    }
    for f in edits["files"].as_array().into_iter().flatten() {
        if f["status"] == "edited" {
            w.push(format!(
                "Hermes edited {}; the next switch replaces it, so bring it into the repo as {}",
                f["file"].as_str().unwrap_or_default(),
                f["repo_path"].as_str().unwrap_or_default()
            ));
        }
    }
    let saved = edits["saved_before_switch"].as_array().map_or(0, Vec::len);
    if saved > 0 {
        w.push(format!("{saved} saved Hermes edit(s) are waiting to go into the repo"));
    }
    w
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_edits_and_saved_copies() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        for p in ["home/skills/wiki", "home/skills/other", "repo/modules", "saved/skills/wiki", "saved/.installed/skills/wiki"] {
            fs::create_dir_all(d.join(p)).unwrap();
        }
        fs::write(d.join("repo/modules/wiki.md"), "original").unwrap();
        fs::write(d.join("repo/modules/other.md"), "same").unwrap();
        fs::write(d.join("home/skills/wiki/SKILL.md"), "improved by Hermes").unwrap();
        fs::write(d.join("home/skills/other/SKILL.md"), "same").unwrap();
        fs::write(d.join("saved/skills/wiki/SKILL.md.2026-11-16-183000"), "older edit").unwrap();
        fs::write(d.join("saved/.installed/skills/wiki/SKILL.md"), "original").unwrap();
        let manifest = d.join("managed.json");
        fs::write(
            &manifest,
            json!({
                "home": d.join("home"),
                "saved": d.join("saved"),
                "files": {
                    "skills/wiki/SKILL.md": "modules/wiki.md",
                    "skills/other/SKILL.md": "modules/other.md",
                    "skills/gone/SKILL.md": "modules/gone.md",
                },
            })
            .to_string(),
        )
        .unwrap();

        let out = edits(manifest.to_str().unwrap(), d.join("repo").to_str().unwrap()).unwrap();
        let statuses: Vec<&str> = out["files"].as_array().unwrap().iter().map(|f| f["status"].as_str().unwrap()).collect();
        assert_eq!(statuses, ["missing", "unchanged", "edited"]);
        let saved = out["saved_before_switch"].as_array().unwrap();
        assert_eq!(saved.len(), 1);
        assert!(saved[0]["path"].as_str().unwrap().ends_with("SKILL.md.2026-11-16-183000"));

        let w = warnings(&out);
        assert_eq!(w.len(), 2);
        assert!(w[0].contains("as modules/wiki.md"));
        assert_eq!(w[1], "1 saved Hermes edit(s) are waiting to go into the repo");
    }
}
