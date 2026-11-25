use super::*;
use tempfile::TempDir;

fn vault() -> (TempDir, Library) {
    let dir = TempDir::new().unwrap();
    let root = dir.path().join("vault");
    let write = |rel: &str, text: &str| {
        let path = root.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    };
    let transcribed = |review: &str, body: &str| {
        format!(
            "---\nsource: \"[[_attachments/Excalidraw/Drawing 1.excalidraw]]\"\ntags:\n  - handwritten\ntranscribed: 2026-11-23 11:43\ntranscription: current\nreview: {review}\npng-sha256: aa\ntext-sha256: bb\n---\n{body}"
        )
    };
    write("Inbox/Drawing 1.md", &transcribed("accept", "To do:\n- [ ] Set up Minecraft server\n- [x] Already done\n- [ ] Set up game streaming\n\nStudy for the cert.\n\n![[_attachments/Excalidraw/Drawing 1.excalidraw]]\n"));
    write("Inbox/Pending.md", &transcribed("pending", "not checked yet\n"));
    write("Inbox/Rejected.md", &transcribed("delete", "garbled\n"));
    write("Inbox/From chat.md", "---\ntype: idea\n---\nA quieter fan.\n");
    write("_attachments/Excalidraw/Drawing 1.excalidraw.md", "drawing data\n");
    write("_attachments/Excalidraw/Drawing 1.excalidraw.png", "png\n");
    write("Projects/Homelab/Homelab.md", "# Homelab\n");
    write("Daily/2026-11-23.md", "Wrote [[Drawing 1]] today.\n");
    (dir, Library { root })
}

fn filing<'a>(note: &'a str, to: &'a str, tags: &'a [String], related: &'a [String]) -> Filing<'a> {
    Filing { inbox: "Inbox", tasks: "Reference/Tasks.md", note, to, kind: "project", status: Some("open"), tags, created: None, related }
}

#[test]
fn an_accepted_note_is_filed_with_its_text_kept() {
    let (_dir, lib) = vault();
    let tags = vec!["homelab".to_string(), "#games".to_string()];
    let related = vec!["Homelab".to_string()];
    let out = lib.file(&filing("Drawing 1", "Projects/Homelab/Game servers", &tags, &related)).unwrap();
    assert_eq!(out["to"], "Projects/Homelab/Game servers.md");
    assert!(!lib.root.join("Inbox/Drawing 1.md").exists());

    let filed = fs::read_to_string(lib.root.join("Projects/Homelab/Game servers.md")).unwrap();
    let note = Note::parse(&filed);
    assert_eq!(note.get("type").as_deref(), Some("project"));
    assert_eq!(note.get("status").as_deref(), Some("open"));
    assert_eq!(note.list("tags"), ["homelab", "games"]);
    assert_eq!(note.get("created").as_deref(), Some("2026-11-23"), "the day it was transcribed");
    assert_eq!(note.source_link().as_deref(), Some("_attachments/Excalidraw/Drawing 1.excalidraw"), "the drawing stays linked");
    for gone in ["review", "transcribed", "transcription", "png-sha256", "text-sha256"] {
        assert!(note.get(gone).is_none(), "{gone} is the transcriber's, and goes");
    }
    assert!(!note.is_generated(), "the transcriber leaves a filed note alone");
    assert!(filed.contains("Study for the cert."), "the owner's text is kept");
    assert!(filed.contains("- [x] Already done"), "done to-dos stay");
    assert!(filed.contains("To-dos moved to [[Tasks]]."));
    assert!(!filed.contains("Minecraft"), "open to-dos move out");
    assert!(filed.trim_end().ends_with("Related: [[Homelab]]"));

    let tasks = fs::read_to_string(lib.root.join("Reference/Tasks.md")).unwrap();
    assert!(tasks.contains("- [ ] Set up Minecraft server ([[Game servers]])\n- [ ] Set up game streaming ([[Game servers]])\n"));
    let daily = fs::read_to_string(lib.root.join("Daily/2026-11-23.md")).unwrap();
    assert!(daily.contains("[[Game servers]]"), "links to it follow the new name");
}

