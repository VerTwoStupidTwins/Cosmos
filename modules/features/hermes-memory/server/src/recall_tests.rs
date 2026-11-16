//! The wiki index and recall. Embeddings are faked from word counts and there is no reranker, so
//! results come in search order, as they do when the reranker is down.

use serde_json::{Value, json};
use surrealdb::Surreal;
use surrealdb::engine::local::Mem;

use crate::memory::{self, Caller};
use crate::models::Models;
use crate::recall::{self, Search};
use crate::{App, db, wiki};

pub async fn app(dir: &std::path::Path) -> App {
    let database: db::Database = Surreal::new::<Mem>(()).await.unwrap();
    db::prepare(&database).await.unwrap();
    App::new(database, Models::Fake, dir.to_path_buf(), dir.join("memory"), Some(dir.join("backups")))
}

fn desktop() -> Caller {
    Caller { platform: "desktop".into(), remote: false, session_id: None, actor: "hermes/main".into() }
}

fn write(dir: &std::path::Path, rel: &str, text: &str) {
    let path = dir.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

#[test]
fn pages_split_into_sections() {
    let body = "Intro paragraph.\n\n# First\nSome text.\n\n[^1]: A footnote that only repeats a title.\n\n## Empty\n\n# Long\n";
    let long = format!("{body}{}\n\n{}", "a".repeat(2000), "b".repeat(2500));
    let parts = wiki::sections("Title", &long);
    let headings: Vec<_> = parts.iter().map(|(h, _)| h.as_str()).collect();
    assert_eq!(headings, vec!["Title", "First", "Long", "Long"], "{parts:?}");
    assert_eq!(parts[1].1, "Some text.", "footnote definitions are dropped");
    assert!(parts.iter().all(|(_, t)| t.chars().count() <= wiki::MAX_CHARS));
    // A single paragraph longer than the limit is cut.
    let huge = wiki::sections("T", &"x".repeat(7000));
    assert_eq!(huge.iter().map(|(_, t)| t.len()).collect::<Vec<_>>(), vec![3000, 3000, 1000]);
}

#[test]
fn front_matter_gives_title_and_trust() {
    let raw = "---\ntitle: mmWave sensors\nstatus: draft\nverified:\n  - by: human:twins\nstale_after: 2020-01-01\ngenerated: { by: hermes/research }\n---\n# Body\ntext";
    let (meta, body) = wiki::parse_page(raw);
    assert_eq!(meta["title"], json!("mmWave sensors"));
    assert!(body.starts_with("# Body"));
    let d = wiki::page_details(&meta);
    assert_eq!(d["status"], json!("draft"));
    assert_eq!(d["trust"], json!("human-reviewed"));
    assert_eq!(d["generated_by"], json!("hermes/research"));
    assert!(d["stale_after"].as_str().unwrap().starts_with("2020-01-01T00:00:00"));
    let plain = wiki::page_details(&json!({"verified": {"by": "process:check"}}));
    assert_eq!(plain["trust"], json!("machine-confirmed"));
    assert_eq!(plain["status"], json!("stable"));
    assert_eq!(wiki::page_details(&json!({}))["trust"], json!("unverified"));
    // Broken front matter is ignored rather than failing the page.
    assert_eq!(wiki::parse_page("---\n: [\n---\nbody").0, json!({}));
}

#[test]
fn keywords_and_fusion() {
    assert_eq!(recall::keywords("What is the owner's favourite colour?").as_deref(), Some("owner favourite colour"));
    assert_eq!(recall::keywords("is it a"), None);
    let fused = recall::fuse(&[vec![json!(1), json!(2), json!(3)], vec![json!(3), json!(4)]]);
    assert_eq!(fused, vec![json!(3), json!(1), json!(2), json!(4)], "found by both lists ranks first");
}

#[tokio::test]
async fn wiki_index_follows_the_files() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    write(dir.path(), "topics/sensors.md", "---\ntitle: Presence sensors\n---\n# mmWave\nmmWave radar sees people sitting still.\n# PIR\nPIR sees motion only.");
    write(dir.path(), "topics/running.md", "# Training\nMarathon training plans build mileage slowly.");
    write(dir.path(), "index.md", "reserved, never indexed");
    write(dir.path(), ".obsidian/x.md", "hidden, never indexed");
    write(dir.path(), "memory/facts.md", "the memory export, never indexed");

    assert_eq!(wiki::sync(&app, true).await.unwrap(), 2);
    assert_eq!(wiki::sync(&app, true).await.unwrap(), 0, "unchanged files aren't re-read");
    let chunks = db::rows(&app.db, "SELECT record::id(page) AS path, heading FROM wiki_chunk ORDER BY path, heading", vec![]).await.unwrap();
    assert_eq!(chunks.len(), 3, "{chunks:?}");

    // An edit re-indexes the page; a deletion removes it and its sections.
    std::thread::sleep(std::time::Duration::from_millis(20));
    write(dir.path(), "topics/sensors.md", "# mmWave\nOnly mmWave now.");
    std::fs::remove_file(dir.path().join("topics/running.md")).unwrap();
    assert_eq!(wiki::sync(&app, true).await.unwrap(), 2);
    let chunks = db::rows(&app.db, "SELECT record::id(page) AS path, heading, text FROM wiki_chunk", vec![]).await.unwrap();
    assert_eq!(chunks, vec![json!({"path": "/topics/sensors.md", "heading": "mmWave", "text": "Only mmWave now."})]);
}

