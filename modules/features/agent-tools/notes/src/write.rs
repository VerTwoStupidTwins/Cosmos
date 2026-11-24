//! Writing to the vault: a new note in its inbox, an exact edit of a note, and moving or renaming a note (with the
//! links to it fixed). Nothing is ever deleted: retiring a note is a move to the vault's archive. Paths get the same
//! checks as reading (relative, nothing hidden, never through a symlink), and every file is written whole and then
//! put in place, so Obsidian Sync never picks up half a note. New files are group-writable, so the sync service (in
//! the same group) can change them in turn.

use crate::library::{LINK, Library};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

/// Characters Obsidian won't have in a note's name (or that would break a [[link]] to it).
const BAD_NAME: &[char] = &['/', '\\', ':', '[', ']', '#', '^', '|', '*', '"', '<', '>', '?'];

impl Library {
    /// A new note in the inbox. `name` is its name (no folder; ".md" optional), `content` the whole note,
    /// properties included. Names are unique across the vault, since links go by name.
    pub fn create(&self, inbox: &str, name: &str, content: &str) -> Result<Value> {
        let name = note_name(name)?;
        if let Some(existing) = self.named(&name)? {
            bail!("a note called {name} already exists ({existing}): read it, or pick another name");
        }
        let path = self.new_path(&format!("{inbox}/{name}.md"))?;
        write_new(&path, content)?;
        Ok(json!({ "created": self.show(&path) }))
    }

    /// Replaces `old`, which must appear exactly once in the note, with `new`.
    pub fn edit(&self, note: &str, old: &str, new: &str) -> Result<Value> {
        if old.is_empty() {
            bail!("say which text to replace: old can't be empty");
        }
        if old == new {
            bail!("old and new are the same: nothing to change");
        }
        let path = self.find(note)?;
        let raw = fs::read_to_string(&path).with_context(|| format!("{note} can't be read as text"))?;
        let rel = self.show(&path);
        match raw.matches(old).count() {
            0 => {
                bail!("{rel} doesn't contain that text (it may have changed): read it again and copy the text exactly")
            }
            1 => {}
            n => bail!("that text is in {rel} {n} times: include more of the text around it so it's found once"),
        }
        replace(&path, &raw.replacen(old, new, 1))?;
        Ok(json!({ "edited": rel }))
    }

    /// Moves `note` to `to` (a path in the vault, ".md" optional), making folders as needed. When its name changes,
    /// every link to it is changed to the new name.
    pub fn move_note(&self, note: &str, to: &str) -> Result<Value> {
        let from = self.find(note)?;
        let from_rel = self.show(&from);
        let to = to.trim().trim_end_matches('/');
        let to_rel = if to.ends_with(".md") {
            to.to_string()
        } else {
            format!("{to}.md")
        };
        let new_name = note_name(
            Path::new(&to_rel)
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default()
                .as_str(),
        )?;
        let old_name = Path::new(&from_rel)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let dest = self.new_path(&to_rel)?;
        if dest.exists() {
            bail!("{to_rel} already exists: pick another place or name");
        }
        if new_name != old_name
            && let Some(existing) = self.named(&new_name)?
        {
            bail!("a note called {new_name} already exists ({existing}): names are unique, pick another");
        }
        fs::create_dir_all(dest.parent().unwrap()).with_context(|| format!("making the folders for {to_rel}"))?;
        fs::rename(&from, &dest).with_context(|| format!("moving {from_rel}"))?;
        let dest_rel = self.show(&dest);

        // Links by name ([[Old]]) and by path ([[Folder/Old]]) both point at it; fix the ones that break.
        let mut relinked = Vec::new();
        let old_path = from_rel.trim_end_matches(".md").to_string();
        let new_path = dest_rel.trim_end_matches(".md").to_string();
        for found in self.notes_under(&self.root)? {
            let changed = relink(&found.raw, &old_name, &old_path, &new_name, &new_path);
            if changed != found.raw {
                replace(&self.root.join(&found.rel), &changed)?;
                relinked.push(found.rel);
            }
        }
        Ok(json!({ "moved": from_rel, "to": dest_rel, "links_updated_in": relinked }))
    }

