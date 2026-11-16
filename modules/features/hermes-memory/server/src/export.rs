//! The memory export, one wiki page per kind, and the nightly database backup.

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use chrono::{Local, Utc};
use serde_json::{Value, json};

use crate::App;
use crate::db;
use crate::memory::MEMORY_FIELDS;

const EXPORT_FILES: [(&str, &str, &str); 5] = [
    ("preference", "preferences.md", "Preferences"),
    ("procedure", "procedures.md", "How the owner likes things done"),
    ("fact", "facts.md", "Facts"),
    ("event", "events.md", "Events"),
    ("commitment", "commitments.md", "Commitments"),
];
/// Backups kept, one per night.
const BACKUPS_KEPT: usize = 7;

fn write_atomic(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn local(value: &Value) -> Option<chrono::DateTime<Local>> {
    chrono::DateTime::parse_from_rfc3339(value.as_str()?).ok().map(|d| d.with_timezone(&Local))
}

/// One OKF page per kind. Local-only memories never leave lugh, so they're left out.
pub async fn export(app: &App) -> Result<()> {
    std::fs::create_dir_all(&app.export_dir)?;
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
    let mut rows = db::rows(
        &app.db,
        &format!(
            "SELECT {MEMORY_FIELDS} FROM memory
             WHERE privacy = 'normal' AND retracted = false AND valid_until = NONE"
        ),
        vec![],
    )
    .await?;
    // Most important first, then oldest first.
    rows.sort_by(|a, b| {
        b["importance"].as_i64().cmp(&a["importance"].as_i64()).then_with(|| a["valid_from"].as_str().cmp(&b["valid_from"].as_str()))
    });
    for (kind, file, title) in EXPORT_FILES {
        let description = format!("Hermes memory: {}. Generated, so edits here are overwritten.", title.to_lowercase());
        let mut lines = vec![
            "---".to_string(),
            "type: Memory Export".into(),
            format!("title: {}", json!(title)),
            format!("description: {}", json!(description)),
            format!("generated: {{ by: process:hermes-memory, at: {now} }}"),
            "---".into(),
            String::new(),
            format!("# {title}"),
            String::new(),
            "Generated from Hermes' memory database. To change something, tell Hermes.".into(),
            String::new(),
        ];
        for r in rows.iter().filter(|r| r["kind"] == kind) {
            let mut notes = vec![r["origin"].as_str().unwrap_or("").to_string()];
            if !r["confirmed_at"].is_null() {
                notes.push("confirmed".into());
            }
            let platforms: Vec<&str> = r["platforms"].as_array().into_iter().flatten().filter_map(|p| p.as_str()).collect();
            if !platforms.is_empty() {
                notes.push(format!("only {}", platforms.join(", ")));
            }
            if kind == "commitment" {
                if let Some(due) = local(&r["commitment"]["due_at"]) {
                    notes.push(format!("due {}", due.format("%Y-%m-%d %H:%M")));
                }
                if let Some(c) = r["commitment"]["condition"].as_str() {
                    notes.push(format!("when {c}"));
                }
            }
            if let Some(since) = local(&r["valid_from"]) {
                notes.push(format!("since {}", since.date_naive()));
            }
            lines.push(format!("- **#{}** {} _({})_", r["id"], r["content"].as_str().unwrap_or(""), notes.join("; ")));
        }
        write_atomic(&app.export_dir.join(file), &(lines.join("\n") + "\n"))?;
    }
    Ok(())
}

/// Rewrites the export shortly after the last change, so a burst of edits writes once.
pub fn schedule(app: &App) {
    use std::sync::atomic::Ordering;
    let ticket = app.export_ticket.fetch_add(1, Ordering::SeqCst) + 1;
    let app = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        if app.export_ticket.load(Ordering::SeqCst) == ticket {
            if let Err(e) = export(&app).await {
                tracing::error!("export failed: {e:#}");
            }
        }
    });
}

/// Writes the whole database as SurrealQL and keeps the newest few. Returns the file written.
pub async fn backup(app: &App) -> Result<String> {
    let dir = app.backup_dir.as_ref().context("no --backup-dir given")?;
    std::fs::create_dir_all(dir)?;
    let name = format!("hermes-memory-{}.surql", Local::now().format("%Y-%m-%d"));
    let path = dir.join(&name);
    let tmp = dir.join(format!("{name}.tmp"));
    app.db.export(&tmp).await.context("exporting the database")?;
    std::fs::rename(&tmp, &path)?;
    let mut old: Vec<_> = std::fs::read_dir(dir)?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.starts_with("hermes-memory-") && n.ends_with(".surql"))
        .collect();
    old.sort();
    for n in old.iter().rev().skip(BACKUPS_KEPT) {
        let _ = std::fs::remove_file(dir.join(n));
    }
    Ok(path.display().to_string())
}

/// Backs up once soon after starting when today has no backup yet, then every night at 3:30.
pub async fn nightly(app: App) {
    use chrono::{Duration as Days, NaiveTime, TimeZone};
    let Some(dir) = app.backup_dir.clone() else { return };
    let today = dir.join(format!("hermes-memory-{}.surql", Local::now().format("%Y-%m-%d")));
    let mut first = !today.exists();
    loop {
        if !first {
            let now = Local::now();
            let mut next = now.date_naive().and_time(NaiveTime::from_hms_opt(3, 30, 0).unwrap());
            if next <= now.naive_local() {
                next += Days::days(1);
            }
            let wait = Local.from_local_datetime(&next).earliest().map(|t| t - now).and_then(|d| d.to_std().ok());
            tokio::time::sleep(wait.unwrap_or(Duration::from_secs(3600))).await;
        } else {
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
        first = false;
        match backup(&app).await {
            Ok(path) => tracing::info!("backup written to {path}"),
            Err(e) => tracing::error!("backup failed: {e:#}"),
        }
    }
}