#[tokio::test]
async fn recall_finds_memories_and_wiki_sections() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    write(dir.path(), "topics/sensors.md", "---\ntitle: Presence sensors\nstatus: stable\n---\n# mmWave\nmmWave radar presence sensors detect people sitting still.");
    write(dir.path(), "old/sensors.md", "---\ntitle: Old sensors\nstatus: deprecated\n---\nmmWave radar presence sensors, the old notes.");
    let m = &app.models;
    for (kind, content) in [
        ("fact", "The owner bought three Aqara FP2 mmWave presence sensors."),
        ("preference", "The owner likes the color green."),
        ("fact", "The owner is training for the LA Marathon."),
    ] {
        memory::remember(&app.db, m, &json!({"kind": kind, "content": content}), &desktop(), "stated").await.unwrap();
    }
    memory::remember(&app.db, m, &json!({"kind": "fact", "content": "The owner's mmWave sensors are in the bedroom.", "privacy": "local_only"}), &desktop(), "stated").await.unwrap();

    let search = |query: &str, memories: bool, wiki: bool, deprecated: bool| Search {
        query: query.into(),
        limit: 8,
        memories,
        wiki,
        include_past: false,
        include_deprecated: deprecated,
    };
    let out = recall::search(&app, search("mmWave presence sensors", true, true, false), &desktop()).await.unwrap();
    println!("{out:#}");
    let results = out["results"].as_array().unwrap();
    assert!(out["notes"].as_array().unwrap().iter().any(|n| n.as_str().unwrap().starts_with("Re-indexed 2")));
    assert!(out["notes"].as_array().unwrap().iter().any(|n| n.as_str().unwrap().starts_with("Reranker unavailable")));
    let first_memory = results.iter().find(|r| r["source"] == "memory").unwrap();
    assert_eq!(first_memory["id"], json!(1));
    let section = results.iter().find(|r| r["source"] == "wiki").unwrap();
    assert_eq!(section["link"], json!("/topics/sensors.md"));
    assert_eq!(section["title"], json!("Presence sensors"));
    assert_eq!(section["section"], json!("mmWave"));
    assert_eq!(section["status"], json!("stable"));
    assert!(section["path"].as_str().unwrap().ends_with("/topics/sensors.md"));
    assert!(!results.iter().any(|r| r["link"] == json!("/old/sensors.md")), "deprecated pages are left out");

    // A remote chat doesn't get the local-only memory.
    let telegram = Caller { platform: "telegram".into(), remote: true, session_id: None, actor: "hermes/main".into() };
    let remote = recall::search(&app, search("mmWave sensors bedroom", true, false, false), &telegram).await.unwrap();
    assert!(!remote["results"].as_array().unwrap().iter().any(|r| r["id"] == json!(4)));

    // Wiki search leaves memories out, and can include deprecated pages.
    let wiki_only = recall::search(&app, search("mmWave presence sensors", false, true, true), &desktop()).await.unwrap();
    let w = wiki_only["results"].as_array().unwrap();
    assert!(w.iter().all(|r| r["source"] == "wiki"));
    assert!(w.iter().any(|r| r["link"] == json!("/old/sensors.md")));

    // What was recalled is counted.
    let counts = db::rows(&app.db, "SELECT record::id(id) AS id, recall_count FROM memory:1", vec![]).await.unwrap();
    assert!(counts[0]["recall_count"].as_i64().unwrap() >= 1);

    let related = wiki::related(&app, &json!({"path": "/topics/sensors.md"})).await.unwrap();
    assert_eq!(related["related"][0]["link"], json!("/old/sensors.md"));
    let missing = wiki::related(&app, &json!({"path": "/nope.md"})).await.unwrap();
    assert!(missing["error"].as_str().unwrap().contains("isn't in the index"));
}

#[tokio::test]
async fn nothing_found_says_so() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    let out = recall::search(
        &app,
        Search { query: "anything".into(), limit: 8, memories: true, wiki: true, include_past: false, include_deprecated: false },
        &desktop(),
    )
    .await
    .unwrap();
    assert_eq!(out["results"], json!([]));
    assert_eq!(out["message"], json!("Nothing closely matches."));
    let _: Value = out;
}
