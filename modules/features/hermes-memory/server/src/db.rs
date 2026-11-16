//! The embedded database: opening it, its schema, and plain JSON in and out of SurrealQL.

use std::collections::HashMap;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde_json::Value;
use surrealdb::Surreal;
use surrealdb::engine::local::Db;

pub type Database = Surreal<Db>;

const SCHEMA: &str = include_str!("schema.surql");

/// Opens the on-disk database, creating it when it doesn't exist, and applies the schema.
pub async fn open(path: &Path) -> Result<Database> {
    // SurrealKV sizes its cache from the machine's memory, which on lugh came to 32 GB beside main's own
    // prompt cache. The memories and wiki index take a few megabytes.
    let config = surrealdb::opt::Config::new()
        .datastore_option("surrealkv_block_cache_capacity", 64 * 1024 * 1024)
        .datastore_option("surrealkv_max_memtable_size", 16 * 1024 * 1024)
        // Large queries spill to disk here, beside the database, rather than in a /tmp shared with others.
        .temporary_directory(Some(path.with_extension("spill")));
    let db = Surreal::new::<surrealdb::engine::local::SurrealKv>((path, config))
        .await
        .with_context(|| format!("opening {}", path.display()))?;
    prepare(&db).await?;
    Ok(db)
}

/// Applies the schema to a database that's already open, such as an in-memory one in tests.
pub async fn prepare(db: &Database) -> Result<()> {
    db.use_ns("hermes").use_db("memory").await?;
    db.query(SCHEMA).await?.check().context("applying the schema")?;
    Ok(())
}

/// Runs SurrealQL with named parameters and returns each statement's result as JSON.
pub async fn run(db: &Database, sql: &str, params: Vec<(&str, Value)>) -> Result<Vec<Value>> {
    let vars: HashMap<String, Value> = params.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
    let mut response = db.query(sql).bind(vars).await?;
    let errors = response.take_errors();
    if !errors.is_empty() {
        let mut list: Vec<_> = errors.into_iter().collect();
        list.sort_by_key(|(i, _)| *i);
        bail!("{}", list.into_iter().map(|(i, e)| format!("statement {i}: {e}")).collect::<Vec<_>>().join("; "));
    }
    // Results come back as SurrealDB's own values, which convert to JSON with record ids and datetimes as strings.
    (0..response.num_statements())
        .map(|i| Ok(response.take::<surrealdb::types::Value>(i)?.into_json_value()))
        .collect()
}

/// The rows of a single-statement query.
pub async fn rows(db: &Database, sql: &str, params: Vec<(&str, Value)>) -> Result<Vec<Value>> {
    match run(db, sql, params).await?.pop() {
        Some(Value::Array(rows)) => Ok(rows),
        Some(Value::Null) | None => Ok(vec![]),
        Some(other) => Ok(vec![other]),
    }
}
