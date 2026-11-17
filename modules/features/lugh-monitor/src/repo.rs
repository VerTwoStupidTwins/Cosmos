//! What lugh is running, from the Cosmos repository: the commit it was built from, and a read-only copy of the
//! NixOS config that commit holds.
//!
//! Both are read from /etc on every call, so they always describe the system that's active now, and Hermes' own
//! config doesn't change (and restart Hermes) with every commit.

use std::fs;
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, bail};
use regex::RegexBuilder;
use serde_json::{Value, json};

pub const MAX_LIST: usize = 500;
pub const MAX_MATCHES: usize = 200;
pub const MAX_READ_LINES: usize = 500;
const MAX_LINE_CHARS: usize = 300;

/// The commit a build came from. A dirty build had uncommitted changes on top of `commit`.
pub struct Revision {
    pub commit: Option<String>,
    pub dirty: Option<bool>,
}

impl Revision {
    pub fn read(file: &str) -> Self {
        Self::parse(fs::read_to_string(file).ok().as_deref().unwrap_or(""))
    }

    fn parse(text: &str) -> Self {
        let text = text.trim();
        if text.is_empty() || text == "unknown" {
            return Self { commit: None, dirty: None };
        }
        match text.strip_suffix("-dirty") {
            Some(commit) => Self { commit: Some(commit.to_owned()), dirty: Some(true) },
            None => Self { commit: Some(text.to_owned()), dirty: Some(false) },
        }
    }
}

pub fn deployed_revision(revision_file: &str, source: &str) -> Value {
    let rev = Revision::read(revision_file);
    let note = match rev.dirty {
        None => "The build didn't record a commit.",
        Some(true) => "Built from uncommitted changes on top of this commit, so the config tools show those changes too.",
        Some(false) => "Built from exactly this commit.",
    };
    json!({
        "commit": rev.commit,
        "short": rev.commit.as_deref().map(|c| &c[..c.len().min(7)]),
        "uncommitted_changes": rev.dirty,
        "note": note,
        "config_available": Path::new(source).is_dir(),
    })
}

/// Resolves a path the caller gave, relative to the config root, refusing anything that would leave it.
fn resolve(root: &Path, relative: &str) -> Result<PathBuf> {
    let relative = relative.trim().trim_start_matches("./");
    let rel = Path::new(relative);
    if rel.components().any(|c| !matches!(c, Component::Normal(_) | Component::CurDir)) {
        bail!("Give a path inside the config, such as modules/features/llm.nix, without .. or a leading /");
    }
    let root = fs::canonicalize(root).context("The config isn't available on this system")?;
    let full = fs::canonicalize(root.join(rel)).with_context(|| format!("No such file or directory: {relative}"))?;
    if !full.starts_with(&root) {
        bail!("That path leads outside the config");
    }
    Ok(full)
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let mut entries: Vec<_> = fs::read_dir(dir)?.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            walk(&path, out)?;
        } else {
            out.push(path);
        }
    }
    Ok(())
}

fn relative_to(root: &Path, path: &Path) -> String {
    path.strip_prefix(root).unwrap_or(path).to_string_lossy().into_owned()
}

/// Every file under `dir` (or the file itself), with paths relative to the config root.
fn files_under(source: &str, dir: &str) -> Result<(PathBuf, Vec<PathBuf>)> {
    let root = fs::canonicalize(source).context("The config isn't available on this system")?;
    let start = resolve(&root, dir)?;
    let mut files = Vec::new();
    if start.is_dir() {
        walk(&start, &mut files)?;
    } else {
        files.push(start);
    }
    Ok((root, files))
}

pub fn list(source: &str, dir: &str) -> Result<Value> {
    let (root, files) = files_under(source, dir)?;
    let total = files.len();
    let names: Vec<String> = files.iter().take(MAX_LIST).map(|f| relative_to(&root, f)).collect();
    Ok(json!({ "files": names, "total": total, "truncated": total > MAX_LIST }))
}

pub fn search(source: &str, pattern: &str, dir: &str, ignore_case: bool, max_results: usize) -> Result<Value> {
    let re = RegexBuilder::new(pattern)
        .case_insensitive(ignore_case)
        .size_limit(1 << 20)
        .build()
        .context("Not a valid regular expression")?;
    let (root, files) = files_under(source, dir)?;
    let mut matches = Vec::new();
    let mut truncated = false;
    'files: for file in &files {
        // Binary files aren't config, so anything that isn't text is skipped.
        let Ok(text) = fs::read_to_string(file) else { continue };
        for (i, line) in text.lines().enumerate() {
            if re.is_match(line) {
                if matches.len() == max_results {
                    truncated = true;
                    break 'files;
                }
                matches.push(json!({
                    "file": relative_to(&root, file),
                    "line": i + 1,
                    "text": line.trim_end().chars().take(MAX_LINE_CHARS).collect::<String>(),
                }));
            }
        }
    }
    Ok(json!({ "pattern": pattern, "matches": matches, "truncated": truncated }))
}

