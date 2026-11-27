//! Filing the inbox. The owner reviews each transcription in Obsidian and sets `review: accept` or `review: delete`;
//! that mark is their approval, so these two need no other:
//! - `file` splits an accepted note into the notes it holds: each piece becomes a new note in its place (the vault's
//!   properties: type, status, tags, created) or is added to the end of a note that already covers it, with links to
//!   related notes. Open to-dos go only into the tasks note, each linked to the note it belongs to. The model tidies
//!   the owner's words lightly (broken handwriting lines joined, slips fixed); drawing embeds and to-do lines never
//!   reach a filed note. Then the inbox note and its drawing are deleted. A note with no `review` at all (one saved
//!   from chat) files too; one still `pending` waits.
//! - `discard` deletes a note marked `review: delete`, with its drawing.
//!
//! Nothing but the inbox note, its drawing and the end of the tasks note and of the notes pieces are added to is
//! changed, and everything is checked before anything is.

use crate::library::Library;
use crate::note::{Note, quoted, set_field};
use crate::write::{note_name, replace, write_new};
use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::{Value, json};
use std::fs;
use std::sync::LazyLock;

const TYPES: &[&str] = &["idea", "project", "reference"];
const STATUSES: &[&str] = &["open", "parked", "in-progress", "done", "dropped"];

// An unchecked to-do: "- [ ] …" or "* [ ] …", indented or not.
static TODO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*[-*+] \[ \]\s+(.+?)\s*$").unwrap());
// A to-do in the tasks note, ticked or not, and the note it links to at its end: "- [x] Call Bob ([[Dentist]])".
static TASK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*[-*+] \[([ xX])\]\s+.*?(?:\(\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]\))?\s*$").unwrap());
// An embedded drawing: ![[….excalidraw]] (with or without .md, a size or a heading).
static DRAWING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"!\[\[[^\]]*\.excalidraw[^\]]*\]\]").unwrap());

/// One note an inbox note is split into, as the model chose it: a new note (`to`) or an addition to an existing one
/// (`into`).
pub struct Piece<'a> {
    /// A new note's path: folder and name.
    pub to: Option<&'a str>,
    /// An existing note this piece is added to: its path or name.
    pub into: Option<&'a str>,
    /// A new note's type, status and tags.
    pub kind: Option<&'a str>,
    pub status: Option<&'a str>,
    pub tags: &'a [String],
    /// The piece's text, in the owner's words, lightly tidied.
    pub text: &'a str,
    /// Notes to link to from it.
    pub related: &'a [String],
    /// Its open to-dos, for the tasks note.
    pub todos: &'a [String],
}

/// How an inbox note is filed.
pub struct Filing<'a> {
    pub inbox: &'a str,
    pub tasks: &'a str,
    pub note: &'a str,
    pub pieces: &'a [Piece<'a>],
    /// To-dos that belong to no piece.
    pub todos: &'a [String],
    /// YYYY-MM-DD for new notes; default: the day it was transcribed, else today.
    pub created: Option<&'a str>,
}

