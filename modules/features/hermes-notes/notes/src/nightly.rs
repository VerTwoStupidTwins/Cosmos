//! Run by Hermes before the nightly notes-ingest job's agent; what it prints goes into the agent's
//! prompt. Deletes the inbox notes the owner marked `review: delete` (with their drawings or
//! recordings), then lists the ones marked `review: accept` for Hermes to file. Notes still
//! `pending`, or marked anything else, wait.

use crate::note::Note;
use crate::remove::remove;
use anyhow::Result;
use std::fmt::Write;
use std::fs;
use std::path::Path;

pub fn run(vault: &Path) -> Result<String> {
    let inbox = vault.join("Inbox");
    let mut notes: Vec<_> = match fs::read_dir(&inbox) {
        Ok(entries) => entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.extension().is_some_and(|e| e == "md")
                    && p.is_file()
                    && !p.file_name().unwrap().to_string_lossy().starts_with('.')
            })
            .collect(),
        Err(_) => Vec::new(),
    };
    notes.sort();

    let mut deleted = Vec::new();
    let mut accepted = Vec::new();
    for path in notes {
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        let note = Note::parse(&raw);
        if note.is("review", "delete") {
            match remove(vault, &path) {
                Ok(message) => {
                    eprintln!("{message}");
                    deleted.push(path.file_name().unwrap().to_string_lossy().into_owned());
                }
                Err(e) => eprintln!("notes nightly: {e}"),
            }
        } else if note.is("review", "accept") {
            accepted.push(path.display().to_string());
        }
    }

    let mut out = String::new();
    writeln!(
        out,
        "Inbox notes deleted at the owner's request: {}",
        deleted.len()
    )?;
    for name in &deleted {
        writeln!(out, "- {name}")?;
    }
    writeln!(out)?;
    writeln!(
        out,
        "Accepted inbox notes to ingest with the notes-ingest skill: {}",
        accepted.len()
    )?;
    for path in &accepted {
        writeln!(out, "- {path}")?;
    }
    Ok(out)
}

#[cfg(test)]
#[path = "nightly_tests.rs"]
mod tests;
