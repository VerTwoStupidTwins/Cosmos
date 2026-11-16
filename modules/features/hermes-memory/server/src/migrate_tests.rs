//! Importing a Postgres dump, and the consistency check.

use serde_json::{Value, json};
use surrealdb::Surreal;
use surrealdb::engine::local::Mem;

use crate::check;
use crate::db::{self, Database};
use crate::import;
use crate::memory::{self, Caller};
use crate::models::Models;

async fn empty() -> Database {
    let db: Database = Surreal::new::<Mem>(()).await.unwrap();
    db::prepare(&db).await.unwrap();
    db
}

fn desktop() -> Caller {
    Caller { platform: "desktop".into(), remote: false, session_id: None, actor: "hermes/main".into() }
}

/// What dump-postgres.sql writes, with Postgres' timestamp format.
fn dump() -> Value {
    let vec = |seed: f32| json!((0..256).map(|i| ((i as f32 + seed) * 0.37).sin()).collect::<Vec<_>>());
    json!({
        "memories": [
            {"id": 7, "kind": "fact", "content": "The owner lives in Buena Park.", "embedding": vec(1.0),
             "origin": "stated", "confidence": 1, "importance": 4, "privacy": "local_only", "platforms": [],
             "valid_from": "2026-11-13T10:15:02.123456-08:00", "valid_until": "2026-11-14T09:00:00-08:00",
             "superseded_by": 9, "retracted": false, "confirmed_at": null,
             "created_at": "2026-11-13T10:15:02.123456-08:00", "updated_at": "2026-11-14T09:00:00-08:00",
             "last_recalled_at": null, "recall_count": 3,
             "sources": [{"platform": "desktop", "session_id": "abc", "said_at": "2026-11-13T10:15:02.123456-08:00"}],
             "commitment": null},
            {"id": 8, "kind": "commitment", "content": "Remind the owner to renew the domain.", "embedding": vec(2.0),
             "origin": "inferred", "confidence": 0.7, "importance": 3, "privacy": "normal", "platforms": ["telegram"],
             "valid_from": "2026-11-13T11:00:00-08:00", "valid_until": null, "superseded_by": null,
             "retracted": false, "confirmed_at": "2026-11-13T12:00:00-08:00",
             "created_at": "2026-11-13T11:00:00-08:00", "updated_at": "2026-11-13T12:00:00-08:00",
             "last_recalled_at": "2026-11-14T08:00:00-08:00", "recall_count": 1, "sources": [],
             "commitment": {"due_at": "2026-12-01T09:00:00-08:00", "condition": null, "status": "open", "resolved_at": null}},
            {"id": 9, "kind": "fact", "content": "The owner lives in Fullerton.", "embedding": null,
             "origin": "stated", "confidence": 1, "importance": 4, "privacy": "local_only", "platforms": [],
             "valid_from": "2026-11-14T09:00:00-08:00", "valid_until": null, "superseded_by": null,
             "retracted": false, "confirmed_at": null, "created_at": "2026-11-14T09:00:00-08:00",
             "updated_at": "2026-11-14T09:00:00-08:00", "last_recalled_at": null, "recall_count": 0,
             "sources": [{"platform": "telegram", "session_id": null, "said_at": "2026-11-14T09:00:00-08:00"}],
             "commitment": null}
        ],
        "history": [
            {"memory_id": 5, "action": "create", "before": null, "after": null, "actor": "hermes/main", "reason": null, "at": "2026-11-12T08:00:00-08:00"},
            {"memory_id": 5, "action": "forget", "before": null, "after": null, "actor": "hermes/main", "reason": null, "at": "2026-11-12T09:00:00-08:00"},
            {"memory_id": 7, "action": "create", "before": null, "after": {"kind": "fact", "content": "The owner lives in Buena Park.", "valid_until": null}, "actor": "hermes/main", "reason": null, "at": "2026-11-13T10:15:02.123456-08:00"},
            {"memory_id": 8, "action": "create", "before": null, "after": {"kind": "commitment"}, "actor": "hermes/capture", "reason": null, "at": "2026-11-13T11:00:00-08:00"},
            {"memory_id": 9, "action": "create", "before": null, "after": {"kind": "fact"}, "actor": "hermes/main", "reason": "replaces #7", "at": "2026-11-14T09:00:00-08:00"},
            {"memory_id": 7, "action": "replace", "before": {"valid_until": null}, "after": {"valid_until": "2026-11-14T17:00:00+00:00"}, "actor": "hermes/main", "reason": "moved", "at": "2026-11-14T09:00:00-08:00"}
        ],
        "observations": [
            {"platform": "telegram", "remote": true, "session_id": null, "user_message": "we got a cat",
             "assistant_response": "Nice!", "received_at": "2026-11-15T10:00:00-08:00", "attempts": 1}
        ],
        // #10 and #11 were forgotten, so the next number is 12.
        "last_id": 11
    })
}

