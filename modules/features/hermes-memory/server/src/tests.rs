//! Checks of the SurrealQL the service relies on, against the SurrealDB version it's built with.

use serde_json::{Value, json};
use surrealdb::Surreal;
use surrealdb::engine::local::Mem;

use crate::db::{self, Database};

async fn memory_db() -> Database {
    let db: Database = Surreal::new::<Mem>(()).await.unwrap();
    db::prepare(&db).await.unwrap();
    db
}

fn vec3(a: f64, b: f64, c: f64) -> Value {
    json!([a, b, c])
}

async fn add(db: &Database, id: i64, kind: &str, content: &str, embedding: Value) {
    db::run(
        db,
        "CREATE type::record('memory', $id) CONTENT { kind: $kind, content: $content, embedding: $embedding,
            sources: [{ platform: 'desktop', session_id: 's1', said_at: time::now() }] };",
        vec![("id", json!(id)), ("kind", json!(kind)), ("content", json!(content)), ("embedding", embedding)],
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn schema_applies_again() {
    let db = memory_db().await;
    db::prepare(&db).await.unwrap();
}

#[tokio::test]
async fn memories_keep_their_numbers_and_nested_fields() {
    let db = memory_db().await;
    add(&db, 12, "fact", "The owner goes by twins.", vec3(1.0, 0.0, 0.0)).await;
    db::run(
        &db,
        "CREATE memory:40 CONTENT { kind: 'commitment', content: 'Remind the owner about the NAS.',
            embedding: [0.0, 1.0, 0.0], commitment: { status: 'open', condition: 'the NAS is set up' } };",
        vec![],
    )
    .await
    .unwrap();
    let rows = db::rows(
        &db,
        "SELECT record::id(id) AS id, kind, sources, commitment, importance, privacy, platforms, valid_until
         FROM memory ORDER BY id",
        vec![],
    )
    .await
    .unwrap();
    println!("{rows:#?}");
    assert_eq!(rows[0]["id"], json!(12));
    assert_eq!(rows[0]["sources"][0]["platform"], json!("desktop"));
    assert_eq!(rows[0]["importance"], json!(3));
    assert_eq!(rows[1]["commitment"]["condition"], json!("the NAS is set up"));
    // A value outside the allowed set is refused, as Postgres' check constraints did.
    assert!(db::run(&db, "CREATE memory:41 CONTENT { kind: 'gossip', content: 'x', embedding: [] };", vec![])
        .await
        .is_err());
}

#[tokio::test]
async fn keyword_search_stems_and_matches_any_word() {
    let db = memory_db().await;
    add(&db, 1, "fact", "The owner is training for the LA Marathon.", vec3(1.0, 0.0, 0.0)).await;
    add(&db, 2, "preference", "The owner likes the color green.", vec3(0.0, 1.0, 0.0)).await;
    add(&db, 3, "fact", "The owner runs NixOS on their homelab.", vec3(0.0, 0.0, 1.0)).await;

    let search = |q: &'static str| {
        let db = db.clone();
        async move {
            db::rows(
                &db,
                "SELECT record::id(id) AS id, search::score(1) AS score FROM memory
                 WHERE content @1@ $q ORDER BY score DESC",
                vec![("q", json!(q))],
            )
            .await
            .unwrap()
        }
    };
    // Stemming: "trained" finds "training".
    let found = search("trained").await;
    println!("trained: {found:?}");
    assert_eq!(found.first().map(|r| r["id"].clone()), Some(json!(1)));
    // Two words that never appear together: does the operator match either word, or need both?
    let either = search("marathon green").await;
    println!("marathon green: {either:?}");
    let scores: Vec<f64> = search("homelab").await.iter().map(|r| r["score"].as_f64().unwrap()).collect();
    println!("homelab scores: {scores:?}");
    assert!(scores.iter().all(|s| *s > 0.0));
}

#[tokio::test]
async fn or_keyword_search() {
    let db = memory_db().await;
    add(&db, 1, "fact", "The owner is training for the LA Marathon.", vec3(1.0, 0.0, 0.0)).await;
    add(&db, 2, "preference", "The owner likes the color green.", vec3(0.0, 1.0, 0.0)).await;
    let result = db::rows(
        &db,
        "SELECT record::id(id) AS id, search::score(1) AS score FROM memory
         WHERE content @1,OR@ $q ORDER BY score DESC",
        vec![("q", json!("marathon green"))],
    )
    .await;
    println!("@1,OR@: {result:?}");
}

