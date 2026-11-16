//! Remember, revise and list, with the rules each enforces. Embeddings are faked from word counts.

use serde_json::{Value, json};
use surrealdb::Surreal;
use surrealdb::engine::local::Mem;

use crate::db::{self, Database};
use crate::memory::{self, BadRequest, Caller};
use crate::models::Models;

async fn setup() -> (Database, Models) {
    let db: Database = Surreal::new::<Mem>(()).await.unwrap();
    db::prepare(&db).await.unwrap();
    (db, Models::Fake)
}

fn desktop() -> Caller {
    Caller { platform: "desktop".into(), remote: false, session_id: Some("s1".into()), actor: "hermes/main".into() }
}

fn telegram() -> Caller {
    Caller { platform: "telegram".into(), remote: true, session_id: None, actor: "hermes/main".into() }
}

async fn remember(db: &Database, m: &Models, body: Value) -> Value {
    memory::remember(db, m, &body, &desktop(), "stated").await.unwrap()
}

async fn revise(db: &Database, m: &Models, caller: &Caller, body: Value) -> Value {
    memory::revise(db, m, &body, caller, "stated").await.unwrap()
}

async fn list(db: &Database, caller: &Caller, body: Value) -> Vec<Value> {
    memory::list(db, &body, caller).await.unwrap()["memories"].as_array().unwrap().clone()
}

#[tokio::test]
async fn remembering_numbers_memories_and_refuses_duplicates() {
    let (db, m) = setup().await;
    let a = remember(&db, &m, json!({"kind": "fact", "content": "The owner has a husky named Koda."})).await;
    assert_eq!(a, json!({"status": "saved", "id": 1}));
    let b = remember(&db, &m, json!({"kind": "preference", "content": "The owner likes the color green.", "importance": 9})).await;
    assert_eq!(b["id"], json!(2));
    // The same sentence again is a duplicate of #1.
    let dup = remember(&db, &m, json!({"kind": "fact", "content": "The owner has a husky named Koda."})).await;
    assert_eq!(dup["status"], json!("duplicate"));
    assert_eq!(dup["existing"]["id"], json!(1));
    // Close but different is saved, with the related memory pointed out.
    let near = remember(&db, &m, json!({"kind": "fact", "content": "The owner has a husky named Koda who is three."})).await;
    assert_eq!(near["status"], json!("saved"));
    assert_eq!(near["similar"][0]["id"], json!(1));

    let all = list(&db, &desktop(), json!({})).await;
    assert_eq!(all.len(), 3);
    let green = all.iter().find(|r| r["id"] == json!(2)).unwrap();
    assert_eq!(green["importance"], json!(5), "importance is clamped to 1-5");
    assert_eq!(green["platforms"], json!(["all"]));
    assert_eq!(green["origin"], json!("stated"));
    assert_eq!(green["confirmed"], json!(false));
    assert!(green["since"].as_str().unwrap().len() == 10);
}

#[tokio::test]
async fn bad_requests_are_reported_as_such() {
    let (db, m) = setup().await;
    for body in [
        json!({"kind": "gossip", "content": "x"}),
        json!({"kind": "fact", "content": "  "}),
        json!({"kind": "fact", "content": "x", "privacy": "secret"}),
        json!({"kind": "commitment", "content": "x", "due": "next tuesday"}),
    ] {
        let err = memory::remember(&db, &m, &body, &desktop(), "stated").await.unwrap_err();
        assert!(err.downcast_ref::<BadRequest>().is_some(), "{body} gave {err}");
    }
    let err = memory::revise(&db, &m, &json!({"id": 1, "action": "explode"}), &desktop(), "stated").await;
    // Unknown memories are answered before the action is checked, as in the Python service.
    assert_eq!(err.unwrap()["error"], json!("No memory #1 that you can change."));
}

#[tokio::test]
async fn private_and_platform_memories_stay_where_they_belong() {
    let (db, m) = setup().await;
    remember(&db, &m, json!({"kind": "fact", "content": "The owner's bank is in Fullerton.", "privacy": "local_only"})).await;
    remember(&db, &m, json!({"kind": "preference", "content": "The owner wants short replies on Telegram.", "platforms": ["Telegram"]})).await;
    remember(&db, &m, json!({"kind": "preference", "content": "The owner likes detailed answers on the desktop.", "platforms": ["desktop"]})).await;

    let on_desktop: Vec<_> = list(&db, &desktop(), json!({})).await.iter().map(|r| r["id"].clone()).collect();
    let on_telegram: Vec<_> = list(&db, &telegram(), json!({})).await.iter().map(|r| r["id"].clone()).collect();
    assert!(on_desktop.contains(&json!(1)) && on_desktop.contains(&json!(3)) && !on_desktop.contains(&json!(2)));
    assert_eq!(on_telegram, vec![json!(2)], "remote chats see neither local-only nor desktop-only memories");
    // A memory a caller can't see can't be changed by it either.
    let r = revise(&db, &m, &telegram(), json!({"id": 1, "action": "forget"})).await;
    assert_eq!(r["error"], json!("No memory #1 that you can change."));
}

