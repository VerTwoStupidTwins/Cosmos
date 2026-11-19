//! The one thing that deletes anything: an inbox note the transcriber or Hermes' notes-capture
//! plugin wrote, with the drawing it was transcribed from or the recording it came from. Used for
//! notes the owner marked `review: delete` (by `notes nightly`) and notes Hermes has filed into the
//! vault, `review: filed` (by `notes watch`).

use crate::note::Note;
use anyhow::{Result, bail};
use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path};

const AUDIO: &[&str] = &[
    "ogg", "oga", "opus", "mp3", "m4a", "wav", "aac", "webm", "flac",
];

/// Deletes the note and what it came from; says what was removed.
pub fn remove(vault: &Path, note_path: &Path) -> Result<String> {
    let inbox = vault.join("Inbox");
    let shown = note_path
        .strip_prefix(vault)
        .unwrap_or(note_path)
        .display()
        .to_string();
    if note_path.parent() != Some(inbox.as_path())
        || note_path.extension().is_none_or(|e| e != "md")
        || !is_plain(note_path.strip_prefix(vault).unwrap_or(note_path))
        || !note_path.is_file()
    {
        bail!("{shown} is not a note in the inbox, so it was kept");
    }
    let raw = fs::read_to_string(note_path)?;
    let note = Note::parse(&raw);
    if !note.is_generated() {
        bail!("{shown} wasn't written by the transcriber or notes-capture, so it was kept");
    }

    let message = match note.source_link() {
        Some(link) if is_plain(Path::new(&link)) => {
            if link.ends_with(".excalidraw") {
                delete(&vault.join(format!("{link}.md")))?;
                delete(&vault.join(format!("{link}.png")))?;
                format!("removed {shown} and its drawing {link}")
            } else if is_recording(&link) {
                delete(&vault.join(&link))?;
                format!("removed {shown} and its recording {link}")
            } else {
                format!(
                    "removed {shown} (its source, {link}, isn't a drawing or recording, so nothing else was)"
                )
            }
        }
        Some(link) => format!(
            "removed {shown} (its source, {link}, isn't a path in the vault, so nothing else was)"
        ),
        None => format!("removed {shown}"),
    };
    delete(note_path)?;
    Ok(message)
}

/// A relative path that stays where it points: no `..`, no root.
fn is_plain(path: &Path) -> bool {
    path.components().all(|c| matches!(c, Component::Normal(_)))
}

/// Voice/<file>.<audio extension>, where notes-capture keeps recordings.
fn is_recording(link: &str) -> bool {
    let path = Path::new(link);
    let mut parts = path.components();
    matches!(parts.next(), Some(Component::Normal(d)) if d == "Voice")
        && parts.next().is_some()
        && parts.next().is_none()
        && path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| AUDIO.contains(&e.to_ascii_lowercase().as_str()))
}

/// Like rm -f: a file already gone is fine.
fn delete(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

#[cfg(test)]
#[path = "remove_tests.rs"]
mod tests;
