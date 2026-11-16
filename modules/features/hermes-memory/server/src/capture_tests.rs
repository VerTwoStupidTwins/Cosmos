//! Capture, the memory export and backups. The helper model isn't called; its answers are given directly.

use serde_json::json;
use surrealdb::Surreal;
use surrealdb::engine::local::Mem;

use crate::capture;
use crate::db;
use crate::export;
use crate::memory::{self, Caller};
use crate::recall_tests::app;

fn desktop() -> Caller {
    Caller { platform: "desktop".into(), remote: false, session_id: Some("s1".into()), actor: "hermes/main".into() }
}

fn capture_caller() -> Caller {
    Caller { actor: "hermes/capture".into(), ..desktop() }
}

#[tokio::test]
async fn turns_are_queued_for_capture() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    let skipped = capture::observe(&app, &json!({"user_message": "  ", "assistant_response": "hi"}), &desktop()).await.unwrap();
    assert_eq!(skipped, json!({"status": "skipped"}));
    let long = "x".repeat(10_000);
    let queued = capture::observe(&app, &json!({"user_message": long, "assistant_response": null}), &desktop()).await.unwrap();
    assert_eq!(queued, json!({"status": "queued"}));
    let rows = db::rows(&app.db, "SELECT platform, remote, session_id, user_message, assistant_response, attempts FROM observation", vec![]).await.unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["user_message"].as_str().unwrap().len(), 6000, "long messages are cut");
    assert_eq!(rows[0]["assistant_response"], json!(""));
    assert_eq!(rows[0]["session_id"], json!("s1"));
    assert_eq!(rows[0]["attempts"], json!(0));
}

#[test]
fn the_schema_only_offers_replacing_shown_memories() {
    let none = capture::capture_schema(&[]);
    assert_eq!(none["properties"]["memories"]["items"]["properties"]["action"], json!({"const": "add"}));
    let some = capture::capture_schema(&[7, 3]);
    let variants = some["properties"]["memories"]["items"]["anyOf"].as_array().unwrap();
    assert_eq!(variants.len(), 2);
    assert_eq!(variants[1]["properties"]["replaces"]["enum"], json!([3, 7]));
    assert_eq!(some["properties"]["memories"]["maxItems"], json!(5));
    assert_eq!(variants[0]["properties"]["kind"]["enum"], json!(["fact", "preference", "procedure", "event"]));
}

#[tokio::test]
async fn captured_items_become_inferred_memories() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    memory::remember(&app.db, &app.models, &json!({"kind": "fact", "content": "The owner lives in Buena Park."}), &desktop(), "stated").await.unwrap();
    let items = vec![
        json!({"action": "add", "kind": "fact", "content": "The owner has a husky named Koda.", "importance": 3}),
        json!({"action": "replace", "replaces": 1, "kind": "fact", "content": "The owner lives in Fullerton.", "importance": 4}),
        // A replacement naming a memory that wasn't shown is stored as new instead.
        json!({"action": "replace", "replaces": 99, "kind": "preference", "content": "The owner likes the color green.", "importance": 2}),
        json!({"action": "add", "kind": "commitment", "content": "Commitments are never captured.", "importance": 3}),
        json!({"action": "add", "kind": "fact", "content": "  ", "importance": 3}),
        // Already known: refused as a duplicate, so not counted.
        json!({"action": "add", "kind": "fact", "content": "The owner has a husky named Koda.", "importance": 3}),
    ];
    let saved = capture::apply(&app, &items, &[1], &capture_caller()).await.unwrap();
    assert_eq!(saved, 3);
    let rows = db::rows(&app.db, "SELECT record::id(id) AS id, kind, content, origin, valid_until FROM memory ORDER BY id", vec![]).await.unwrap();
    let contents: Vec<_> = rows.iter().map(|r| (r["id"].as_i64().unwrap(), r["content"].as_str().unwrap())).collect();
    assert_eq!(contents, vec![
        (1, "The owner lives in Buena Park."),
        (2, "The owner has a husky named Koda."),
        (3, "The owner lives in Fullerton."),
        (4, "The owner likes the color green."),
    ]);
    assert!(rows[0]["valid_until"].is_string(), "the replaced memory ended");
    assert!(rows[1..].iter().all(|r| r["origin"] == "inferred"));
    let actors = db::rows(&app.db, "SELECT VALUE actor FROM history WHERE memory_id > 1", vec![]).await.unwrap();
    assert!(actors.iter().all(|a| a == "hermes/capture"), "{actors:?}");
}

