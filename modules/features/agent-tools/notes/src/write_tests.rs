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
    write(
        "Inbox/Skerry.md",
        "---\ntype: place\n---\nA rib town. Part of [[Vantle]].\n",
    );
    write(
        "Worlds/Vantle/Vantle.md",
        "# Vantle\nTowns: [[Skerry]], [[Inbox/Skerry|the rib town]], [[Skerry#Notable spots]].\n",
    );
    write(
        "Reference/Rules.md",
        "Skerry is mentioned but not linked. [[Skerryhold]] is another note.\n",
    );
    write("Reference/Skerryhold.md", "Not the same note.\n");
    fs::write(dir.path().join("outside.md"), "outside\n").unwrap();
    (dir, Library { root })
}

fn read(lib: &Library, rel: &str) -> String {
    fs::read_to_string(lib.root.join(rel)).unwrap()
}

#[test]
fn create_writes_a_new_note_in_the_inbox() {
    let (_dir, lib) = vault();
    let out = lib
        .create("Inbox", "Old Maren", "---\ntype: npc\n---\nThe lighthouse keeper.\n")
        .unwrap();
    assert_eq!(out["created"], "Inbox/Old Maren.md");
    assert_eq!(
        read(&lib, "Inbox/Old Maren.md"),
        "---\ntype: npc\n---\nThe lighthouse keeper.\n"
    );
    let mode = fs::metadata(lib.root.join("Inbox/Old Maren.md"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o660);
    // no temporary file left behind
    assert!(
        fs::read_dir(lib.root.join("Inbox")).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with('.'))
    );
}

#[test]
fn create_makes_the_inbox_if_needed() {
    let (_dir, lib) = vault();
    fs::remove_dir_all(lib.root.join("Inbox")).unwrap();
    lib.create("Inbox", "New.md", "text\n").unwrap();
    assert_eq!(read(&lib, "Inbox/New.md"), "text\n");
}

#[test]
fn create_never_reuses_a_name() {
    let (_dir, lib) = vault();
    // anywhere in the vault, in any case
    let err = lib.create("Inbox", "vantle", "x").unwrap_err().to_string();
    assert!(err.contains("Worlds/Vantle/Vantle.md"), "{err}");
    assert!(lib.create("Inbox", "Skerry", "x").is_err());
    assert_eq!(
        read(&lib, "Inbox/Skerry.md"),
        "---\ntype: place\n---\nA rib town. Part of [[Vantle]].\n"
    );
}

#[test]
fn create_refuses_names_with_folders_or_odd_characters() {
    let (_dir, lib) = vault();
    for bad in ["../outside", "Worlds/Thing", ".hidden", "", "a|b", "a#b", "[[x]]"] {
        assert!(lib.create("Inbox", bad, "x").is_err(), "{bad:?} should be refused");
    }
    assert_eq!(read(&lib, "../outside.md"), "outside\n");
}

#[test]
fn create_refuses_an_inbox_through_a_symlink() {
    let (dir, lib) = vault();
    fs::remove_dir_all(lib.root.join("Inbox")).unwrap();
    std::os::unix::fs::symlink(dir.path(), lib.root.join("Inbox")).unwrap();
    assert!(lib.create("Inbox", "Escape", "x").is_err());
    assert!(!dir.path().join("Escape.md").exists());
}

#[test]
fn edit_replaces_text_found_once() {
    let (_dir, lib) = vault();
    let out = lib.edit("Skerry", "A rib town.", "A hundred-soul rib town.").unwrap();
    assert_eq!(out["edited"], "Inbox/Skerry.md");
    assert_eq!(
        read(&lib, "Inbox/Skerry.md"),
        "---\ntype: place\n---\nA hundred-soul rib town. Part of [[Vantle]].\n"
    );
}

#[test]
fn edit_refuses_missing_repeated_or_empty_text() {
    let (_dir, lib) = vault();
    assert!(
        lib.edit("Skerry", "not there", "x")
            .unwrap_err()
            .to_string()
            .contains("doesn't contain")
    );
    assert!(
        lib.edit("Vantle", "Skerry", "x")
            .unwrap_err()
            .to_string()
            .contains("3 times")
    );
    assert!(lib.edit("Skerry", "", "x").is_err());
    assert!(lib.edit("Skerry", "rib", "rib").is_err());
    assert!(lib.edit("../outside.md", "outside", "x").is_err());
}

#[test]
fn move_keeps_the_name_and_fixes_path_links() {
    let (_dir, lib) = vault();
    let out = lib.move_note("Skerry", "Worlds/Vantle/Places/Skerry").unwrap();
    assert_eq!(out["to"], "Worlds/Vantle/Places/Skerry.md");
    assert!(!lib.root.join("Inbox/Skerry.md").exists());
    assert!(read(&lib, "Worlds/Vantle/Places/Skerry.md").contains("A rib town."));
    // name links still work as they are; the path link follows the note
    assert_eq!(
        read(&lib, "Worlds/Vantle/Vantle.md"),
        "# Vantle\nTowns: [[Skerry]], [[Worlds/Vantle/Places/Skerry|the rib town]], [[Skerry#Notable spots]].\n"
    );
    assert_eq!(out["links_updated_in"], json!(["Worlds/Vantle/Vantle.md"]));
}

#[test]
fn a_rename_changes_every_link_to_the_note_and_only_those() {
    let (_dir, lib) = vault();
    lib.move_note("Inbox/Skerry.md", "Inbox/Skerry Rib.md").unwrap();
    assert_eq!(
        read(&lib, "Worlds/Vantle/Vantle.md"),
        "# Vantle\nTowns: [[Skerry Rib]], [[Inbox/Skerry Rib|the rib town]], [[Skerry Rib#Notable spots]].\n"
    );
    // plain mentions and other notes whose names start the same are left alone
    assert_eq!(
        read(&lib, "Reference/Rules.md"),
        "Skerry is mentioned but not linked. [[Skerryhold]] is another note.\n"
    );
}

#[test]
fn move_never_overwrites_or_duplicates_a_name() {
    let (_dir, lib) = vault();
    assert!(lib.move_note("Skerry", "Reference/Skerryhold").is_err());
    assert!(lib.move_note("Skerry", "Archive/Vantle").is_err());
    assert!(lib.move_note("Skerry", "../outside").is_err());
    assert!(lib.move_note("Skerry", ".obsidian/Skerry").is_err());
    assert!(lib.root.join("Inbox/Skerry.md").exists());
}

#[test]
fn relink_handles_headings_and_shown_text() {
    let text = "[[Old]] [[old|shown]] ![[Old#Part]] [[Folder/Old]] [[Older]]";
    assert_eq!(
        relink(text, "Old", "Folder/Old", "New", "Place/New"),
        "[[New]] [[New|shown]] ![[New#Part]] [[Place/New]] [[Older]]"
    );
}
