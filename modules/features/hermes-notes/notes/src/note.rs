//! Notes as files: front matter, body, and the fingerprint of a body.

use regex::Regex;
use sha2::{Digest, Sha256};
use std::sync::LazyLock;
use yaml_rust2::{Yaml, YamlLoader};

// The front matter, possibly empty, between a first line of --- and the next line of ---.
static FRONT_MATTER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?s)\A---[ \t]*\r?\n(?:(.*?)\r?\n)?---[ \t]*(?:\r?\n|\z)").unwrap()
});

/// A note's front matter fields and body. A note without front matter, or with front matter that
/// isn't a YAML mapping, has no fields: nothing here acts on such a note.
pub struct Note<'a> {
    fields: Option<yaml_rust2::yaml::Hash>,
    /// Everything after the front matter, as written.
    pub body: &'a str,
}

impl<'a> Note<'a> {
    pub fn parse(raw: &'a str) -> Self {
        let Some(m) = FRONT_MATTER.captures(raw) else {
            return Note {
                fields: None,
                body: raw,
            };
        };
        let body = &raw[m.get(0).unwrap().end()..];
        let yaml = m.get(1).map_or("", |g| g.as_str());
        let fields = match YamlLoader::load_from_str(yaml) {
            Ok(docs) => match docs.into_iter().next() {
                Some(Yaml::Hash(h)) => Some(h),
                // Empty front matter.
                None | Some(Yaml::Null) => Some(Default::default()),
                Some(_) => None,
            },
            Err(_) => None,
        };
        Note { fields, body }
    }

    /// A scalar field as text (numbers and booleans too), or None when it's missing, empty or a list.
    pub fn get(&self, key: &str) -> Option<String> {
        let value = self.fields.as_ref()?.get(&Yaml::String(key.to_string()))?;
        let text = match value {
            Yaml::String(s) | Yaml::Real(s) => s.clone(),
            Yaml::Integer(i) => i.to_string(),
            Yaml::Boolean(b) => b.to_string(),
            _ => return None,
        };
        (!text.trim().is_empty()).then_some(text)
    }

    /// A field compared loosely, as the owner might type it: "Accept ", "accept" and "ACCEPT" agree.
    pub fn is(&self, key: &str, value: &str) -> bool {
        self.get(key)
            .is_some_and(|v| v.trim().eq_ignore_ascii_case(value))
    }

    /// The drawing or recording in `source: "[[…]]"`, without the brackets.
    pub fn source_link(&self) -> Option<String> {
        let source = self.get("source")?;
        let inner = source.trim().strip_prefix("[[")?.strip_suffix("]]")?;
        Some(inner.to_string())
    }

    /// Whether the transcriber or Hermes' notes-capture plugin wrote it: both record the body's
    /// fingerprint, and nothing deletes or replaces a note without one.
    pub fn is_generated(&self) -> bool {
        self.get("text-sha256").is_some()
    }

    /// Whether the body has been edited since it was written.
    pub fn is_edited(&self) -> bool {
        self.get("text-sha256")
            .is_some_and(|h| h.trim() != fingerprint(self.body.as_bytes()))
    }
}

pub fn fingerprint(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// `raw` with a top-level front matter field set to a plain value, changing only that line (or
/// adding it at the end of the front matter), so the rest stays as the owner or Obsidian wrote it.
/// None when the note has no front matter.
pub fn set_field(raw: &str, key: &str, value: &str) -> Option<String> {
    let m = FRONT_MATTER.captures(raw)?;
    let whole = m.get(0).unwrap();
    let line = format!("{key}: {value}");
    let mut lines: Vec<String> = match m.get(1) {
        Some(yaml) => yaml.as_str().lines().map(str::to_string).collect(),
        None => Vec::new(),
    };
    let prefix = format!("{key}:");
    match lines.iter_mut().find(|l| l.starts_with(&prefix)) {
        Some(existing) => *existing = line,
        None => lines.push(line),
    }
    let mut out = String::from("---\n");
    for l in &lines {
        out.push_str(l);
        out.push('\n');
    }
    out.push_str("---\n");
    out.push_str(&raw[whole.end()..]);
    Some(out)
}

/// A YAML double-quoted string.
pub fn quoted(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
#[path = "note_tests.rs"]
mod tests;
