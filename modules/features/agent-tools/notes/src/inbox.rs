//! Filing the inbox. The owner reviews each transcription in Obsidian and sets `review: accept` or `review: delete`;
//! that mark is their approval, so these two need no other:
//! - `file` puts an accepted note in its place: the vault's properties (type, status, tags, created) instead of the
//!   transcriber's bookkeeping, its unchecked to-dos moved into the tasks note, links to related notes, and a move
//!   (links to it fixed). The owner's text is kept as they wrote it. A note with no `review` at all (one saved from
//!   chat) files too; one still `pending` waits.
//! - `discard` deletes a note marked `review: delete`, with its drawing: the only thing here that deletes, and only
//!   that.
//!
//! Once filed, a note has no fingerprint, so the transcriber treats it as the owner's and never changes it again.

use crate::library::Library;
use crate::note::{Note, quoted};
use crate::write::{note_name, replace, write_new};
use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

const TYPES: &[&str] = &["idea", "project", "reference"];
const STATUSES: &[&str] = &["open", "parked", "in-progress", "done", "dropped"];

// An unchecked to-do: "- [ ] …" or "* [ ] …", indented or not.
static TODO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*[-*+] \[ \]\s+(.+?)\s*$").unwrap());

/// What a filed note becomes, as the model chose it.
pub struct Filing<'a> {
    pub inbox: &'a str,
    pub tasks: &'a str,
    pub note: &'a str,
    /// Its new path: folder and name.
    pub to: &'a str,
    pub kind: &'a str,
    pub status: Option<&'a str>,
    pub tags: &'a [String],
    /// YYYY-MM-DD; default: the day it was transcribed, else today.
    pub created: Option<&'a str>,
    /// Notes to link to from it.
    pub related: &'a [String],
}

impl Library {
    /// An inbox note the owner has reviewed (or that needs no review), with its text and its `review` mark.
    fn reviewed(&self, inbox: &str, note: &str) -> Result<(String, String, Option<String>)> {
        let path = self.find(note)?;
        let rel = self.show(&path);
        if !rel.starts_with(&format!("{}/", inbox.trim_end_matches('/'))) {
            bail!("{rel} isn't in {inbox}: only inbox notes are filed or discarded this way");
        }
        let raw = fs::read_to_string(&path).with_context(|| format!("{rel} can't be read as text"))?;
        let review = Note::parse(&raw).get("review").map(|r| r.trim().to_lowercase());
        Ok((rel, raw, review))
    }

    pub fn file(&self, f: &Filing) -> Result<Value> {
        let (rel, raw, review) = self.reviewed(f.inbox, f.note)?;
        match review.as_deref() {
            None | Some("accept") => {}
            Some("delete") => bail!("{rel} is marked review: delete; discard it instead"),
            Some(other) => bail!("{rel} is marked review: {other}; it waits until the owner accepts it"),
        }
        if !TYPES.contains(&f.kind) {
            bail!("type must be one of {}", TYPES.join(", "));
        }
        let status = match (f.kind, f.status.map(str::trim).filter(|s| !s.is_empty())) {
            ("reference", _) => None,
            (_, Some(s)) if STATUSES.contains(&s) => Some(s),
            (_, Some(s)) => bail!("status {s:?} isn't one of {}", STATUSES.join(", ")),
            (_, None) => bail!("an {} needs a status: one of {}", f.kind, STATUSES.join(", ")),
        };

        // Where it goes, checked before anything changes.
        let to = f.to.trim().trim_end_matches('/');
        let to_rel = if to.ends_with(".md") { to.to_string() } else { format!("{to}.md") };
        let (folder, name) = to_rel.rsplit_once('/').map_or(("", to_rel.as_str()), |(d, n)| (d, n));
        let name = note_name(name)?;
        if folder.is_empty() || folder.split('/').next() == Some(f.inbox) || folder.starts_with('_') {
            bail!("{to_rel}: file it into a folder of the vault (Ideas, Projects/…, Reference…), not the top, the inbox or a _ folder");
        }
        if self.new_path(&to_rel)?.exists() {
            bail!("{to_rel} already exists: pick another name");
        }
        let old_name = Path::new(&rel).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        if !name.eq_ignore_ascii_case(&old_name)
            && let Some(existing) = self.named(&name)?
        {
            bail!("a note called {name} already exists ({existing}): names are unique, pick another");
        }
        let mut related = Vec::new();
        for r in f.related {
            let path = self.find(r).with_context(|| format!("related note {r}"))?;
            let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if stem != old_name && !related.contains(&stem) {
                related.push(stem);
            }
        }

        let note = Note::parse(&raw);
        let created = match f.created {
            Some(c) if is_date(c.trim()) => c.trim().to_string(),
            Some(c) => bail!("created {c:?} isn't a date like 2026-11-23"),
            None => note
                .get("transcribed")
                .and_then(|t| t.get(..10).map(String::from))
                .filter(|d| is_date(d))
                .unwrap_or_else(|| chrono::Local::now().format("%Y-%m-%d").to_string()),
        };
        let (body, todos) = take_todos(note.body);
        // Only the vault's properties and the drawing link: the transcriber's fields (review, transcribed,
        // transcription, the fingerprints) are left behind.
        let mut text = front_matter(f.kind, status, f.tags, &created, note.get("source").as_deref());
        text.push_str(body.trim_start_matches('\n').trim_end());
        text.push('\n');
        if !related.is_empty() {
            let links: Vec<String> = related.iter().map(|r| format!("[[{r}]]")).collect();
            text.push_str(&format!("\nRelated: {}\n", links.join(", ")));
        }

        replace(&self.root.join(&rel), &text)?;
        let moved = self.move_note(&rel, &to_rel)?;
        if !todos.is_empty() {
            self.add_tasks(f.tasks, &todos, &name)?;
        }
        Ok(json!({
            "filed": rel,
            "to": moved["to"],
            "todos_moved_to": if todos.is_empty() { Value::Null } else { json!(f.tasks) },
            "todos": todos,
            "links_updated_in": moved["links_updated_in"],
        }))
    }

