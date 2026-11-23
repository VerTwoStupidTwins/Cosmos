use super::*;

#[test]
fn reads_fields_and_body() {
    let raw = "---\nsource: \"[[Excalidraw/A.excalidraw]]\"\ntags: [handwritten]\nreview: pending\n---\nhello\n";
    let note = Note::parse(raw);
    assert_eq!(note.get("review").as_deref(), Some("pending"));
    assert_eq!(
        note.source_link().as_deref(),
        Some("Excalidraw/A.excalidraw")
    );
    // A list isn't a scalar.
    assert_eq!(note.get("tags"), None);
    assert_eq!(note.body, "hello\n");
}

#[test]
fn reads_values_however_obsidian_or_the_owner_writes_them() {
    for raw in [
        "---\nreview: accept\n---\n",
        "---\nreview: \"accept\"\n---\n",
        "---\nreview: 'Accept'\n---\n",
        "---\nreview:   ACCEPT  \n---\n",
        "---\r\nreview: accept\r\n---\r\n",
        // Obsidian writes lists as indented items.
        "---\ntags:\n  - handwritten\nreview: accept\n---\nbody\n",
    ] {
        assert!(Note::parse(raw).is("review", "accept"), "{raw:?}");
    }
}

#[test]
fn unreadable_front_matter_has_no_fields() {
    for raw in [
        "no front matter\n",
        "---\n[unclosed\n---\n",
        "---\n- a list\n---\n",
        "---\nreview: accept\n",
    ] {
        let note = Note::parse(raw);
        assert_eq!(note.get("review"), None, "{raw:?}");
        assert!(!note.is_generated());
    }
    // Empty front matter is fine, just empty.
    let note = Note::parse("---\n---\nbody\n");
    assert_eq!(note.body, "body\n");
}

#[test]
fn source_needs_brackets() {
    assert_eq!(Note::parse("---\nsource: voice\n---\n").source_link(), None);
    assert_eq!(
        Note::parse("---\nsource: \"[[Voice/V 1.ogg]]\"\n---\n")
            .source_link()
            .as_deref(),
        Some("Voice/V 1.ogg")
    );
}

#[test]
fn edits_are_detected_by_the_body_fingerprint() {
    let body = "- [ ] Clean room\n\n![[Excalidraw/A.excalidraw]]\n";
    let raw = format!(
        "---\nreview: pending\ntext-sha256: {}\n---\n{body}",
        fingerprint(body.as_bytes())
    );
    assert!(Note::parse(&raw).is_generated());
    assert!(!Note::parse(&raw).is_edited());
    // A changed front matter isn't an edit; a changed body is.
    let reviewed = raw.replace("review: pending", "review: accept");
    assert!(!Note::parse(&reviewed).is_edited());
    let edited = format!("{raw}my addition\n");
    assert!(Note::parse(&edited).is_edited());
}

#[test]
fn fingerprints_match_the_plugin_and_the_old_scripts() {
    // `printf 'no recording left now\n' | sha256sum`, as the Python plugin also computes.
    assert_eq!(
        fingerprint(b"no recording left now\n"),
        "26346e7e0c2b830c2ccfc44f016c3a3c33f85edd8bc141b9d61581713e45dfe8"
    );
}

#[test]
fn set_field_changes_one_line_only() {
    let raw = "---\nsource: \"[[A.excalidraw]]\"\ntags:\n  - handwritten\ntranscription: current\n---\nbody\n";
    let out = set_field(raw, "transcription", "outdated").unwrap();
    assert_eq!(
        out,
        raw.replace("transcription: current", "transcription: outdated")
    );
    let added = set_field("---\na: 1\n---\nbody\n", "b", "2").unwrap();
    assert_eq!(added, "---\na: 1\nb: 2\n---\nbody\n");
    assert_eq!(
        set_field("---\n---\nbody\n", "b", "2").unwrap(),
        "---\nb: 2\n---\nbody\n"
    );
    assert_eq!(set_field("no front matter", "b", "2"), None);
}

#[test]
fn quoting_round_trips() {
    let name = r#"Odd "name" \ here"#;
    let raw = format!("---\nsource: {}\n---\n", quoted(&format!("[[{name}]]")));
    assert_eq!(Note::parse(&raw).source_link().as_deref(), Some(name));
}
