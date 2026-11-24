//! Reading the vault: listing folders, reading a note with its properties and links, and searching by words. Every
//! path the model gives is relative to the vault and checked to stay inside it, hidden files and folders (Obsidian's
//! settings, sync state) included: nothing here reaches outside the notes.

use crate::note::Note;
use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::{Value, json};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;
use std::time::SystemTime;

/// The most a list or search returns, and the most of a note's body a read returns.
const MAX_ENTRIES: usize = 200;
const MAX_BODY: usize = 30_000;

// [[target]], [[target|shown]], [[target#heading]], and the embedded ![[…]] forms.
pub(crate) static LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[\[([^\]|#\n]+)(?:#[^\]|\n]*)?(?:\|[^\]\n]*)?\]\]").unwrap());
// #tag or #nested/tag in the text, not a heading (# followed by a space) or part of a word or URL.
static TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:^|[\s(])#([\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*)").unwrap());

pub struct Library {
    pub root: PathBuf,
}

/// One note found on disk, with the parts listing and searching need.
pub(crate) struct Found {
    pub(crate) rel: String,
    pub(crate) raw: String,
    modified: Option<SystemTime>,
}

impl Library {
    /// A path the model gave, relative to the vault, made absolute: no root, no `..`, nothing hidden, and (once
    /// symlinks are resolved) still inside the vault.
    fn resolve(&self, rel: &str) -> Result<PathBuf> {
        let rel = rel.trim().trim_start_matches("./").trim_end_matches('/');
        let path = Path::new(rel);
        if rel.is_empty() {
            return Ok(self.root.clone());
        }
        for c in path.components() {
            match c {
                Component::Normal(part) if !part.to_string_lossy().starts_with('.') => {}
                _ => bail!("{rel}: use a path inside the vault, like Inbox or Ideas/Duct fan.md"),
            }
        }
        let full = self.root.join(path);
        let real = full.canonicalize().with_context(|| format!("{rel} isn't in the vault"))?;
        let root = self.root.canonicalize().context("the vault is missing")?;
        if !real.starts_with(&root) {
            bail!("{rel} isn't in the vault");
        }
        Ok(full)
    }

    pub(crate) fn show(&self, path: &Path) -> String {
        path.strip_prefix(&self.root).unwrap_or(path).to_string_lossy().into_owned()
    }

    /// Every note (Markdown, but not Excalidraw's drawing data) under `dir`, in path order.
    pub(crate) fn notes_under(&self, dir: &Path) -> Result<Vec<Found>> {
        let mut out = Vec::new();
        for path in walk(dir)? {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if !name.ends_with(".md") || name.ends_with(".excalidraw.md") {
                continue;
            }
            let Ok(raw) = fs::read_to_string(&path) else { continue };
            let modified = fs::metadata(&path).and_then(|m| m.modified()).ok();
            out.push(Found { rel: self.show(&path), raw, modified });
        }
        Ok(out)
    }

    /// A folder's contents: subfolders, then notes (with their type, status and tags) and other files, newest first.
    pub fn list(&self, folder: &str, recursive: bool) -> Result<Value> {
        let dir = self.resolve(folder)?;
        if !dir.is_dir() {
            bail!("{folder} is a note, not a folder: read it instead");
        }
        let mut folders = Vec::new();
        let mut files = Vec::new();
        let paths = if recursive { walk(&dir)? } else { children(&dir)? };
        for path in paths {
            let rel = self.show(&path);
            if path.is_dir() {
                folders.push(json!(rel));
                continue;
            }
            let modified = fs::metadata(&path).and_then(|m| m.modified()).ok();
            let mut entry = json!({ "path": rel, "modified": date(modified) });
            if rel.ends_with(".md")
                && !rel.ends_with(".excalidraw.md")
                && let Ok(raw) = fs::read_to_string(&path)
            {
                let note = Note::parse(&raw);
                for key in ["type", "status"] {
                    if let Some(v) = note.get(key) {
                        entry[key] = json!(v);
                    }
                }
                let tags = note.list("tags");
                if !tags.is_empty() {
                    entry["tags"] = json!(tags);
                }
            }
            files.push((modified, entry));
        }
        files.sort_by_key(|f| std::cmp::Reverse(f.0));
        let total = files.len();
        let files: Vec<Value> = files.into_iter().take(MAX_ENTRIES).map(|(_, e)| e).collect();
        let mut out = json!({ "folder": if folder.trim().is_empty() { "/" } else { folder.trim() }, "folders": folders, "files": files });
        if total > MAX_ENTRIES {
            out["note"] = json!(format!("showing the newest {MAX_ENTRIES} of {total} files"));
        }
        Ok(out)
    }

    /// One note: its properties, body, tags, the notes it links to, and the notes that link to it. `name` is a path
    /// (with or without `.md`) or, as in an Obsidian link, just the note's name when that's unique.
    pub fn read(&self, name: &str) -> Result<Value> {
        let path = self.find(name)?;
        let raw = fs::read_to_string(&path).with_context(|| format!("{name} can't be read as text"))?;
        let note = Note::parse(&raw);
        let rel = self.show(&path);
        let stem = rel.trim_end_matches(".md").to_string();
        let title = Path::new(&stem).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();

        let mut tags = note.list("tags");
        for t in inline_tags(note.body) {
            if !tags.contains(&t) {
                tags.push(t);
            }
        }
        let linked_from: Vec<String> = self
            .notes_under(&self.root)?
            .into_iter()
            .filter(|f| f.rel != rel && links(&f.raw).iter().any(|l| l == &stem || l == &title))
            .map(|f| f.rel)
            .collect();

        let (body, cut) = clip(note.body, MAX_BODY);
        let mut out = json!({
            "path": rel,
            "properties": note.properties(),
            "body": body,
            "tags": tags,
            "links": links(note.body),
            "linked_from": linked_from,
            "modified": date(fs::metadata(&path).and_then(|m| m.modified()).ok()),
        });
        if cut {
            out["note"] = json!(format!("the body is cut at {MAX_BODY} characters"));
        }
        Ok(out)
    }

    /// The note `name` refers to: a path in the vault (`.md` optional), or a note name found once anywhere in it.
    pub(crate) fn find(&self, name: &str) -> Result<PathBuf> {
        let name = name.trim().trim_start_matches("[[").trim_end_matches("]]");
        for candidate in [name.to_string(), format!("{name}.md")] {
            if let Ok(path) = self.resolve(&candidate)
                && path.is_file()
            {
                return Ok(path);
            }
        }
        let wanted = format!("{}.md", name.trim_end_matches(".md")).to_lowercase();
        let matches: Vec<String> = self
            .notes_under(&self.root)?
            .into_iter()
            .map(|f| f.rel)
            .filter(|rel| rel.rsplit('/').next().is_some_and(|n| n.to_lowercase() == wanted))
            .collect();
        match matches.as_slice() {
            [one] => self.resolve(one),
            [] => bail!("no note called {name}: search for it, or list a folder"),
            many => bail!("{name} could be any of: {}", many.join(", ")),
        }
    }

    /// Notes containing every word of `query` (in any case) in their name, properties or text, best first: name
    /// matches, then the most mentions. Each comes with the lines that match.
    pub fn search(&self, query: &str, folder: &str, limit: usize) -> Result<Value> {
        let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
        if words.is_empty() {
            bail!("search for at least one word");
        }
        let dir = self.resolve(folder)?;
        let mut hits = Vec::new();
        for found in self.notes_under(&dir)? {
            let haystack = format!("{}\n{}", found.rel, found.raw).to_lowercase();
            if !words.iter().all(|w| haystack.contains(w.as_str())) {
                continue;
            }
            let name = found.rel.to_lowercase();
            let in_name = words.iter().filter(|w| name.contains(w.as_str())).count();
            let mentions: usize = words.iter().map(|w| haystack.matches(w.as_str()).count()).sum();
            let lines: Vec<String> = found
                .raw
                .lines()
                .filter(|l| {
                    let l = l.to_lowercase();
                    words.iter().any(|w| l.contains(w.as_str()))
                })
                .take(3)
                .map(|l| clip(l.trim(), 200).0)
                .collect();
            let note = Note::parse(&found.raw);
            let mut hit = json!({ "path": found.rel, "lines": lines, "modified": date(found.modified) });
            if let Some(t) = note.get("type") {
                hit["type"] = json!(t);
            }
            hits.push((in_name, mentions, hit));
        }
        hits.sort_by_key(|h| std::cmp::Reverse((h.0, h.1)));
        let total = hits.len();
        let limit = limit.clamp(1, 50);
        Ok(json!({
            "query": query,
            "matches": total,
            "notes": hits.into_iter().take(limit).map(|(_, _, h)| h).collect::<Vec<_>>(),
        }))
    }
}

/// The targets of a note's [[links]] (embeds included), each once, in order.
pub fn links(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for c in LINK.captures_iter(text) {
        let target = c[1].trim().trim_end_matches(".md").to_string();
        if !out.contains(&target) {
            out.push(target);
        }
    }
    out
}

/// The #tags written in a note's text, each once, outside code.
pub fn inline_tags(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut in_code = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            continue;
        }
        for c in TAG.captures_iter(line) {
            let tag = c[1].to_string();
            if !out.contains(&tag) {
                out.push(tag);
            }
        }
    }
    out
}

/// Text cut to at most `max` characters (on a character boundary), and whether it was cut.
fn clip(text: &str, max: usize) -> (String, bool) {
    match text.char_indices().nth(max) {
        Some((i, _)) => (format!("{}…", &text[..i]), true),
        None => (text.to_string(), false),
    }
}

fn date(time: Option<SystemTime>) -> Value {
    match time {
        Some(t) => json!(chrono::DateTime::<chrono::Local>::from(t).format("%Y-%m-%d %H:%M").to_string()),
        None => Value::Null,
    }
}

/// A folder's visible entries, in name order.
fn children(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| e.path())
        .collect();
    out.sort();
    Ok(out)
}

/// Everything visible under a folder, folders and files, in path order (symlinks aren't followed).
fn walk(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for path in children(dir)? {
        let kind = fs::symlink_metadata(&path)?.file_type();
        if kind.is_dir() {
            out.push(path.clone());
            out.extend(walk(&path)?);
        } else if kind.is_file() {
            out.push(path);
        }
    }
    Ok(out)
}

#[cfg(test)]
#[path = "library_tests.rs"]
mod tests;
