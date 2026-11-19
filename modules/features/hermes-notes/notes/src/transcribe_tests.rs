use super::*;
use std::cell::Cell;
use tempfile::TempDir;

/// Answers with a fixed transcription, counting calls.
struct Fake {
    reply: &'static str,
    calls: Cell<usize>,
}

impl Fake {
    fn new(reply: &'static str) -> Self {
        Fake {
            reply,
            calls: Cell::new(0),
        }
    }
}

impl Model for Fake {
    fn transcribe(&self, _png: &[u8]) -> Result<String> {
        self.calls.set(self.calls.get() + 1);
        Ok(self.reply.to_string())
    }
}

struct Failing;

impl Model for Failing {
    fn transcribe(&self, _png: &[u8]) -> Result<String> {
        bail!("llama-swap is down")
    }
}

fn setup() -> (TempDir, Vault, PathBuf) {
    let dir = TempDir::new().unwrap();
    let root = dir.path().join("vault");
    fs::create_dir_all(root.join("Excalidraw")).unwrap();
    let png = root.join("Excalidraw/Drawing 1.excalidraw.png");
    fs::write(&png, "ink").unwrap();
    let vault = Vault {
        seen: dir.path().join("transcribed"),
        root,
    };
    (dir, vault, png)
}

#[test]
fn a_new_drawing_gets_an_inbox_note() {
    let (_dir, vault, png) = setup();
    let model = Fake::new("- [ ] Clean room\nThis is a test");
    let note = vault.root.join("Inbox/Drawing 1.md");
    assert_eq!(
        vault.transcribe(&png, &model).unwrap(),
        Outcome::Wrote(note.clone())
    );

    let raw = fs::read_to_string(&note).unwrap();
    let parsed = Note::parse(&raw);
    assert_eq!(
        parsed.source_link().as_deref(),
        Some("Excalidraw/Drawing 1.excalidraw")
    );
    assert!(parsed.is("review", "pending"));
    assert!(parsed.is("transcription", "current"));
    assert!(!parsed.is_edited());
    assert_eq!(
        parsed.body,
        "- [ ] Clean room\nThis is a test\n\n![[Excalidraw/Drawing 1.excalidraw]]\n"
    );
}

#[test]
fn an_unchanged_drawing_is_not_sent_again() {
    let (_dir, vault, png) = setup();
    let model = Fake::new("text");
    vault.transcribe(&png, &model).unwrap();
    assert_eq!(vault.transcribe(&png, &model).unwrap(), Outcome::Unchanged);
    assert_eq!(model.calls.get(), 1);
}

#[test]
fn a_changed_drawing_updates_its_note_where_it_was_filed() {
    let (_dir, vault, png) = setup();
    vault.transcribe(&png, &Fake::new("first")).unwrap();
    let moved = vault.root.join("Projects/Drawing 1.md");
    fs::create_dir_all(moved.parent().unwrap()).unwrap();
    fs::rename(vault.root.join("Inbox/Drawing 1.md"), &moved).unwrap();

    fs::write(&png, "more ink").unwrap();
    assert_eq!(
        vault.transcribe(&png, &Fake::new("second")).unwrap(),
        Outcome::Wrote(moved.clone())
    );
    assert!(fs::read_to_string(&moved).unwrap().contains("second"));
    assert!(!vault.root.join("Inbox/Drawing 1.md").exists());
}

#[test]
fn an_edited_note_is_kept_and_marked_outdated() {
    let (_dir, vault, png) = setup();
    vault.transcribe(&png, &Fake::new("first")).unwrap();
    let note = vault.root.join("Inbox/Drawing 1.md");
    let edited = fs::read_to_string(&note).unwrap() + "my own edit\n";
    fs::write(&note, &edited).unwrap();

    fs::write(&png, "more ink").unwrap();
    let model = Fake::new("second");
    assert_eq!(
        vault.transcribe(&png, &model).unwrap(),
        Outcome::MarkedOutdated(note.clone())
    );
    assert_eq!(
        vault.transcribe(&png, &model).unwrap(),
        Outcome::AlreadyOutdated(note.clone())
    );
    assert_eq!(model.calls.get(), 0);
    let raw = fs::read_to_string(&note).unwrap();
    assert!(
        raw.contains("my own edit")
            && raw.contains("transcription: outdated")
            && !raw.contains("second")
    );
}

