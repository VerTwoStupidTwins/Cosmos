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
    write("Inbox/Drawing 1.md", &transcribed("accept", "To do:\n- [ ] Set up Minecraft server\n- [ ] Set up game streaming\n\nToday i need to start studying\nfor my Ignition Core certification\n\n![[_attachments/Excalidraw/Drawing 1.excalidraw]]\n"));
    write("Inbox/Pending.md", &transcribed("pending", "not checked yet\n"));
    write("Inbox/Rejected.md", &transcribed("delete", "garbled\n"));
    write("Inbox/From chat.md", "---\ntype: idea\n---\nA quieter fan.\n");
    write("_attachments/Excalidraw/Drawing 1.excalidraw.md", "drawing data\n");
    write("_attachments/Excalidraw/Drawing 1.excalidraw.png", "png\n");
    write("Projects/Homelab/Homelab.md", "---\ntype: project\n---\n# Homelab\n\nRelated: [[Game servers]]\n");
    write("Ideas/Game servers.md", "---\ntype: idea\n---\nServers for the group.\n");
    (dir, Library { root })
}

fn new_piece<'a>(to: &'a str, text: &'a str, related: &'a [String], todos: &'a [String]) -> Piece<'a> {
    Piece { to: Some(to), into: None, kind: Some("project"), status: Some("open"), tags: &[], text, related, todos }
}

fn into_piece<'a>(into: &'a str, text: &'a str, related: &'a [String], todos: &'a [String]) -> Piece<'a> {
    Piece { to: None, into: Some(into), kind: None, status: None, tags: &[], text, related, todos }
}

fn filing<'a>(note: &'a str, pieces: &'a [Piece<'a>], todos: &'a [String]) -> Filing<'a> {
    Filing { inbox: "Inbox", tasks: "Reference/Tasks.md", note, pieces, todos, created: None }
}

#[test]
fn a_note_is_split_into_new_and_existing_notes_and_deleted() {
    let (_dir, lib) = vault();
    let cert_todos = vec!["Start studying".to_string()];
    let server_todos = vec!["Set up Minecraft server".to_string(), "Set up game streaming".to_string()];
    let related = vec!["Homelab".to_string()];
    let tags = vec!["certification".to_string(), "handwritten".to_string()];
    let mut cert = new_piece(
        "Projects/Ignition Core certification/Ignition Core certification",
        "Study for my Ignition Core certification.",
        &[],
        &cert_todos,
    );
    cert.tags = &tags;
    let pieces = [cert, into_piece("Game servers", "Minecraft and game streaming, set up on lugh.", &related, &server_todos)];
    let out = lib.file(&filing("Drawing 1", &pieces, &[])).unwrap();

    assert_eq!(out["new_notes"], json!(["Projects/Ignition Core certification/Ignition Core certification.md"]));
    assert_eq!(out["added_to"], json!(["Ideas/Game servers.md"]));
    assert_eq!(
        out["deleted"],
        json!(["Inbox/Drawing 1.md", "_attachments/Excalidraw/Drawing 1.excalidraw.md", "_attachments/Excalidraw/Drawing 1.excalidraw.png"]),
        "the original and its drawing go"
    );

    let cert = fs::read_to_string(lib.root.join("Projects/Ignition Core certification/Ignition Core certification.md")).unwrap();
    let note = Note::parse(&cert);
    assert_eq!(note.get("type").as_deref(), Some("project"));
    assert_eq!(note.get("status").as_deref(), Some("open"));
    assert_eq!(note.list("tags"), ["certification", "handwritten"]);
    assert_eq!(note.get("created").as_deref(), Some("2026-11-23"), "the day it was transcribed");
    assert!(note.source_link().is_none(), "the drawing is gone, so no link to it");
    for gone in ["review", "transcribed", "transcription", "png-sha256", "text-sha256"] {
        assert!(note.get(gone).is_none(), "{gone} is the transcriber's, and goes");
    }
    assert!(cert.contains("Study for my Ignition Core certification."));
    assert!(!cert.contains("[ ]") && !cert.contains("Tasks"), "no to-dos and no pointer to them in the note");

    let servers = fs::read_to_string(lib.root.join("Ideas/Game servers.md")).unwrap();
    assert!(servers.starts_with("---\ntype: idea\n---\nServers for the group.\n"), "the existing text is untouched");
    assert!(servers.contains("\n## Added "));
    assert!(servers.contains("Minecraft and game streaming, set up on lugh.\n\nRelated: [[Homelab]]\n"));

    let tasks = fs::read_to_string(lib.root.join("Reference/Tasks.md")).unwrap();
    assert!(tasks.contains(
        "- [ ] Start studying ([[Ignition Core certification]])\n- [ ] Set up Minecraft server ([[Game servers]])\n- [ ] Set up game streaming ([[Game servers]])\n"
    ));
}

#[test]
fn to_dos_and_drawings_never_reach_a_filed_note() {
    let (_dir, lib) = vault();
    let pieces = [new_piece(
        "Ideas/Servers",
        "Servers:\n- [ ] Set up Minecraft server\nThey should be quiet.\n![[_attachments/Excalidraw/Drawing 1.excalidraw]]",
        &[],
        &[],
    )];
    lib.file(&filing("Drawing 1", &pieces, &[])).unwrap();
    let filed = fs::read_to_string(lib.root.join("Ideas/Servers.md")).unwrap();
    assert!(!filed.contains("[ ]") && !filed.contains("excalidraw"), "{filed}");
    assert!(filed.contains("They should be quiet."));
    let tasks = fs::read_to_string(lib.root.join("Reference/Tasks.md")).unwrap();
    assert!(tasks.contains("- [ ] Set up Minecraft server ([[Servers]])"));
}

