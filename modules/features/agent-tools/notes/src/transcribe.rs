//! Transcribes handwritten Excalidraw drawings in the Notes vault into inbox notes.
//!
//! Every `Drawing X.excalidraw.png` (the PNG Excalidraw exports beside each drawing) gets a note,
//! `Inbox/Drawing X.md`: the model's transcription, then the drawing embedded for checking. The
//! owner reviews it there. A note is found wherever it went by its `source:` link, and every PNG
//! transcribed is remembered, so:
//! - an unchanged PNG is never sent again, and a deleted note stays deleted;
//! - a changed PNG updates its note where it is, unless the note was edited since (by the owner or
//!   the agent): then the edits stay and the note is marked `transcription: outdated` instead;
//! - a changed PNG whose note was deleted gets a new note in the inbox.
//!
//! The owner checks each transcription in Obsidian; `review` (pending, accept, delete) is for the
//! agent's nightly filing.

use crate::note::{Note, fingerprint, quoted, set_field};
use anyhow::{Context, Result, bail};
use base64::Engine;
use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

/// Reads handwriting.
pub trait Model {
    fn transcribe(&self, png: &[u8]) -> Result<String>;
}

/// The main model through llama-swap's OpenAI-style chat completions.
pub struct Http {
    agent: ureq::Agent,
    pub api: String,
    pub model: String,
    /// The rules, as the system prompt.
    pub prompt: String,
    /// The rules again, shorter, beside the image: this model follows those more closely.
    pub request: String,
}

impl Http {
    pub fn new(api: String, model: String, prompt: String, request: String) -> Self {
        // Covers loading the main model after another one had the card.
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(300))
            .build();
        Http {
            agent,
            api,
            model,
            prompt,
            request,
        }
    }
}

impl Model for Http {
    fn transcribe(&self, png: &[u8]) -> Result<String> {
        let image = base64::engine::general_purpose::STANDARD.encode(png);
        let body = json!({
            "model": self.model,
            "temperature": 0,
            // With thinking on, the whole transcription sometimes arrived as reasoning, with an
            // empty reply.
            "chat_template_kwargs": { "enable_thinking": false },
            "messages": [
                { "role": "system", "content": self.prompt },
                { "role": "user", "content": [
                    { "type": "image_url", "image_url": { "url": format!("data:image/png;base64,{image}") } },
                    { "type": "text", "text": self.request },
                ] },
            ],
        });
        let response: Value = self.agent.post(&self.api).send_json(body)?.into_json()?;
        Ok(reply_text(&response))
    }
}

/// The reply, or the reasoning if the reply came back empty anyway.
pub fn reply_text(response: &Value) -> String {
    let message = &response["choices"][0]["message"];
    let content = message["content"].as_str().unwrap_or("");
    if !content.trim().is_empty() {
        return content.to_string();
    }
    message["reasoning_content"]
        .as_str()
        .unwrap_or("")
        .to_string()
}

/// Code fences, which would hide the Markdown in Obsidian, go; a bare `[sketch: …]` or
/// `[no writing]` line gets its italics.
pub fn tidy(text: &str) -> String {
    let lines: Vec<String> = text
        .lines()
        .filter(|l| !l.trim_start().starts_with("```"))
        .map(|l| {
            let t = l.trim();
            let bracketed = t.starts_with('[') && t.ends_with(']');
            if bracketed && (t.starts_with("[sketch:") || t == "[no writing]") {
                format!("_{t}_")
            } else {
                l.to_string()
            }
        })
        .collect();
    lines.join("\n").trim().to_string()
}

/// What happened to a drawing.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// Its note is up to date.
    Unchanged,
    /// Its note was deleted after it was transcribed.
    Forgotten,
    /// A note with this source that the service didn't write.
    NotOurs(PathBuf),
    /// The drawing changed after its note was edited.
    MarkedOutdated(PathBuf),
    AlreadyOutdated(PathBuf),
    /// The model saw nothing to write.
    Empty,
    Wrote(PathBuf),
}

pub struct Vault {
    pub root: PathBuf,
    /// The fingerprints of every PNG transcribed, one per line.
    pub seen: PathBuf,
}

impl Vault {
    fn show(&self, path: &Path) -> String {
        path.strip_prefix(&self.root)
            .unwrap_or(path)
            .display()
            .to_string()
    }

    pub fn transcribe(&self, png: &Path, model: &dyn Model) -> Result<Outcome> {
        let rel = png
            .strip_prefix(&self.root)
            .context("the drawing isn't in the vault")?;
        let rel = rel.to_str().context("the drawing's path isn't UTF-8")?;
        let Some(link) = rel.strip_suffix(".png") else {
            bail!("{rel} isn't a PNG")
        };
        let file_name = png.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        let Some(name) = file_name.strip_suffix(".excalidraw.png") else {
            bail!("{rel} isn't an Excalidraw export")
        };

        let bytes = fs::read(png)?;
        let png_hash = fingerprint(&bytes);

        let target = match self.find_note(link)? {
            Some(path) => {
                let raw = fs::read_to_string(&path)?;
                let note = Note::parse(&raw);
                if !note.is_generated() {
                    return Ok(Outcome::NotOurs(path));
                }
                if note.get("png-sha256").is_some_and(|h| h.trim() == png_hash) {
                    return Ok(Outcome::Unchanged);
                }
                if note.is_edited() {
                    if note.is("transcription", "outdated") {
                        return Ok(Outcome::AlreadyOutdated(path));
                    }
                    let marked = set_field(&raw, "transcription", "outdated")
                        .context("the note lost its front matter")?;
                    write_atomic(&path, &marked)?;
                    return Ok(Outcome::MarkedOutdated(path));
                }
                path
            }
            None => {
                if self.was_seen(&png_hash)? {
                    return Ok(Outcome::Forgotten);
                }
                free_name(&self.root.join("Inbox"), name)
            }
        };

        let text = tidy(&model.transcribe(&bytes)?);
        if text.is_empty() {
            return Ok(Outcome::Empty);
        }
        let body = format!("{text}\n\n![[{link}]]\n");
        let content = [
            "---".to_string(),
            format!("source: {}", quoted(&format!("[[{link}]]"))),
            "tags: [handwritten]".to_string(),
            format!(
                "transcribed: {}",
                chrono::Local::now().format("%Y-%m-%d %H:%M")
            ),
            "transcription: current".to_string(),
            // The owner changes it to accept or delete once the transcription is right; the agent's nightly
            // filing acts on it.
            "review: pending".to_string(),
            format!("png-sha256: {png_hash}"),
            format!("text-sha256: {}", fingerprint(body.as_bytes())),
            "---".to_string(),
            body,
        ]
        .join("\n");
        write_atomic(&target, &content)?;
        self.remember(&png_hash)?;
        Ok(Outcome::Wrote(target))
    }