#[test]
fn tasks_are_added_to_the_end_of_an_existing_tasks_note() {
    let (_dir, lib) = vault();
    fs::create_dir_all(lib.root.join("Reference")).unwrap();
    fs::write(lib.root.join("Reference/Tasks.md"), "# Tasks\n- [ ] older").unwrap();
    lib.file(&filing("Drawing 1", "Reference/Servers", &[], &[])).unwrap();
    let tasks = fs::read_to_string(lib.root.join("Reference/Tasks.md")).unwrap();
    assert!(tasks.starts_with("# Tasks\n- [ ] older\n- [ ] Set up Minecraft server ([[Servers]])\n"));
}

#[test]
fn only_accepted_or_unreviewed_inbox_notes_are_filed() {
    let (_dir, lib) = vault();
    let e = lib.file(&filing("Pending", "Ideas/P", &[], &[])).unwrap_err().to_string();
    assert!(e.contains("waits"), "{e}");
    let e = lib.file(&filing("Rejected", "Ideas/R", &[], &[])).unwrap_err().to_string();
    assert!(e.contains("discard"), "{e}");
    let e = lib.file(&filing("Homelab", "Ideas/H", &[], &[])).unwrap_err().to_string();
    assert!(e.contains("isn't in Inbox"), "{e}");
    let mut chat = filing("From chat", "Ideas/Quiet fan", &[], &[]);
    chat.kind = "idea";
    lib.file(&chat).unwrap();
    assert!(lib.root.join("Ideas/Quiet fan.md").exists(), "a note with no review mark files");
}

#[test]
fn filing_checks_everything_before_changing_anything() {
    let (_dir, lib) = vault();
    let original = fs::read_to_string(lib.root.join("Inbox/Drawing 1.md")).unwrap();
    for (to, why) in [
        ("Projects/Homelab/Homelab", "exists"),
        ("Ideas/Homelab", "unique"),
        ("Inbox/Elsewhere", "inbox"),
        ("Top level", "folder"),
        ("_templates/X", "folder"),
    ] {
        assert!(lib.file(&filing("Drawing 1", to, &[], &[])).is_err(), "{to} ({why}) should be refused");
    }
    let mut bad = filing("Drawing 1", "Ideas/X", &[], &[]);
    bad.kind = "idea";
    bad.status = Some("someday");
    assert!(lib.file(&bad).is_err(), "an unknown status");
    bad.status = None;
    assert!(lib.file(&bad).is_err(), "an idea needs a status");
    assert!(lib.file(&filing("Drawing 1", "Ideas/X", &[], &["No such note".to_string()])).is_err());
    assert_eq!(fs::read_to_string(lib.root.join("Inbox/Drawing 1.md")).unwrap(), original, "untouched");
    assert!(!lib.root.join("Reference/Tasks.md").exists());
}

#[test]
fn a_reference_note_has_no_status() {
    let (_dir, lib) = vault();
    let mut f = filing("Drawing 1", "Reference/Servers", &[], &[]);
    f.kind = "reference";
    lib.file(&f).unwrap();
    let filed = fs::read_to_string(lib.root.join("Reference/Servers.md")).unwrap();
    assert!(Note::parse(&filed).get("status").is_none());
}

#[test]
fn discard_deletes_a_rejected_note_and_its_drawing_only() {
    let (_dir, lib) = vault();
    assert!(lib.discard("Inbox", "Drawing 1").is_err(), "accepted, so not deleted");
    assert!(lib.discard("Inbox", "Pending").is_err());
    assert!(lib.discard("Inbox", "Homelab").is_err(), "not in the inbox");
    let out = lib.discard("Inbox", "Rejected").unwrap();
    assert_eq!(
        out["deleted"],
        json!(["Inbox/Rejected.md", "_attachments/Excalidraw/Drawing 1.excalidraw.md", "_attachments/Excalidraw/Drawing 1.excalidraw.png"])
    );
    assert!(!lib.root.join("Inbox/Rejected.md").exists());
    assert!(lib.root.join("Inbox/Drawing 1.md").exists(), "other notes stay");
}

#[test]
fn to_dos_in_code_blocks_stay() {
    let (body, todos) = take_todos("```\n- [ ] not a task\n```\n- [ ] a task\n");
    assert_eq!(todos, ["a task"]);
    assert!(body.contains("- [ ] not a task"));
}