#[tokio::test]
async fn replacing_keeps_history_and_links_the_two() {
    let (db, m) = setup().await;
    remember(&db, &m, json!({"kind": "fact", "content": "The owner lives in Buena Park.", "importance": 4, "privacy": "local_only"})).await;
    let r = revise(&db, &m, &desktop(), json!({"id": 1, "action": "replace", "content": "The owner lives in Fullerton.", "reason": "moved"})).await;
    assert_eq!(r, json!({"status": "replaced", "id": 1, "new_id": 2}));

    let current = list(&db, &desktop(), json!({})).await;
    assert_eq!(current.len(), 1);
    assert_eq!(current[0]["id"], json!(2));
    assert_eq!(current[0]["importance"], json!(4), "the replacement keeps importance and privacy");
    assert_eq!(current[0]["privacy"], json!("local_only"));

    let past = list(&db, &desktop(), json!({"include_past": true})).await;
    let old = past.iter().find(|r| r["id"] == json!(1)).unwrap();
    assert_eq!(old["current"], json!(false));
    assert_eq!(old["replaced_by"], json!(2));
    assert!(old["until"].is_string());

    // An old memory can't be replaced again.
    let again = revise(&db, &m, &desktop(), json!({"id": 1, "action": "replace", "content": "x"})).await;
    assert_eq!(again["error"], json!("#1 is no longer current, so it can't be replaced."));
    let empty = revise(&db, &m, &desktop(), json!({"id": 2, "action": "replace"})).await;
    assert_eq!(empty["error"], json!("replace needs the new content."));

    let history = db::rows(&db, "SELECT memory_id, action, reason, before.content AS was, after.valid_until AS ended FROM history ORDER BY at, memory_id", vec![]).await.unwrap();
    println!("{history:#?}");
    let actions: Vec<_> = history.iter().map(|h| (h["memory_id"].as_i64().unwrap(), h["action"].as_str().unwrap().to_string())).collect();
    assert_eq!(actions, vec![(1, "create".into()), (2, "create".into()), (1, "replace".into())]);
    assert_eq!(history[1]["reason"], json!("replaces #1"));
    assert_eq!(history[2]["was"], json!("The owner lives in Buena Park."));
    assert!(history[2]["ended"].is_string());
}

#[tokio::test]
async fn retracted_memories_never_come_back() {
    let (db, m) = setup().await;
    remember(&db, &m, json!({"kind": "fact", "content": "The owner has a cat."})).await;
    let r = revise(&db, &m, &desktop(), json!({"id": 1, "action": "retract", "reason": "misheard"})).await;
    assert_eq!(r, json!({"status": "retracted", "id": 1}));
    assert!(list(&db, &desktop(), json!({"include_past": true})).await.is_empty());
    // Retracting with a correction saves the correction and links it.
    remember(&db, &m, json!({"kind": "fact", "content": "The owner has a dog."})).await;
    let r = revise(&db, &m, &desktop(), json!({"id": 2, "action": "retract", "content": "The owner has two dogs."})).await;
    assert_eq!(r["new_id"], json!(3));
}

#[tokio::test]
async fn forgetting_erases_content_everywhere() {
    let (db, m) = setup().await;
    remember(&db, &m, json!({"kind": "fact", "content": "The owner's secret hobby is karaoke."})).await;
    revise(&db, &m, &desktop(), json!({"id": 1, "action": "confirm"})).await;
    let r = revise(&db, &m, &desktop(), json!({"id": 1, "action": "forget"})).await;
    assert_eq!(r, json!({"status": "forgotten", "id": 1}));
    assert!(list(&db, &desktop(), json!({"include_past": true})).await.is_empty());
    let history = db::rows(&db, "SELECT action, before, after FROM history ORDER BY at", vec![]).await.unwrap();
    let actions: Vec<_> = history.iter().map(|h| h["action"].as_str().unwrap()).collect();
    assert_eq!(actions, vec!["create", "confirm", "forget"]);
    let dump = serde_json::to_string(&history).unwrap();
    assert!(!dump.contains("karaoke"), "history still holds the content: {dump}");
    // The number isn't reused.
    let next = remember(&db, &m, json!({"kind": "fact", "content": "The owner sings."})).await;
    assert_eq!(next["id"], json!(2));
}

