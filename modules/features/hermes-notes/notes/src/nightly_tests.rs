use super::*;
use crate::note::fingerprint;
use tempfile::TempDir;

fn generated(source: &str, review: &str) -> String {
    format!(
        "---\nsource: {source}\nreview: {review}\ntext-sha256: {}\n---\nx\n",
        fingerprint(b"x\n")
    )
}

fn write(vault: &Path, rel: &str, content: &str) {
    let path = vault.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, content).unwrap();
}

#[test]
fn deletes_rejected_lists_accepted_and_leaves_the_rest() {
    let dir = TempDir::new().unwrap();
    let v = dir.path();
    write(v, "Excalidraw/A.excalidraw.md", "drawing");
    write(v, "Excalidraw/A.excalidraw.png", "png");
    write(
        v,
        "Inbox/A.md",
        &generated("\"[[Excalidraw/A.excalidraw]]\"", "delete"),
    );
    write(v, "Inbox/B.md", &generated("chat", "Accept"));
    write(v, "Inbox/C.md", &generated("chat", "pending"));
    write(v, "Inbox/D.md", "---\nreview: delete\n---\nnot generated\n");
    write(v, "Inbox/E.md", &generated("chat", "filed"));

    let out = run(v).unwrap();
    let b = v.join("Inbox/B.md");
    assert_eq!(
        out,
        format!(
            "Inbox notes deleted at the owner's request: 1\n- A.md\n\n\
             Accepted inbox notes to ingest with the notes-ingest skill: 1\n- {}\n",
            b.display()
        )
    );
    assert!(!v.join("Inbox/A.md").exists());
    assert!(!v.join("Excalidraw/A.excalidraw.png").exists());
    for kept in ["B", "C", "D", "E"] {
        assert!(v.join(format!("Inbox/{kept}.md")).exists(), "{kept}");
    }
}

#[test]
fn an_empty_or_missing_inbox_says_so() {
    let dir = TempDir::new().unwrap();
    let expected = "Inbox notes deleted at the owner's request: 0\n\n\
                    Accepted inbox notes to ingest with the notes-ingest skill: 0\n";
    assert_eq!(run(dir.path()).unwrap(), expected);
    fs::create_dir(dir.path().join("Inbox")).unwrap();
    assert_eq!(run(dir.path()).unwrap(), expected);
}