#[test]
fn a_deleted_note_stays_deleted_until_new_ink() {
    let (_dir, vault, png) = setup();
    vault.transcribe(&png, &Fake::new("first")).unwrap();
    fs::remove_file(vault.root.join("Inbox/Drawing 1.md")).unwrap();
    assert_eq!(
        vault.transcribe(&png, &Fake::new("again")).unwrap(),
        Outcome::Forgotten
    );

    fs::write(&png, "more ink").unwrap();
    let note = vault.root.join("Inbox/Drawing 1.md");
    assert_eq!(
        vault.transcribe(&png, &Fake::new("new")).unwrap(),
        Outcome::Wrote(note)
    );
}

#[test]
fn a_note_it_did_not_write_is_left_alone() {
    let (_dir, vault, png) = setup();
    let mine = vault.root.join("Mine.md");
    let raw = "---\nsource: \"[[Excalidraw/Drawing 1.excalidraw]]\"\n---\nthe owner's own\n";
    fs::write(&mine, raw).unwrap();
    assert_eq!(
        vault.transcribe(&png, &Fake::new("x")).unwrap(),
        Outcome::NotOurs(mine.clone())
    );
    assert_eq!(fs::read_to_string(&mine).unwrap(), raw);
}

#[test]
fn inbox_names_do_not_clash() {
    let (_dir, vault, png) = setup();
    fs::create_dir_all(vault.root.join("Inbox")).unwrap();
    fs::write(vault.root.join("Inbox/Drawing 1.md"), "someone else's").unwrap();
    let expected = vault.root.join("Inbox/Drawing 1 2.md");
    assert_eq!(
        vault.transcribe(&png, &Fake::new("x")).unwrap(),
        Outcome::Wrote(expected)
    );
}

#[test]
fn nothing_is_written_or_remembered_when_the_model_fails_or_sees_nothing() {
    let (_dir, vault, png) = setup();
    assert!(vault.transcribe(&png, &Failing).is_err());
    assert_eq!(
        vault.transcribe(&png, &Fake::new("```\n\n```")).unwrap(),
        Outcome::Empty
    );
    assert!(!vault.root.join("Inbox").exists());
    // Still new, so the next attempt goes ahead.
    assert!(matches!(
        vault.transcribe(&png, &Fake::new("x")).unwrap(),
        Outcome::Wrote(_)
    ));
}

#[test]
fn filed_notes_are_cleaned_up_with_their_drawing() {
    let (_dir, vault, png) = setup();
    fs::write(
        vault.root.join("Excalidraw/Drawing 1.excalidraw.md"),
        "drawing",
    )
    .unwrap();
    vault.transcribe(&png, &Fake::new("x")).unwrap();
    let note = vault.root.join("Inbox/Drawing 1.md");
    assert_eq!(vault.clean_up(&note).unwrap(), None);

    let raw = fs::read_to_string(&note)
        .unwrap()
        .replace("review: pending", "review: filed");
    fs::write(&note, raw).unwrap();
    vault.handle(&note, &Failing);
    assert!(!note.exists() && !png.exists());
    assert!(
        !vault
            .root
            .join("Excalidraw/Drawing 1.excalidraw.md")
            .exists()
    );
}

#[test]
fn catching_up_skips_hidden_folders() {
    let (_dir, vault, _png) = setup();
    fs::create_dir_all(vault.root.join(".trash")).unwrap();
    fs::write(vault.root.join(".trash/Old.excalidraw.png"), "old").unwrap();
    let model = Fake::new("x");
    vault.catch_up(&model).unwrap();
    assert_eq!(model.calls.get(), 1);
    assert!(vault.root.join("Inbox/Drawing 1.md").exists());
}

#[test]
fn replies_are_tidied() {
    assert_eq!(tidy("```markdown\n- [ ] a\n```\n"), "- [ ] a");
    assert_eq!(tidy("[sketch: a cat]"), "_[sketch: a cat]_");
    assert_eq!(tidy("[no writing]"), "_[no writing]_");
    assert_eq!(tidy("[unreadable] word"), "[unreadable] word");
}

#[test]
fn an_empty_reply_falls_back_to_the_reasoning() {
    let both = json!({"choices": [{"message": {"content": "", "reasoning_content": "- [ ] a"}}]});
    assert_eq!(reply_text(&both), "- [ ] a");
    let normal =
        json!({"choices": [{"message": {"content": "text", "reasoning_content": "thinking"}}]});
    assert_eq!(reply_text(&normal), "text");
    assert_eq!(reply_text(&json!({})), "");
}