#[tokio::test]
async fn a_postgres_dump_imports_exactly() {
    let db = empty().await;
    let summary = import::import(&db, &Models::Fake, &dump()).await.unwrap();
    assert_eq!(
        summary,
        "imported 3 memories (1 embedded again), 1 replacement links, 6 history entries and 1 waiting turns; next number 12"
    );
    let rows = db::rows(
        &db,
        "SELECT record::id(id) AS id, privacy, platforms, recall_count, confidence, origin, sources,
             <string>valid_from AS valid_from, <string>confirmed_at AS confirmed, commitment, array::len(embedding) AS dims
         FROM memory ORDER BY id",
        vec![],
    )
    .await
    .unwrap();
    println!("{rows:#?}");
    assert_eq!(rows[0]["valid_from"], json!("2026-11-13T18:15:02.123456Z"), "exact time kept");
    assert_eq!(rows[0]["recall_count"], json!(3));
    assert_eq!(rows[0]["sources"][0]["session_id"], json!("abc"));
    assert_eq!(rows[1]["platforms"], json!(["telegram"]));
    assert_eq!(rows[1]["confidence"], json!(0.7));
    assert_eq!(rows[1]["commitment"]["status"], json!("open"));
    assert!(rows[1]["confirmed"].is_string());
    assert!(rows.iter().all(|r| r["dims"] == json!(256)));

    // The service sees them as the Python one did.
    let past = memory::list(&db, &json!({"include_past": true}), &desktop()).await.unwrap();
    let old = past["memories"].as_array().unwrap().iter().find(|m| m["id"] == json!(7)).unwrap().clone();
    assert_eq!(old["replaced_by"], json!(9));
    assert_eq!(old["current"], json!(false));
    let next = memory::remember(&db, &Models::Fake, &json!({"kind": "fact", "content": "The owner has a NAS."}), &desktop(), "stated").await.unwrap();
    assert_eq!(next["id"], json!(12), "forgotten numbers aren't reused");

    let (problems, summary) = check::check(&db).await.unwrap();
    assert!(problems.is_empty(), "{problems:?}");
    assert_eq!(summary["turns_waiting"], json!(1));
    assert_eq!(summary["links"], json!(1));

    // A second import into the same database is refused.
    assert!(import::import(&db, &Models::Fake, &dump()).await.is_err());
}

#[tokio::test]
async fn the_check_finds_damage() {
    let db = empty().await;
    import::import(&db, &Models::Fake, &dump()).await.unwrap();
    db::run(
        &db,
        "DELETE history WHERE memory_id = 8 AND action = 'create';
         UPDATE memory:9 SET commitment = { status: 'open' };
         UPDATE memory:7 SET valid_until = NONE;
         UPSERT counter:memory SET n = 3;",
        vec![],
    )
    .await
    .unwrap();
    let (problems, _) = check::check(&db).await.unwrap();
    let text = problems.join("\n");
    println!("{text}");
    assert!(text.contains("#8 has no 'create' history entry"));
    assert!(text.contains("#9 is a \"fact\" but its commitment details"));
    assert!(text.contains("#7 was replaced but is still current"));
    assert!(text.contains("is above the counter (3)"));
}
