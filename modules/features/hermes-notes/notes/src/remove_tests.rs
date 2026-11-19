use super::*;
use crate::note::fingerprint;
use std::path::PathBuf;
use tempfile::TempDir;

pub fn generated(source: &str, review: &str, body: &str) -> String {
    format!(
        "---\nsource: {source}\nreview: {review}\ntext-sha256: {}\n---\n{body}",
        fingerprint(body.as_bytes())
    )
}

fn write(vault: &Path, rel: &str, content: &str) -> PathBuf {
    let path = vault.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, content).unwrap();
    path
}

fn files(vault: &Path) -> Vec<String> {
    let mut out = Vec::new();
    fn walk(dir: &Path, vault: &Path, out: &mut Vec<String>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(&path, vault, out);
            } else {
                out.push(path.strip_prefix(vault).unwrap().display().to_string());
            }
        }
    }
    walk(vault, vault, &mut out);
    out.sort();
    out
}

#[test]
fn removes_a_note_with_its_drawing() {
    let dir = TempDir::new().unwrap();
    let v = dir.path();
    write(v, "Excalidraw/A.excalidraw.md", "drawing");
    write(v, "Excalidraw/A.excalidraw.png", "png");
    write(v, "Excalidraw/B.excalidraw.png", "another drawing");
    let note = write(
        v,
        "Inbox/A.md",
        &generated("\"[[Excalidraw/A.excalidraw]]\"", "delete", "text\n"),
    );
    let message = remove(v, &note).unwrap();
    assert_eq!(
        message,
        "removed Inbox/A.md and its drawing Excalidraw/A.excalidraw"
    );
    assert_eq!(files(v), ["Excalidraw/B.excalidraw.png"]);
}

#[test]
fn removes_a_voice_note_with_its_recording() {
    let dir = TempDir::new().unwrap();
    let v = dir.path();
    write(v, "Voice/Voice 1.ogg", "audio");
    let note = write(
        v,
        "Inbox/Voice 1.md",
        &generated("\"[[Voice/Voice 1.ogg]]\"", "filed", "hi\n"),
    );
    assert!(
        remove(v, &note)
            .unwrap()
            .contains("its recording Voice/Voice 1.ogg")
    );
    assert!(files(v).is_empty());
}

#[test]
fn removes_a_note_whose_drawing_is_already_gone_or_has_none() {
    let dir = TempDir::new().unwrap();
    let v = dir.path();
    let a = write(
        v,
        "Inbox/A.md",
        &generated("\"[[Excalidraw/A.excalidraw]]\"", "delete", "x\n"),
    );
    let b = write(v, "Inbox/B.md", &generated("chat", "delete", "y\n"));
    remove(v, &a).unwrap();
    assert_eq!(remove(v, &b).unwrap(), "removed Inbox/B.md");
    assert!(files(v).is_empty());
}

#[test]
fn keeps_everything_but_the_note_when_the_source_points_elsewhere() {
    let dir = TempDir::new().unwrap();
    let v = dir.path();
    write(v, "Tasks.md", "precious");
    write(v, "Voice/deep/x.ogg", "audio");
    for (i, source) in [
        "\"[[../Tasks]]\"",
        "\"[[/etc/passwd]]\"",
        "\"[[Tasks.md]]\"",
        "\"[[Voice/deep/x.ogg]]\"",
        "\"[[Excalidraw/../Tasks.excalidraw]]\"",
    ]
    .iter()
    .enumerate()
    {
        let note = write(
            v,
            &format!("Inbox/{i}.md"),
            &generated(source, "delete", "x\n"),
        );
        remove(v, &note).unwrap();
    }
    assert_eq!(files(v), ["Tasks.md", "Voice/deep/x.ogg"]);
}

#[test]
fn refuses_notes_it_did_not_write_or_outside_the_inbox() {
    let dir = TempDir::new().unwrap();
    let v = dir.path();
    let mine = write(
        v,
        "Inbox/Mine.md",
        "---\nreview: delete\n---\nthe owner's own note\n",
    );
    let filed = write(v, "Notes/Filed.md", &generated("chat", "delete", "x\n"));
    let nested = write(v, "Inbox/sub/N.md", &generated("chat", "delete", "x\n"));
    let sneaky = v.join("Inbox/../Notes/Filed.md");
    let text = write(v, "Inbox/T.txt", &generated("chat", "delete", "x\n"));
    for path in [
        &mine,
        &filed,
        &nested,
        &sneaky,
        &text,
        &v.join("Inbox/missing.md"),
    ] {
        assert!(remove(v, path).is_err(), "{}", path.display());
    }
    assert_eq!(files(v).len(), 4);
}