#[test]
fn a_note_of_only_chores_needs_no_new_note() {
    let (_dir, lib) = vault();
    let todos = vec!["Set up Minecraft server".to_string()];
    let out = lib.file(&filing("Drawing 1", &[], &todos)).unwrap();
    assert_eq!(out["new_notes"], json!([]));
    let tasks = fs::read_to_string(lib.root.join("Reference/Tasks.md")).unwrap();
    assert!(tasks.ends_with("- [ ] Set up Minecraft server\n"), "no link: it belongs to no note");
    assert!(!lib.root.join("Inbox/Drawing 1.md").exists());
}

#[test]
fn tasks_are_added_to_the_end_of_an_existing_tasks_note() {
    let (_dir, lib) = vault();
    fs::create_dir_all(lib.root.join("Reference")).unwrap();
    fs::write(lib.root.join("Reference/Tasks.md"), "# Tasks\n- [ ] older").unwrap();
    let todos = vec!["Set up Minecraft server".to_string()];
    let pieces = [new_piece("Reference/Servers", "Servers.", &[], &todos)];
    lib.file(&filing("Drawing 1", &pieces, &[])).unwrap();
    let tasks = fs::read_to_string(lib.root.join("Reference/Tasks.md")).unwrap();
    assert!(tasks.starts_with("# Tasks\n- [ ] older\n- [ ] Set up Minecraft server ([[Servers]])\n"));
}

#[test]
fn only_accepted_or_unreviewed_inbox_notes_are_filed() {
    let (_dir, lib) = vault();
    let pieces = [new_piece("Ideas/P", "text", &[], &[])];
    let e = lib.file(&filing("Pending", &pieces, &[])).unwrap_err().to_string();
    assert!(e.contains("waits"), "{e}");
    let e = lib.file(&filing("Rejected", &pieces, &[])).unwrap_err().to_string();
    assert!(e.contains("discard"), "{e}");
    let e = lib.file(&filing("Homelab", &pieces, &[])).unwrap_err().to_string();
    assert!(e.contains("isn't in Inbox"), "{e}");
    let mut chat = new_piece("Ideas/Quiet fan", "A quieter fan.", &[], &[]);
    chat.kind = Some("idea");
    lib.file(&filing("From chat", &[chat], &[])).unwrap();
    assert!(lib.root.join("Ideas/Quiet fan.md").exists(), "a note with no review mark files");
}

#[test]
fn filing_checks_everything_before_changing_anything() {
    let (_dir, lib) = vault();
    let original = fs::read_to_string(lib.root.join("Inbox/Drawing 1.md")).unwrap();
    let good = || new_piece("Ideas/Fine", "fine", &[], &[]);
    for (bad, why) in [
        (new_piece("Projects/Homelab/Homelab", "x", &[], &[]), "exists"),
        (new_piece("Ideas/Homelab", "x", &[], &[]), "name taken"),
        (new_piece("Inbox/Elsewhere", "x", &[], &[]), "inbox"),
        (new_piece("Top level", "x", &[], &[]), "top"),
        (new_piece("_templates/X", "x", &[], &[]), "_ folder"),
        (new_piece("Reference/Tasks", "x", &[], &[]), "tasks note"),
        (new_piece("Ideas/Empty", "- [ ] only a to-do", &[], &[]), "no text"),
        (into_piece("No such note", "x", &[], &[]), "no note to add to"),
        (into_piece("Pending", "x", &[], &[]), "adding to an inbox note"),
        (Piece { to: Some("Ideas/A"), into: Some("Game servers"), ..good() }, "both to and into"),
        (Piece { kind: Some("thought"), ..good() }, "unknown type"),
        (Piece { status: Some("someday"), ..good() }, "unknown status"),
        (Piece { status: None, ..good() }, "a project needs a status"),
    ] {
        let pieces = [good(), bad];
        assert!(lib.file(&filing("Drawing 1", &pieces, &[])).is_err(), "{why} should be refused");
    }
    let missing = vec!["No such note".to_string()];
    let pieces = [new_piece("Ideas/X", "x", &missing, &[])];
    assert!(lib.file(&filing("Drawing 1", &pieces, &[])).is_err(), "an unknown related note");
    let twice = [good(), good()];
    assert!(lib.file(&filing("Drawing 1", &twice, &[])).is_err(), "two pieces with one name");
    assert!(lib.file(&filing("Drawing 1", &[], &[])).is_err(), "nothing to file");

    assert_eq!(fs::read_to_string(lib.root.join("Inbox/Drawing 1.md")).unwrap(), original, "untouched");
    assert!(!lib.root.join("Ideas/Fine.md").exists(), "not even the good piece was written");
    assert!(!lib.root.join("Reference/Tasks.md").exists());
}

#[test]
fn a_reference_note_has_no_status() {
    let (_dir, lib) = vault();
    let pieces = [Piece { kind: Some("reference"), ..new_piece("Reference/Servers", "Servers.", &[], &[]) }];
    lib.file(&filing("Drawing 1", &pieces, &[])).unwrap();
    let filed = fs::read_to_string(lib.root.join("Reference/Servers.md")).unwrap();
    assert!(Note::parse(&filed).get("status").is_none());
}

#[test]
fn links_already_in_a_note_are_not_added_again() {
    let (_dir, lib) = vault();
    let related = vec!["Game servers".to_string()];
    let pieces = [into_piece("Homelab", "More on the lab.", &related, &[])];
    lib.file(&filing("Drawing 1", &pieces, &[])).unwrap();
    let homelab = fs::read_to_string(lib.root.join("Projects/Homelab/Homelab.md")).unwrap();
    assert_eq!(homelab.matches("[[Game servers]]").count(), 1, "{homelab}");
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