    /// Where the note called `name` (any case) is, if there is one.
    fn named(&self, name: &str) -> Result<Option<String>> {
        let wanted = format!("{}.md", name.to_lowercase());
        Ok(self
            .notes_under(&self.root)?
            .into_iter()
            .map(|f| f.rel)
            .find(|rel| rel.rsplit('/').next().is_some_and(|n| n.to_lowercase() == wanted)))
    }

    /// A path for a file that may not exist yet: relative, nothing hidden, and none of the folders on the way a
    /// symlink (so it can't lead out of the vault).
    fn new_path(&self, rel: &str) -> Result<PathBuf> {
        let rel = rel.trim().trim_start_matches("./");
        let path = Path::new(rel);
        if rel.is_empty() || !rel.ends_with(".md") {
            bail!("{rel}: a note's path ends in .md");
        }
        let mut at = self.root.clone();
        for c in path.components() {
            match c {
                Component::Normal(part) if !part.to_string_lossy().starts_with('.') => {
                    at.push(part);
                    if let Ok(meta) = fs::symlink_metadata(&at)
                        && meta.file_type().is_symlink()
                    {
                        bail!("{rel} goes through a link: use a path inside the vault");
                    }
                }
                _ => bail!("{rel}: use a path inside the vault, like Inbox/Note.md"),
            }
        }
        Ok(at)
    }
}

/// A note's name, checked: what's left once ".md" is taken off, with nothing Obsidian can't use in a name.
fn note_name(name: &str) -> Result<String> {
    let name = name.trim().trim_end_matches(".md").trim();
    if name.is_empty() || name.starts_with('.') || name.contains(BAD_NAME) {
        bail!(
            "{name:?} can't be a note's name: no folder, no leading dot, and none of {}",
            BAD_NAME.iter().collect::<String>()
        );
    }
    Ok(name.to_string())
}

/// `text` with links to the old note pointed at the new one: by name where they used the name, by path where they
/// used the path. Their #heading and |shown text are kept.
pub fn relink(text: &str, old_name: &str, old_path: &str, new_name: &str, new_path: &str) -> String {
    LINK.replace_all(text, |c: &regex::Captures| {
        let whole = &c[0];
        let target = c[1].trim().trim_end_matches(".md");
        let replacement = if target.eq_ignore_ascii_case(old_path) {
            new_path
        } else if target.eq_ignore_ascii_case(old_name) {
            new_name
        } else {
            return whole.to_string();
        };
        whole.replacen(&c[1], replacement, 1)
    })
    .into_owned()
}

/// A temporary file beside `path` (hidden, so neither Obsidian nor its sync shows it), with `content`, group-writable.
fn temp_beside(path: &Path, content: &str) -> Result<PathBuf> {
    let dir = path.parent().context("no folder")?;
    let name = path.file_name().context("no name")?.to_string_lossy();
    let temp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let mut file = fs::File::create(&temp).with_context(|| format!("writing in {}", dir.display()))?;
    file.write_all(content.as_bytes())?;
    file.sync_all()?;
    fs::set_permissions(&temp, fs::Permissions::from_mode(0o660))?;
    Ok(temp)
}

/// Writes a new file, never over an existing one.
fn write_new(path: &Path, content: &str) -> Result<()> {
    fs::create_dir_all(path.parent().context("no folder")?)?;
    let temp = temp_beside(path, content)?;
    // A hard link fails if the name is taken, so a note that appeared meanwhile isn't overwritten.
    let linked = fs::hard_link(&temp, path);
    fs::remove_file(&temp)?;
    linked.with_context(|| format!("{} exists already", path.display()))
}

/// Replaces an existing file's content in one step.
fn replace(path: &Path, content: &str) -> Result<()> {
    let temp = temp_beside(path, content)?;
    fs::rename(&temp, path).with_context(|| format!("replacing {}", path.display()))
}

#[cfg(test)]
#[path = "write_tests.rs"]
mod tests;