pub fn read(source: &str, path: &str, start_line: usize, lines: usize) -> Result<Value> {
    let root = fs::canonicalize(source).context("The config isn't available on this system")?;
    let full = resolve(&root, path)?;
    if full.is_dir() {
        bail!("{path} is a directory; config_files lists what it holds");
    }
    let text = fs::read_to_string(&full).with_context(|| format!("{path} isn't a text file"))?;
    let all: Vec<&str> = text.lines().collect();
    let start = start_line.max(1);
    let end = (start + lines - 1).min(all.len());
    let numbered: Vec<String> =
        (start..=end).map(|n| format!("{n:>5}  {}", all[n - 1])).collect();
    Ok(json!({
        "path": relative_to(&root, &full),
        "start_line": start,
        "end_line": end,
        "total_lines": all.len(),
        "text": numbered.join("\n"),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let features = dir.path().join("modules/features");
        fs::create_dir_all(&features).unwrap();
        fs::write(dir.path().join("flake.nix"), "{ outputs = _: { }; }\n").unwrap();
        fs::write(features.join("llm.nix"), "# The B50 runs transcription.\n{\n  port = 8080;\n}\n").unwrap();
        fs::write(features.join("image.png"), [0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe]).unwrap();
        dir
    }

    fn src(dir: &tempfile::TempDir) -> String {
        dir.path().to_string_lossy().into_owned()
    }

    #[test]
    fn reads_revisions() {
        let r = Revision::parse("ebda6d2abc\n");
        assert_eq!((r.commit.as_deref(), r.dirty), (Some("ebda6d2abc"), Some(false)));
        let r = Revision::parse("ebda6d2abc-dirty");
        assert_eq!((r.commit.as_deref(), r.dirty), (Some("ebda6d2abc"), Some(true)));
        let r = Revision::parse("unknown");
        assert_eq!((r.commit, r.dirty), (None, None));
    }

    #[test]
    fn refuses_paths_outside_the_config() {
        let dir = config();
        let root = dir.path();
        assert!(resolve(root, "../etc/passwd").is_err());
        assert!(resolve(root, "/etc/passwd").is_err());
        assert!(resolve(root, "modules/../../x").is_err());
        assert!(resolve(root, "./modules/features/llm.nix").is_ok());
    }

    #[test]
    fn refuses_symlinks_out_of_the_config() {
        let dir = config();
        std::os::unix::fs::symlink("/etc", dir.path().join("escape")).unwrap();
        assert!(read(&src(&dir), "escape/hostname", 1, 10).is_err());
    }

    #[test]
    fn lists_files() {
        let dir = config();
        let out = list(&src(&dir), "").unwrap();
        assert_eq!(out["files"], json!(["flake.nix", "modules/features/image.png", "modules/features/llm.nix"]));
        assert_eq!(list(&src(&dir), "modules").unwrap()["total"], 2);
    }

    #[test]
    fn searches_text_files_only() {
        let dir = config();
        let out = search(&src(&dir), "b50", "", true, 50).unwrap();
        assert_eq!(out["matches"], json!([{ "file": "modules/features/llm.nix", "line": 1, "text": "# The B50 runs transcription." }]));
        assert_eq!(search(&src(&dir), "b50", "", false, 50).unwrap()["matches"], json!([]));
        let out = search(&src(&dir), ".", "", false, 2).unwrap();
        assert_eq!(out["truncated"], true);
        assert!(search(&src(&dir), "(", "", false, 2).is_err());
    }

    #[test]
    fn reads_numbered_lines() {
        let dir = config();
        let out = read(&src(&dir), "modules/features/llm.nix", 2, 2).unwrap();
        assert_eq!(out["text"], "    2  {\n    3    port = 8080;");
        assert_eq!(out["total_lines"], 4);
        let past_end = read(&src(&dir), "modules/features/llm.nix", 3, 100).unwrap();
        assert_eq!(past_end["end_line"], 4);
        assert!(read(&src(&dir), "modules", 1, 10).is_err());
    }
}
