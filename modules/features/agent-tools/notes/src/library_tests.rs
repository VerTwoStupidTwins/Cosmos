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
        "Ideas/Duct fan.md",
        "---\ntype: idea\nstatus: parked\ntags: [homelab]\n---\nA quieter fan for the #server closet.\nSee [[Printer]] and [[Projects/Cosmos/Cosmos|the homelab]].\n",
    );
    write("Reference/Printer.md", "# Printer\nThe printer jams on thick paper.\n");
    write("Projects/Cosmos/Cosmos.md", "---\ntype: project\n---\nThe homelab. Fan idea: [[Duct fan]]\n");
    write("Inbox/Drawing 1.md", "---\nreview: pending\n---\nfan noise\n\n![[_attachments/Excalidraw/Drawing 1.excalidraw]]\n");
    write("_attachments/Excalidraw/Drawing 1.excalidraw.md", "fan fan fan (drawing data)\n");
    write(".obsidian/app.json", "{\"secret\": \"fan\"}\n");
    fs::write(dir.path().join("outside.md"), "fan outside the vault\n").unwrap();
    (dir, Library { root })
}

#[test]
fn paths_stay_inside_the_vault() {
    let (_dir, lib) = vault();
    for bad in ["../outside.md", "/etc/passwd", ".obsidian/app.json", "Ideas/../../outside.md", ".obsidian"] {
        assert!(lib.read(bad).is_err(), "{bad} should be refused");
        assert!(lib.list(bad, false).is_err(), "{bad} should be refused");
    }
}

#[test]
fn a_symlink_out_of_the_vault_is_refused() {
    let (dir, lib) = vault();
    std::os::unix::fs::symlink(dir.path().join("outside.md"), lib.root.join("Reference/escape.md")).unwrap();
    assert!(lib.read("Reference/escape.md").is_err());
}

#[test]
fn reading_gives_properties_tags_and_links_both_ways() {
    let (_dir, lib) = vault();
    let note = lib.read("Ideas/Duct fan").unwrap();
    assert_eq!(note["path"], "Ideas/Duct fan.md");
    assert_eq!(note["properties"]["status"], "parked");
    assert_eq!(note["tags"], json!(["homelab", "server"]));
    assert_eq!(note["links"], json!(["Printer", "Projects/Cosmos/Cosmos"]));
    assert_eq!(note["linked_from"], json!(["Projects/Cosmos/Cosmos.md"]));
}

#[test]
fn a_note_can_be_read_by_its_name_alone() {
    let (_dir, lib) = vault();
    assert_eq!(lib.read("printer").unwrap()["path"], "Reference/Printer.md");
    assert_eq!(lib.read("[[Duct fan]]").unwrap()["path"], "Ideas/Duct fan.md");
    assert!(lib.read("Nothing like it").is_err());
}

#[test]
fn listing_shows_folders_and_note_properties() {
    let (_dir, lib) = vault();
    let top = lib.list("", false).unwrap();
    let folders = top["folders"].as_array().unwrap();
    assert!(folders.contains(&json!("Ideas")) && folders.contains(&json!("_attachments")));
    assert!(!folders.contains(&json!(".obsidian")));
    let ideas = lib.list("Ideas", false).unwrap();
    assert_eq!(ideas["files"][0]["status"], "parked");
    assert_eq!(ideas["files"][0]["tags"], json!(["homelab"]));
    assert!(lib.list("Ideas/Duct fan.md", false).is_err());
}

#[test]
fn search_needs_every_word_and_skips_drawing_data_and_settings() {
    let (_dir, lib) = vault();
    let found = lib.search("fan", "", 10).unwrap();
    let paths: Vec<&str> = found["notes"].as_array().unwrap().iter().map(|n| n["path"].as_str().unwrap()).collect();
    // The note named for it first; Excalidraw's data and Obsidian's settings never.
    assert_eq!(paths[0], "Ideas/Duct fan.md");
    assert!(paths.contains(&"Inbox/Drawing 1.md"));
    assert!(!paths.iter().any(|p| p.contains("excalidraw.md") || p.contains(".obsidian")));
    assert_eq!(lib.search("fan printer", "", 10).unwrap()["matches"], 1);
    assert_eq!(lib.search("fan", "Reference", 10).unwrap()["matches"], 0);
    assert!(lib.search("  ", "", 10).is_err());
}

#[test]
fn inline_tags_skip_headings_code_and_urls() {
    let text = "# Heading\nA #tag and #nested/tag.\n```\n#not-this\n```\nhttps://x.org/#anchor 2024 #2024\n";
    assert_eq!(inline_tags(text), vec!["tag", "nested/tag"]);
}