    /// Appends to-dos to the tasks note, newest last, each linked to the note it came from; makes the note if needed.
    fn add_tasks(&self, tasks: &str, todos: &[String], from: &str) -> Result<()> {
        let path = self.new_path(tasks)?;
        let lines: String = todos.iter().map(|t| format!("- [ ] {t} ([[{from}]])\n")).collect();
        if path.exists() {
            let mut raw = fs::read_to_string(&path)?;
            if !raw.ends_with('\n') {
                raw.push('\n');
            }
            raw.push_str(&lines);
            replace(&path, &raw)
        } else {
            let today = chrono::Local::now().format("%Y-%m-%d");
            write_new(
                &path,
                &format!("---\ntype: reference\ntags:\n  - tasks\ncreated: {today}\n---\n# Tasks\n\nTo-dos from filed notes, newest last.\n\n{lines}"),
            )
        }
    }

    /// Deletes an inbox note marked `review: delete`, and the drawing in its `source:` (the .excalidraw.md and its
    /// exported .png).
    pub fn discard(&self, inbox: &str, note: &str) -> Result<Value> {
        let (rel, raw, review) = self.reviewed(inbox, note)?;
        if review.as_deref() != Some("delete") {
            bail!("{rel} isn't marked review: delete; only notes the owner marked that way are deleted");
        }
        let mut deleted = Vec::new();
        if let Some(link) = Note::parse(&raw).source_link()
            && link.ends_with(".excalidraw")
        {
            for file in [format!("{link}.md"), format!("{link}.png")] {
                // resolve() keeps it inside the vault, nothing hidden, through no link.
                if let Ok(path) = self.resolve(&file)
                    && path.is_file()
                {
                    fs::remove_file(&path).with_context(|| format!("deleting {file}"))?;
                    deleted.push(file);
                }
            }
        }
        fs::remove_file(self.root.join(&rel)).with_context(|| format!("deleting {rel}"))?;
        deleted.insert(0, rel);
        Ok(json!({ "deleted": deleted }))
    }
}

/// The body with its unchecked to-dos taken out (a line saying where they went in place of the first), and the
/// to-dos.
fn take_todos(body: &str) -> (String, Vec<String>) {
    let mut todos = Vec::new();
    let mut out = String::new();
    let mut fence = false;
    for line in body.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fence = !fence;
        }
        match TODO.captures(line).filter(|_| !fence) {
            Some(c) => {
                if todos.is_empty() {
                    out.push_str("To-dos moved to [[Tasks]].\n");
                }
                todos.push(c[1].to_string());
            }
            None => {
                out.push_str(line);
                out.push('\n');
            }
        }
    }
    (out, todos)
}

fn front_matter(kind: &str, status: Option<&str>, tags: &[String], created: &str, source: Option<&str>) -> String {
    let mut out = format!("---\ntype: {kind}\n");
    if let Some(s) = status {
        out.push_str(&format!("status: {s}\n"));
    }
    let tags: Vec<String> =
        tags.iter().map(|t| t.trim().trim_start_matches('#').to_string()).filter(|t| !t.is_empty()).collect();
    if tags.is_empty() {
        out.push_str("tags: []\n");
    } else {
        out.push_str("tags:\n");
        for t in tags {
            // Plain where it can be, as Obsidian writes tags.
            let plain = t.chars().all(|c| c.is_alphanumeric() || "_-/".contains(c));
            out.push_str(&format!("  - {}\n", if plain { t } else { quoted(&t) }));
        }
    }
    out.push_str(&format!("created: {created}\n"));
    if let Some(source) = source {
        out.push_str(&format!("source: {}\n", quoted(source.trim())));
    }
    out.push_str("---\n");
    out
}

fn is_date(text: &str) -> bool {
    chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d").is_ok()
}

#[cfg(test)]
#[path = "inbox_tests.rs"]
mod tests;