#[tokio::test]
async fn the_export_leaves_private_and_past_memories_out() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    let m = &app.models;
    for body in [
        json!({"kind": "fact", "content": "The owner has a husky named Koda.", "importance": 2}),
        json!({"kind": "fact", "content": "The owner works at a water utility.", "importance": 5}),
        json!({"kind": "fact", "content": "The owner's bank is in Fullerton.", "privacy": "local_only"}),
        json!({"kind": "preference", "content": "The owner wants short replies on Telegram.", "platforms": ["telegram"]}),
        json!({"kind": "commitment", "content": "Remind the owner to renew the domain.", "due": "2026-12-01T09:00", "condition": "before it lapses"}),
        json!({"kind": "event", "content": "The owner moved in 2024."}),
    ] {
        memory::remember(&app.db, m, &body, &desktop(), "stated").await.unwrap();
    }
    memory::revise(&app.db, m, &json!({"id": 6, "action": "retract"}), &desktop(), "stated").await.unwrap();
    export::export(&app).await.unwrap();

    let read = |f: &str| std::fs::read_to_string(dir.path().join("memory").join(f)).unwrap();
    let facts = read("facts.md");
    println!("{facts}");
    assert!(facts.starts_with("---\ntype: Memory Export\ntitle: \"Facts\"\n"));
    assert!(facts.contains("generated: { by: process:hermes-memory, at: 20"));
    let utility = facts.find("**#2** The owner works at a water utility.").expect("#2 listed");
    let husky = facts.find("**#1** The owner has a husky named Koda. _(stated; since 20").expect("#1 listed");
    assert!(utility < husky, "more important first");
    assert!(!facts.contains("bank"), "local-only memories stay on lugh");
    assert!(read("preferences.md").contains("_(stated; only telegram; since"));
    assert!(read("commitments.md").contains("_(stated; due 2026-12-01 09:00; when before it lapses; since"));
    assert!(!read("events.md").contains("moved"), "retracted memories are left out");
    assert!(read("procedures.md").contains("# How the owner likes things done"));
    assert!(!dir.path().join("memory/facts.tmp").exists());
}

#[tokio::test]
async fn backups_restore_into_an_empty_database() {
    let dir = tempfile::tempdir().unwrap();
    let app = app(dir.path()).await;
    let m = &app.models;
    memory::remember(&app.db, m, &json!({"kind": "fact", "content": "The owner lives in Buena Park."}), &desktop(), "stated").await.unwrap();
    memory::remember(&app.db, m, &json!({"kind": "commitment", "content": "Renew the domain.", "due": "2026-12-01"}), &desktop(), "stated").await.unwrap();
    memory::revise(&app.db, m, &json!({"id": 1, "action": "replace", "content": "The owner lives in Fullerton."}), &desktop(), "stated").await.unwrap();

    let path = export::backup(&app).await.unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("Fullerton"));
    // Older backups beyond the newest seven are removed.
    for day in 1..=9 {
        std::fs::write(dir.path().join(format!("backups/hermes-memory-2020-01-0{day}.surql")), "").unwrap();
    }
    export::backup(&app).await.unwrap();
    let mut kept: Vec<_> = std::fs::read_dir(dir.path().join("backups")).unwrap().flatten().map(|e| e.file_name().into_string().unwrap()).collect();
    kept.sort();
    assert_eq!(kept.len(), 7);
    assert_eq!(kept[0], "hermes-memory-2020-01-04.surql");

    let restored: db::Database = Surreal::new::<Mem>(()).await.unwrap();
    restored.use_ns("hermes").use_db("memory").await.unwrap();
    restored.import(&path).await.unwrap();
    db::prepare(&restored).await.unwrap();
    let rows = db::rows(&restored, "SELECT record::id(id) AS id, content, <-supersedes<-memory AS replaced_by, commitment.due_at AS due FROM memory ORDER BY id", vec![]).await.unwrap();
    println!("{rows:#?}");
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0]["replaced_by"].as_array().unwrap().len(), 1);
    assert!(rows[1]["due"].is_string());
    // Numbering continues after a restore, and search still works.
    let next = memory::remember(&restored, m, &json!({"kind": "fact", "content": "The owner has a NAS."}), &desktop(), "stated").await.unwrap();
    assert_eq!(next["id"], json!(4));
    let found = db::rows(&restored, "SELECT VALUE record::id(id) FROM memory WHERE content @1,OR@ 'fullerton'", vec![]).await.unwrap();
    assert_eq!(found, vec![json!(3)]);
}