#[tokio::test]
async fn replacements_link_and_unlink() {
    let db = memory_db().await;
    add(&db, 7, "fact", "The owner lives in Buena Park.", vec3(1.0, 0.0, 0.0)).await;
    add(&db, 8, "fact", "The owner lives in Fullerton.", vec3(1.0, 0.1, 0.0)).await;
    db::run(&db, "RELATE memory:8->supersedes->memory:7; UPDATE memory:7 SET valid_until = time::now();", vec![])
        .await
        .unwrap();
    let old = db::rows(&db, "SELECT record::id(id) AS id, record::id((<-supersedes<-memory)[0]) AS replaced_by FROM memory:7", vec![])
        .await
        .unwrap();
    println!("{old:?}");
    assert_eq!(old[0]["replaced_by"], json!(8));
    // Forgetting the replacement removes the link with it.
    db::run(&db, "DELETE memory:8;", vec![]).await.unwrap();
    let edges = db::run(&db, "RETURN count(SELECT id FROM supersedes);", vec![]).await.unwrap();
    assert_eq!(edges[0], json!(0));
}

#[tokio::test]
async fn wiki_sections_go_with_their_page() {
    let db = memory_db().await;
    db::run(
        &db,
        "CREATE type::record('wiki_page', $path) CONTENT { mtime: 1.5, size: 10, hash: 'h', title: 'X',
             details: { status: 'stable', trust: 'unverified' } };
         CREATE wiki_chunk CONTENT { page: type::record('wiki_page', $path), heading: 'H', text: 'mmWave sensors',
             search_text: 'H mmWave sensors', embedding: [1.0, 0.0, 0.0] };",
        vec![("path", json!("/topics/x.md"))],
    )
    .await
    .unwrap();
    let info = db::rows(&db, "SELECT details.status AS status, record::id(id) AS path FROM wiki_page", vec![]).await.unwrap();
    println!("{info:?}");
    assert_eq!(info[0]["status"], json!("stable"));
    assert_eq!(info[0]["path"], json!("/topics/x.md"));
    db::run(&db, "DELETE type::record('wiki_page', $path);", vec![("path", json!("/topics/x.md"))]).await.unwrap();
    let left = db::run(&db, "RETURN count(SELECT id FROM wiki_chunk);", vec![]).await.unwrap();
    assert_eq!(left[0], json!(0));
}

#[tokio::test]
async fn meaning_search_orders_by_cosine() {
    let db = memory_db().await;
    add(&db, 1, "fact", "a", vec3(1.0, 0.0, 0.0)).await;
    add(&db, 2, "fact", "b", vec3(0.0, 1.0, 0.0)).await;
    add(&db, 3, "fact", "c", vec3(0.9, 0.1, 0.0)).await;
    let rows = db::rows(
        &db,
        "SELECT record::id(id) AS id, vector::similarity::cosine(embedding, $q) AS similarity FROM memory
         ORDER BY similarity DESC LIMIT 2",
        vec![("q", vec3(1.0, 0.0, 0.0))],
    )
    .await
    .unwrap();
    println!("{rows:?}");
    assert_eq!(rows.iter().map(|r| r["id"].clone()).collect::<Vec<_>>(), vec![json!(1), json!(3)]);
}

#[tokio::test]
async fn numbers_are_counted_in_a_transaction() {
    let db = memory_db().await;
    let next = "BEGIN;
        LET $n = (UPSERT ONLY counter:memory SET n += 1 RETURN AFTER).n;
        CREATE type::record('memory', $n) CONTENT { kind: 'fact', content: 'x', embedding: [] };
        RETURN $n;
        COMMIT;";
    db::run(&db, next, vec![]).await.unwrap();
    db::run(&db, next, vec![]).await.unwrap();
    let ids = db::rows(&db, "SELECT VALUE record::id(id) FROM memory ORDER BY id", vec![]).await.unwrap();
    assert_eq!(ids, vec![json!(1), json!(2)]);
}

#[tokio::test]
async fn data_survives_reopening() {
    let dir = tempfile::tempdir().unwrap();
    {
        let db = db::open(dir.path()).await.unwrap();
        add(&db, 5, "fact", "The owner has a husky named Koda.", vec3(1.0, 0.0, 0.0)).await;
    }
    // The first handle has to be gone before the directory opens again.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let db = db::open(dir.path()).await.unwrap();
    let rows = db::rows(&db, "SELECT content FROM memory:5", vec![]).await.unwrap();
    assert_eq!(rows[0]["content"], json!("The owner has a husky named Koda."));
}
