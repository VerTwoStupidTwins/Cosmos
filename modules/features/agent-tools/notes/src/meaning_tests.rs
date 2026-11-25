use super::*;

fn long(word: &str, n: usize) -> String {
    vec![word; n].join(" ")
}

#[test]
fn notes_are_cut_at_headings_with_their_path() {
    let raw = format!(
        "---\ntype: place\ntags: [vantle, coast]\n---\n{}\n# Skerry\n{}\n## History\n{}\n### The flood\n{}\n## Today\n{}\n",
        long("intro", 50),
        long("town", 50),
        long("old", 50),
        long("water", 50),
        long("now", 50)
    );
    let parts = sections("Worlds/Skerry.md", &raw);
    let headings: Vec<&str> = parts.iter().map(|s| s.heading.as_str()).collect();
    assert_eq!(headings, ["", "Skerry", "Skerry › History", "Skerry › History › The flood", "Skerry › Today"]);
    assert!(parts[0].text.starts_with("tags: vantle, coast\n"), "tags lead the first section");
    assert!(!parts.iter().any(|s| s.text.contains("type: place")), "front matter isn't embedded as text");
    assert!(parts[3].text.starts_with("### The flood\n"), "a section keeps its heading line");
}

#[test]
fn short_sections_join_the_next_and_long_ones_split() {
    let raw = format!("# A\nshort\n# B\n{}\n", long("word", 1000));
    let parts = sections("n.md", &raw);
    assert_eq!(parts[0].heading, "A", "the short section keeps its heading");
    assert!(parts[0].text.contains("short") && parts[0].text.contains("# B"), "and takes in the next one");
    assert!(parts.len() > 1, "a 5,000-character section is split");
    assert!(parts.iter().all(|s| s.text.chars().count() <= MAX_SECTION));
    let rejoined: String = parts.iter().map(|s| s.text.as_str()).collect();
    assert_eq!(rejoined.matches("word").count(), 1000, "nothing is lost in the split");
}

#[test]
fn hashes_in_code_blocks_are_not_headings() {
    let raw = format!("{}\n```sh\n# a comment\nls\n```\n{}\n", long("before", 60), long("after", 60));
    let parts = sections("n.md", &raw);
    assert_eq!(parts.len(), 1);
    assert_eq!(parts[0].heading, "");
}

#[test]
fn an_empty_note_is_its_name() {
    let parts = sections("Ideas/Duct fan.md", "---\ntype: idea\n---\n\n");
    assert_eq!(parts, vec![Section { heading: String::new(), text: "Duct fan".into() }]);
}

#[test]
fn point_ids_are_stable_and_distinct() {
    assert_eq!(point_id("Ideas/Duct fan.md", 0), point_id("Ideas/Duct fan.md", 0));
    assert_ne!(point_id("Ideas/Duct fan.md", 0), point_id("Ideas/Duct fan.md", 1));
    assert_ne!(point_id("Ideas/Duct fan.md", 0), point_id("Ideas/Duct fans.md", 0));
    assert!(point_id("x.md", 3) < 1 << 63);
}

#[test]
fn a_sync_embeds_what_changed_and_drops_what_is_gone() {
    let disk: BTreeMap<String, String> = [("same.md", "a"), ("changed.md", "new text"), ("new.md", "b"), ("remodelled.md", "c")]
        .into_iter()
        .map(|(p, t)| (p.to_string(), t.to_string()))
        .collect();
    let old = |text: &str, model: &str| Indexed { fingerprint: fingerprint(text.as_bytes()), model: model.into(), ids: vec![1] };
    let indexed: HashMap<String, Indexed> = [
        ("same.md", old("a", "embedding")),
        ("changed.md", old("old text", "embedding")),
        ("remodelled.md", old("c", "older-model")),
        ("gone.md", old("d", "embedding")),
    ]
    .into_iter()
    .map(|(p, i)| (p.to_string(), i))
    .collect();
    let plan = plan(&disk, &indexed, "embedding");
    assert_eq!(plan.embed, ["changed.md", "new.md", "remodelled.md"]);
    assert_eq!(plan.drop, ["gone.md"]);
}

#[test]
fn a_note_is_in_every_folder_above_it() {
    assert_eq!(folders("Worlds/Vantle/Skerry.md"), ["Worlds", "Worlds/Vantle"]);
    assert!(folders("Top.md").is_empty());
    assert_eq!(title("Worlds/Vantle/Skerry.md"), "Skerry");
}

#[test]
fn only_note_changes_wake_the_indexer() {
    let root = std::path::Path::new("/vault");
    assert!(is_note_change(root, std::path::Path::new("/vault/Ideas/Duct fan.md")));
    assert!(is_note_change(root, std::path::Path::new("/vault/Ideas")), "a moved folder");
    assert!(!is_note_change(root, std::path::Path::new("/vault/.obsidian/workspace.json")));
    assert!(!is_note_change(root, std::path::Path::new("/vault/_attachments/photo.png")));
}

#[test]
fn search_results_are_one_per_note() {
    let hit = |path: &str, heading: &str, score: f64| Hit { path: path.into(), heading: heading.into(), text: "text".into(), score: Some(score) };
    let out = best_per_note(vec![hit("a.md", "One", 0.9), hit("b.md", "", 0.8), hit("a.md", "Two", 0.7), hit("c.md", "", 0.1)], 2);
    assert_eq!(out.len(), 2);
    assert_eq!(out[0]["path"], "a.md");
    assert_eq!(out[0]["section"], "One");
    assert_eq!(out[0]["also_in"], json!(["Two"]));
    assert_eq!(out[1]["path"], "b.md");
    assert!(out[1].get("section").is_none());
}

#[test]
fn excluded_folders_cover_everything_below_them() {
    let skip = vec!["copilot".to_string()];
    assert!(excluded("copilot/skills/obsidian-markdown/SKILL.md", &skip));
    assert!(excluded("copilot/notes.md", &skip));
    assert!(!excluded("copilot.md", &skip), "a note named like the folder stays");
    assert!(!excluded("Worlds/copilot/Skerry.md", &skip), "only the folder at the vault's top");
    assert!(!excluded("Rules/House rules.md", &skip));
}