    /// Acts on one changed file, logging what happened.
    pub fn handle(&self, path: &Path, model: &dyn Model) {
        let Ok(rel) = path.strip_prefix(&self.root) else {
            return;
        };
        // Obsidian's settings, and the temporary files written here.
        if rel
            .components()
            .any(|c| c.as_os_str().to_string_lossy().starts_with('.'))
            || !path.is_file()
        {
            return;
        }
        if !path.to_string_lossy().ends_with(".excalidraw.png") {
            return;
        }
        let shown = self.show(path);
        match self.transcribe(path, model) {
            Ok(Outcome::Wrote(note)) => eprintln!("wrote {} from {shown}", self.show(&note)),
            Ok(Outcome::MarkedOutdated(note)) => {
                eprintln!(
                    "{}: edited since it was written, so marked outdated instead of replaced",
                    self.show(&note)
                )
            }
            Ok(Outcome::NotOurs(note)) => eprintln!(
                "{}: not one of this service's notes, left alone",
                self.show(&note)
            ),
            Ok(Outcome::Empty) => eprintln!("{shown}: empty transcription, skipped"),
            Ok(_) => {}
            Err(e) => eprintln!(
                "{shown}: {e:#}; it will be tried again when it next changes or the service restarts"
            ),
        }
    }

    /// Every drawing as it is now.
    pub fn catch_up(&self, model: &dyn Model) -> Result<()> {
        for png in self.files(|name| name.ends_with(".excalidraw.png"))? {
            self.handle(&png, model);
        }
        Ok(())
    }

    /// The note whose source is this drawing, wherever it is in the vault.
    fn find_note(&self, link: &str) -> Result<Option<PathBuf>> {
        for path in self.files(|name| name.ends_with(".md") && !name.ends_with(".excalidraw.md"))? {
            let Ok(raw) = fs::read_to_string(&path) else {
                continue;
            };
            if Note::parse(&raw).source_link().as_deref() == Some(link) {
                return Ok(Some(path));
            }
        }
        Ok(None)
    }

    /// Files in the vault whose names pass `keep`, in order, leaving out hidden files and folders.
    fn files(&self, keep: impl Fn(&str) -> bool) -> Result<Vec<PathBuf>> {
        fn walk(dir: &Path, keep: &dyn Fn(&str) -> bool, out: &mut Vec<PathBuf>) -> Result<()> {
            let Ok(entries) = fs::read_dir(dir) else {
                return Ok(());
            };
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                let kind = entry.file_type()?;
                if kind.is_dir() {
                    walk(&entry.path(), keep, out)?;
                } else if kind.is_file() && keep(&name) {
                    out.push(entry.path());
                }
            }
            Ok(())
        }
        let mut out = Vec::new();
        walk(&self.root, &keep, &mut out)?;
        out.sort();
        Ok(out)
    }

    fn was_seen(&self, hash: &str) -> Result<bool> {
        match fs::read_to_string(&self.seen) {
            Ok(seen) => Ok(seen.lines().any(|l| l.trim() == hash)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    fn remember(&self, hash: &str) -> Result<()> {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.seen)?;
        writeln!(file, "{hash}")?;
        Ok(())
    }
}

/// dir/name.md, or dir/name 2.md, name 3.md…, whichever doesn't exist yet.
fn free_name(dir: &Path, name: &str) -> PathBuf {
    let mut candidate = dir.join(format!("{name}.md"));
    let mut n = 2;
    while candidate.exists() {
        candidate = dir.join(format!("{name} {n}.md"));
        n += 1;
    }
    candidate
}

/// Into place in one step, so the sync never uploads half a note.
fn write_atomic(path: &Path, content: &str) -> Result<()> {
    let dir = path.parent().context("no folder")?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.tmp",
        path.file_name().unwrap().to_string_lossy()
    ));
    fs::write(&tmp, content)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

/// Watches the vault for good, catching up first.
pub fn watch(vault: &Vault, model: &dyn Model) -> Result<()> {
    let (tx, rx) = mpsc::channel();
    // The sync writes a file and may touch it again straight after; events settle for two seconds.
    let mut debouncer = new_debouncer(Duration::from_secs(2), tx)?;
    // Watching first, so nothing exported during the catch-up is missed.
    debouncer
        .watcher()
        .watch(&vault.root, RecursiveMode::Recursive)?;
    vault.catch_up(model)?;
    for result in rx {
        match result {
            Ok(events) => {
                for event in events {
                    vault.handle(&event.path, model);
                }
            }
            Err(e) => eprintln!("watching the vault: {e}"),
        }
    }
    bail!("the vault watcher stopped")
}

#[cfg(test)]
#[path = "transcribe_tests.rs"]
mod tests;