/// A piece, checked and ready to write.
struct Planned {
    /// Where it's written, relative to the vault.
    rel: String,
    /// The note's name, for links.
    name: String,
    /// A new note's whole text, or what's appended to an existing one.
    text: String,
    new: bool,
    todos: Vec<String>,
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
        if f.pieces.is_empty() && f.todos.iter().all(|t| t.trim().is_empty()) {
            bail!("nothing to file: give the notes it splits into (pieces), its to-dos, or both");
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
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let tasks_rel = if f.tasks.ends_with(".md") { f.tasks.to_string() } else { format!("{}.md", f.tasks) };

        // Every piece checked before anything changes.
        let mut planned: Vec<Planned> = Vec::new();
        for (i, p) in f.pieces.iter().enumerate() {
            let which = format!("piece {}", i + 1);
            let (text, mut todos) = take_todos(&DRAWING.replace_all(p.text, ""));
            let text = text.trim().to_string();
            todos.extend(p.todos.iter().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()));
            if text.is_empty() {
                bail!("{which} has no text: a to-do on its own goes in todos, not in a piece");
            }
            let (target, name, new) = match (p.to.map(str::trim), p.into.map(str::trim)) {
                (Some(to), None) => {
                    let to = to.trim_end_matches('/');
                    let to_rel = if to.ends_with(".md") { to.to_string() } else { format!("{to}.md") };
                    let (folder, name) = to_rel.rsplit_once('/').map_or(("", to_rel.as_str()), |(d, n)| (d, n));
                    let name = note_name(name)?;
                    if folder.is_empty() || folder.split('/').next() == Some(f.inbox) || folder.starts_with('_') {
                        bail!("{which}: {to_rel}: put it in a folder of the vault (Ideas, Projects/…, Reference…), not the top, the inbox or a _ folder");
                    }
                    if to_rel.eq_ignore_ascii_case(&tasks_rel) {
                        bail!("{which}: {to_rel} is the tasks note; to-dos go in todos");
                    }
                    if self.new_path(&to_rel)?.exists() {
                        bail!("{which}: {to_rel} already exists: add to it with into, or pick another name");
                    }
                    if let Some(existing) = self.named(&name)? {
                        bail!("{which}: a note called {name} already exists ({existing}): add to it with into, or pick another name");
                    }
                    if planned.iter().any(|q| q.name.eq_ignore_ascii_case(&name)) {
                        bail!("{which}: two pieces are both called {name}");
                    }
                    (to_rel, name, true)
                }
                (None, Some(into)) => {
                    let path = self.find(into).with_context(|| format!("{which}: the note to add to"))?;
                    let into_rel = self.show(&path);
                    if into_rel.split('/').next() == Some(f.inbox) || into_rel.starts_with('_') || !into_rel.ends_with(".md") {
                        bail!("{which}: {into_rel} can't be added to: only notes filed in the vault");
                    }
                    if into_rel.eq_ignore_ascii_case(&tasks_rel) {
                        bail!("{which}: {into_rel} is the tasks note; to-dos go in todos");
                    }
                    let name = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                    (into_rel, name, false)
                }
                _ => bail!("{which}: give either to (a new note) or into (an existing note), not both or neither"),
            };
            let mut related = Vec::new();
            for r in p.related {
                let path = self.find(r).with_context(|| format!("{which}: related note {r}"))?;
                let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                if !stem.eq_ignore_ascii_case(&name) && self.show(&path) != rel && !related.contains(&stem) {
                    related.push(stem);
                }
            }
            let links = |already: &str| -> String {
                let fresh: Vec<String> =
                    related.iter().filter(|r| !already.contains(&format!("[[{r}]]"))).map(|r| format!("[[{r}]]")).collect();
                if fresh.is_empty() { String::new() } else { format!("\nRelated: {}\n", fresh.join(", ")) }
            };
            let body = if new {
                let kind = p.kind.map(str::trim).unwrap_or("");
                if !TYPES.contains(&kind) {
                    bail!("{which}: type must be one of {}", TYPES.join(", "));
                }
                let status = match (kind, p.status.map(str::trim).filter(|s| !s.is_empty())) {
                    ("reference", _) => None,
                    (_, Some(s)) if STATUSES.contains(&s) => Some(s),
                    (_, Some(s)) => bail!("{which}: status {s:?} isn't one of {}", STATUSES.join(", ")),
                    (_, None) => bail!("{which}: an {kind} needs a status: one of {}", STATUSES.join(", ")),
                };
                format!("{}{text}\n{}", front_matter(kind, status, p.tags, &created, None), links(""))
            } else {
                let existing = fs::read_to_string(self.root.join(&target)).with_context(|| format!("reading {target}"))?;
                format!("\n## Added {today}\n\n{text}\n{}", links(&existing))
            };
            planned.push(Planned { rel: target, name, text: body, new, todos });
        }
        let loose: Vec<String> = f.todos.iter().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect();