#[tokio::test]
async fn commitments_have_dates_and_resolve() {
    let (db, m) = setup().await;
    remember(&db, &m, json!({"kind": "commitment", "content": "Remind the owner to renew the domain.", "due": "2026-12-01T09:00"})).await;
    remember(&db, &m, json!({"kind": "commitment", "content": "Ask the owner about the NAS.", "condition": "the NAS is set up"})).await;
    remember(&db, &m, json!({"kind": "commitment", "content": "Remind the owner about taxes.", "due": "2026-11-20"})).await;
    remember(&db, &m, json!({"kind": "fact", "content": "The owner has a NAS."})).await;

    let open = list(&db, &desktop(), json!({"kind": "commitment", "status": "open"})).await;
    let order: Vec<_> = open.iter().map(|r| r["id"].clone()).collect();
    assert_eq!(order, vec![json!(3), json!(1), json!(2)], "by due date, undated last");
    let renew = &open[1]["commitment"];
    assert_eq!(renew["status"], json!("open"));
    assert!(renew["due"].as_str().unwrap().starts_with("2026-12-01T09:00:00"), "{renew}");
    assert_eq!(open[2]["commitment"]["condition"], json!("the NAS is set up"));

    let not_one = revise(&db, &m, &desktop(), json!({"id": 4, "action": "complete"})).await;
    assert_eq!(not_one["error"], json!("#4 isn't a commitment."));
    let done = revise(&db, &m, &desktop(), json!({"id": 3, "action": "complete"})).await;
    assert_eq!(done, json!({"status": "done", "id": 3}));
    let cancelled = revise(&db, &m, &desktop(), json!({"id": "#2", "action": "cancel"})).await;
    assert_eq!(cancelled["status"], json!("cancelled"));
    assert_eq!(list(&db, &desktop(), json!({"status": "open"})).await.len(), 1);
    let finished = list(&db, &desktop(), json!({"status": "done", "include_past": true})).await;
    assert_eq!(finished[0]["commitment"]["status"], json!("done"));

    // Replacing a commitment keeps its date unless a new one is given.
    let r = revise(&db, &m, &desktop(), json!({"id": 1, "action": "replace", "content": "Remind the owner to renew both domains."})).await;
    let new = list(&db, &desktop(), json!({"kind": "commitment"})).await.into_iter().find(|x| x["id"] == r["new_id"]).unwrap();
    assert!(new["commitment"]["due"].as_str().unwrap().starts_with("2026-12-01T09:00:00"));
}

#[tokio::test]
async fn inferred_memories_are_marked() {
    let (db, m) = setup().await;
    memory::remember(&db, &m, &json!({"kind": "fact", "content": "The owner uses NixOS."}), &desktop(), "inferred").await.unwrap();
    let rows = db::rows(&db, "SELECT origin, confidence FROM memory", vec![]).await.unwrap();
    assert_eq!(rows[0]["origin"], json!("inferred"));
    assert_eq!(rows[0]["confidence"], json!(0.7));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_replaces_of_one_memory_let_one_win() {
    let (db, m) = setup().await;
    remember(&db, &m, json!({"kind": "fact", "content": "The owner lives in Buena Park."})).await;
    let tasks: Vec<_> = (0..10)
        .map(|i| {
            let (db, m) = (db.clone(), m.clone());
            tokio::spawn(async move {
                let body = json!({"id": 1, "action": "replace", "content": format!("The owner lives in town number {i}.")});
                memory::revise(&db, &m, &body, &desktop(), "stated").await.unwrap()
            })
        })
        .collect();
    let mut replaced = 0;
    for t in tasks {
        let out = t.await.unwrap();
        if out["status"] == "replaced" {
            replaced += 1;
        } else {
            assert_eq!(out["error"], json!("#1 is no longer current, so it can't be replaced."));
        }
    }
    assert_eq!(replaced, 1);
    assert_eq!(list(&db, &desktop(), json!({})).await.len(), 1, "one current memory");
    let (problems, _) = crate::check::check(&db).await.unwrap();
    assert!(problems.is_empty(), "{problems:?}");
}