        // Then the writes: the notes, the to-dos, and last the inbox note and its drawing.
        let mut created_notes = Vec::new();
        let mut added_to = Vec::new();
        for p in &planned {
            let path = self.root.join(&p.rel);
            if p.new {
                if let Some(dir) = path.parent() {
                    fs::create_dir_all(dir).with_context(|| format!("making the folder for {}", p.rel))?;
                }
                write_new(&path, &p.text)?;
                created_notes.push(p.rel.clone());
            } else {
                let mut raw = fs::read_to_string(&path)?;
                if !raw.ends_with('\n') {
                    raw.push('\n');
                }
                raw.push_str(&p.text);
                replace(&path, &raw)?;
                added_to.push(p.rel.clone());
            }
        }
        let mut todos_moved = Vec::new();
        for p in &planned {
            if !p.todos.is_empty() {
                self.add_tasks(f.tasks, &p.todos, Some(&p.name))?;
                todos_moved.extend(p.todos.iter().map(|t| format!("{t} ([[{}]])", p.name)));
            }
        }
        if !loose.is_empty() {
            self.add_tasks(f.tasks, &loose, None)?;
            todos_moved.extend(loose.iter().cloned());
        }
        let deleted = self.delete_with_drawing(&rel, &raw)?;
        Ok(json!({
            "filed": rel,
            "new_notes": created_notes,
            "added_to": added_to,
            "todos_moved_to": if todos_moved.is_empty() { Value::Null } else { json!(f.tasks) },
            "todos": todos_moved,
            "deleted": deleted,
        }))
    }

    /// Appends to-dos to the tasks note, newest last, each linked to the note it belongs to; makes the note if needed.
    fn add_tasks(&self, tasks: &str, todos: &[String], from: Option<&str>) -> Result<()> {
        let path = self.new_path(tasks)?;
        let lines: String = todos
            .iter()
            .map(|t| match from {
                Some(from) => format!("- [ ] {t} ([[{from}]])\n"),
                None => format!("- [ ] {t}\n"),
            })
            .collect();
        if path.exists() {
            let mut raw = fs::read_to_string(&path)?;
            if !raw.ends_with('\n') {
                raw.push('\n');
            }
            raw.push_str(&lines);
            replace(&path, &raw)
        } else {
            if let Some(dir) = path.parent() {
                fs::create_dir_all(dir)?;
            }
            let today = chrono::Local::now().format("%Y-%m-%d");
            write_new(
                &path,
                &format!("---\ntype: reference\ntags:\n  - tasks\ncreated: {today}\n---\n# Tasks\n\nTo-dos from filed notes, newest last.\n\n{lines}"),
            )
        }
    }

    /// Clears the to-dos the owner ticked in the tasks note, and finishes the notes they belonged to: a note whose
    /// to-dos are all ticked gets `status: done` (an idea or project) and moves to the archive, keeping its folder
    /// ("Projects/Minecraft server/Minecraft server" → "Archive/Projects/Minecraft server/Minecraft server"), with
    /// links to it fixed. The tick is the owner's approval. A note with a to-do still open stays where it is.
    pub fn clear_done(&self, tasks: &str, archive: &str) -> Result<Value> {
        let tasks = &if tasks.ends_with(".md") { tasks.to_string() } else { format!("{tasks}.md") };
        let tasks_path = self.new_path(tasks)?;
        if !tasks_path.exists() {
            return Ok(json!({ "cleared": [], "archived": [], "left": [] }));
        }
        let raw = fs::read_to_string(&tasks_path).with_context(|| format!("reading {tasks}"))?;
        let archive = archive.trim().trim_end_matches('/');

        let (mut done, mut open, mut cleared) = (Vec::<String>::new(), Vec::<String>::new(), Vec::<String>::new());
        let mut kept = String::new();
        for line in raw.lines() {
            match TASK.captures(line) {
                Some(c) if &c[1] != " " => {
                    cleared.push(line.trim().to_string());
                    if let Some(note) = c.get(2) {
                        done.push(note.as_str().trim().to_string());
                    }
                }
                Some(c) => {
                    if let Some(note) = c.get(2) {
                        open.push(note.as_str().trim().to_lowercase());
                    }
                    kept.push_str(line);
                    kept.push('\n');
                }
                None => {
                    kept.push_str(line);
                    kept.push('\n');
                }
            }
        }
        if cleared.is_empty() {
            return Ok(json!({ "cleared": [], "archived": [], "left": [] }));
        }

        // Which notes are finished, and where they go: all checked before anything moves.
        let mut moves: Vec<(String, String)> = Vec::new();
        let mut left = Vec::new();
        let mut seen = Vec::new();
        for name in done {
            let key = name.to_lowercase();
            if seen.contains(&key) {
                continue;
            }
            seen.push(key.clone());
            if open.contains(&key) {
                left.push(format!("{name}: a to-do is still open"));
                continue;
            }
            let Ok(path) = self.find(&name) else {
                left.push(format!("{name}: no such note"));
                continue;
            };
            let rel = self.show(&path);
            if rel.split('/').next() == Some(archive) {
                continue;
            }
            if rel.starts_with('_') || rel.eq_ignore_ascii_case(tasks) {
                left.push(format!("{rel}: not a note to archive"));
                continue;
            }
            let to = format!("{archive}/{rel}");
            if self.new_path(&to)?.exists() {
                left.push(format!("{rel}: {to} already exists"));
                continue;
            }
            moves.push((rel, to));
        }

        let mut archived = Vec::new();
        for (rel, to) in &moves {
            let path = self.root.join(rel);
            let note_raw = fs::read_to_string(&path).with_context(|| format!("reading {rel}"))?;
            let kind = Note::parse(&note_raw).get("type").map(|t| t.trim().to_lowercase());
            if matches!(kind.as_deref(), Some("idea" | "project"))
                && let Some(updated) = set_field(&note_raw, "status", "done")
            {
                replace(&path, &updated)?;
            }
            let moved = self.move_note(rel, to)?;
            archived.push(json!({ "from": rel, "to": moved["to"] }));
        }
        replace(&tasks_path, &kept)?;
        Ok(json!({ "cleared": cleared, "archived": archived, "left": left }))
    }

    /// Deletes an inbox note marked `review: delete`, and the drawing in its `source:` (the .excalidraw.md and its
    /// exported .png).
    pub fn discard(&self, inbox: &str, note: &str) -> Result<Value> {
        let (rel, raw, review) = self.reviewed(inbox, note)?;
        if review.as_deref() != Some("delete") {
            bail!("{rel} isn't marked review: delete; only notes the owner marked that way are deleted");
        }
        Ok(json!({ "deleted": self.delete_with_drawing(&rel, &raw)? }))
    }

    /// Deletes an inbox note and the drawing in its `source:` (the .excalidraw.md and its exported .png).
    fn delete_with_drawing(&self, rel: &str, raw: &str) -> Result<Vec<String>> {
        let mut deleted = Vec::new();
        if let Some(link) = Note::parse(raw).source_link()
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
        fs::remove_file(self.root.join(rel)).with_context(|| format!("deleting {rel}"))?;
        deleted.insert(0, rel.to_string());
        Ok(deleted)
    }
}

/// The text with its unchecked to-dos taken out, and the to-dos.
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
            Some(c) => todos.push(c[1].to_string()),
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
