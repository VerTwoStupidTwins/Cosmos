//! The wiki index: pages split into sections, embedded for meaning search, and kept up to date with the files.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use regex::Regex;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::App;
use crate::db;
use crate::models;

/// Wiki sections longer than this are split at paragraphs, so a query and one section fit the reranker's batch.
pub const MAX_CHARS: usize = 3000;
/// OKF reserves these names at every level.
const RESERVED: [&str; 2] = ["index.md", "log.md"];
/// Searches re-check the files at most this often.
const RECHECK: Duration = Duration::from_secs(5);

static HEADING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^#{1,6}\s+(.*)").unwrap());
static FOOTNOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\[\^[^\]]+\]:.*$").unwrap());
static PARAGRAPH: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\n\s*\n").unwrap());
static FRONT_MATTER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)\A---\s*\n(.*?)\n---\s*\n?").unwrap());

pub fn root(wiki: &Path) -> PathBuf {
    std::fs::canonicalize(wiki).unwrap_or_else(|_| wiki.to_path_buf())
}

/// Wiki links of the pages to index, like /topics/x.md: Markdown files outside hidden folders and the memory export.
pub fn wiki_files(wiki: &Path, export: &Path) -> Vec<String> {
    let wiki = root(wiki);
    let export = root(export);
    let mut out = vec![];
    fn walk(dir: &Path, wiki: &Path, export: &Path, out: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        let (dirs, files): (Vec<_>, Vec<_>) = entries.into_iter().partition(|e| e.file_type().is_ok_and(|t| t.is_dir()));
        for f in files {
            let name = f.file_name().to_string_lossy().to_string();
            if name.ends_with(".md") && !RESERVED.contains(&name.as_str()) {
                if let Ok(rel) = f.path().strip_prefix(wiki) {
                    out.push(format!("/{}", rel.to_string_lossy()));
                }
            }
        }
        // Skips .obsidian, .trash and the memory export.
        for d in dirs {
            let name = d.file_name().to_string_lossy().to_string();
            if !name.starts_with('.') && d.path() != export {
                walk(&d.path(), wiki, export, out);
            }
        }
    }
    walk(&wiki, &wiki, &export, &mut out);
    out
}

fn yaml_to_json(y: &yaml_rust2::Yaml) -> Value {
    use yaml_rust2::Yaml;
    match y {
        Yaml::Real(s) => s.parse::<f64>().map(|f| json!(f)).unwrap_or_else(|_| json!(s)),
        Yaml::Integer(i) => json!(i),
        Yaml::String(s) => json!(s),
        Yaml::Boolean(b) => json!(b),
        Yaml::Array(a) => Value::Array(a.iter().map(yaml_to_json).collect()),
        Yaml::Hash(h) => Value::Object(
            h.iter()
                .map(|(k, v)| {
                    let key = match k {
                        Yaml::String(s) => s.clone(),
                        other => yaml_to_json(other).to_string().trim_matches('"').to_string(),
                    };
                    (key, yaml_to_json(v))
                })
                .collect::<Map<_, _>>(),
        ),
        _ => Value::Null,
    }
}

/// The front matter, and the page body after it.
pub fn parse_page(raw: &str) -> (Value, &str) {
    let Some(m) = FRONT_MATTER.captures(raw) else { return (json!({}), raw) };
    let meta = yaml_rust2::YamlLoader::load_from_str(&m[1])
        .ok()
        .and_then(|docs| docs.into_iter().next())
        .map(|d| yaml_to_json(&d))
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    (meta, &raw[m.get(0).unwrap().end()..])
}

fn take_chars(s: &str, n: usize) -> (&str, &str) {
    match s.char_indices().nth(n) {
        Some((i, _)) => s.split_at(i),
        None => (s, ""),
    }
}

/// (heading, text) pairs: one per heading, with long sections split at paragraphs.
pub fn sections(title: &str, body: &str) -> Vec<(String, String)> {
    let mut parts = vec![];
    let mut heading = title.to_string();
    let mut lines: Vec<&str> = vec![];
    for line in body.lines() {
        if let Some(found) = HEADING.captures(line) {
            parts.push((heading, lines.join("\n")));
            heading = found[1].trim().to_string();
            lines = vec![];
        } else {
            lines.push(line);
        }
    }
    parts.push((heading, lines.join("\n")));

    let mut out = vec![];
    for (heading, text) in parts {
        // Footnote definitions only repeat source titles.
        let text = FOOTNOTE.replace_all(&text, "");
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let mut chunk = String::new();
        for para in PARAGRAPH.split(text) {
            if !chunk.is_empty() && chunk.chars().count() + para.chars().count() > MAX_CHARS {
                out.push((heading.clone(), std::mem::take(&mut chunk)));
            }
            chunk = if chunk.is_empty() { para.to_string() } else { format!("{chunk}\n\n{para}") };
            while chunk.chars().count() > MAX_CHARS {
                let (head, rest) = take_chars(&chunk, MAX_CHARS);
                out.push((heading.clone(), head.to_string()));
                chunk = rest.to_string();
            }
        }
        if !chunk.is_empty() {
            out.push((heading.clone(), chunk));
        }
    }
    out
}

/// A date or time from front matter. One without an offset is UTC.
pub fn as_datetime(value: &Value) -> Option<DateTime<Utc>> {
    let text = value.as_str()?.trim().replace('Z', "+00:00");
    if let Ok(d) = DateTime::parse_from_rfc3339(&text) {
        return Some(d.with_timezone(&Utc));
    }
    ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S"]
        .iter()
        .find_map(|f| NaiveDateTime::parse_from_str(&text, f).ok())
        .or_else(|| NaiveDate::parse_from_str(&text, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)))
        .map(|n| n.and_utc())
}

fn text_of(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// What a search result says about its page: status, trust and staleness.
pub fn page_details(meta: &Value) -> Value {
    let verified = match &meta["verified"] {
        Value::Object(_) => vec![meta["verified"].clone()],
        Value::Array(a) => a.clone(),
        _ => vec![],
    };
    let by: Vec<String> = verified.iter().filter(|v| v.is_object()).map(|v| text_of(&v["by"])).collect();
    let trust = if by.iter().any(|b| b.starts_with("human:")) {
        "human-reviewed"
    } else if !by.is_empty() {
        "machine-confirmed"
    } else {
        "unverified"
    };
    let stale_after = as_datetime(&meta["stale_after"]).map(|d| d.to_rfc3339());
    let status = text_of(&meta["status"]);
    json!({
        "type": text_of(&meta["type"]),
        "status": if status.is_empty() { "stable".to_string() } else { status },
        "trust": trust,
        "stale_after": stale_after,
        "generated_by": if meta["generated"].is_object() { text_of(&meta["generated"]["by"]) } else { String::new() },
        "description": text_of(&meta["description"]),
    })
}

fn mtime_and_size(path: &Path) -> Option<(f64, i64)> {
    let m = std::fs::metadata(path).ok()?;
    let mtime = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
    Some((mtime, m.len() as i64))
}

/// Re-indexes wiki pages that changed and returns how many did. Unforced, it checks at most every few seconds.
pub async fn sync(app: &App, force: bool) -> Result<usize> {
    let mut checked = app.wiki_checked.lock().await;
    if !force && checked.is_some_and(|t| t.elapsed() < RECHECK) {
        return Ok(0);
    }
    let wiki = root(&app.wiki);
    let mut on_disk = std::collections::BTreeMap::new();
    for link in wiki_files(&app.wiki, &app.export_dir) {
        if let Some(stat) = mtime_and_size(&wiki.join(link.trim_start_matches('/'))) {
            on_disk.insert(link, stat);
        }
    }
    let known: std::collections::HashMap<String, Value> = db::rows(
        &app.db,
        "SELECT record::id(id) AS path, mtime, size, hash FROM wiki_page",
        vec![],
    )
    .await?
    .into_iter()
    .filter_map(|r| Some((r["path"].as_str()?.to_string(), r)))
    .collect();

    let mut changed = 0;
    for path in known.keys().filter(|p| !on_disk.contains_key(*p)) {
        db::run(&app.db, "DELETE type::record('wiki_page', $path);", vec![("path", json!(path))]).await?;
        changed += 1;
    }
    for (path, (mtime, size)) in &on_disk {
        let old = known.get(path);
        if old.is_some_and(|o| o["mtime"].as_f64() == Some(*mtime) && o["size"].as_i64() == Some(*size)) {
            continue;
        }
        let Ok(bytes) = std::fs::read(wiki.join(path.trim_start_matches('/'))) else { continue };
        let raw = String::from_utf8_lossy(&bytes).to_string();
        let digest = format!("{:x}", Sha256::digest(raw.as_bytes()));
        if old.is_some_and(|o| o["hash"].as_str() == Some(digest.as_str())) {
            db::run(
                &app.db,
                "UPDATE type::record('wiki_page', $path) SET mtime = $mtime, size = $size;",
                vec![("path", json!(path)), ("mtime", json!(mtime)), ("size", json!(size))],
            )
            .await?;
            continue;
        }
        let (meta, body) = parse_page(&raw);
        let title = meta["title"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .or_else(|| meta["title"].as_number().map(|n| n.to_string()))
            .unwrap_or_else(|| Path::new(path).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default());
        let parts = sections(&title, body);
        let texts: Vec<String> = parts.iter().map(|(h, t)| models::wiki_text(&title, h, t)).collect();
        let vectors = if texts.is_empty() { vec![] } else { app.models.embed(&texts).await? };
        let chunks: Vec<Value> = parts
            .iter()
            .zip(vectors)
            .map(|((h, t), v)| json!({"heading": h, "text": t, "search_text": format!("{h} {t}"), "embedding": v}))
            .collect();
        db::run(
            &app.db,
            "BEGIN;
             DELETE type::record('wiki_page', $path);
             CREATE type::record('wiki_page', $path) CONTENT {
                 mtime: $mtime, size: $size, hash: $hash, title: $title, details: $details };
             FOR $c IN $chunks {
                 CREATE wiki_chunk CONTENT { page: type::record('wiki_page', $path), heading: $c.heading,
                     text: $c.text, search_text: $c.search_text, embedding: $c.embedding };
             };
             COMMIT;",
            vec![
                ("path", json!(path)),
                ("mtime", json!(mtime)),
                ("size", json!(size)),
                ("hash", json!(digest)),
                ("title", json!(title)),
                ("details", page_details(&meta)),
                ("chunks", json!(chunks)),
            ],
        )
        .await?;
        changed += 1;
    }
    *checked = Some(Instant::now());
    Ok(changed)
}

/// A wiki section as the plugin receives it.
pub fn section_json(app: &App, row: &Value, score: f64) -> Value {
    let details = &row["details"];
    let stale = as_datetime(&details["stale_after"]).is_some_and(|d| Utc::now() >= d);
    let text = row["text"].as_str().unwrap_or("");
    let excerpt = if text.chars().count() <= 700 {
        text.to_string()
    } else {
        let (head, _) = take_chars(text, 700);
        format!("{} …", head.rsplit_once(' ').map(|(a, _)| a).unwrap_or(head))
    };
    let link = row["path"].as_str().unwrap_or("");
    json!({
        "source": "wiki",
        "path": format!("{}{link}", root(&app.wiki).display()),
        "link": link,
        "title": row["title"],
        "section": row["heading"],
        "excerpt": excerpt,
        "status": details["status"],
        "trust": details["trust"],
        "stale": stale,
        "generated_by": details["generated_by"],
        "score": (score * 10000.0).round() / 10000.0,
    })
}

fn cosine(a: &[f32], b: &[f32]) -> f64 {
    let (mut dot, mut na, mut nb) = (0f64, 0f64, 0f64);
    for (x, y) in a.iter().zip(b) {
        dot += (*x as f64) * (*y as f64);
        na += (*x as f64).powi(2);
        nb += (*y as f64).powi(2);
    }
    if na == 0.0 || nb == 0.0 { 0.0 } else { dot / (na.sqrt() * nb.sqrt()) }
}

fn vector(v: &Value) -> Vec<f32> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect()).unwrap_or_default()
}

/// Pages closest in meaning to one page: each other page scored by its closest section to the page's average.
pub async fn related(app: &App, body: &Value) -> Result<Value> {
    let wiki = root(&app.wiki);
    let given = body["path"].as_str().unwrap_or("");
    let link = format!("/{}", given.strip_prefix(&*wiki.to_string_lossy()).unwrap_or(given).trim_start_matches('/'));
    let limit = body["limit"].as_i64().unwrap_or(8).clamp(1, 20) as usize;
    sync(app, false).await?;
    let chunks = db::rows(&app.db, "SELECT record::id(page) AS path, embedding FROM wiki_chunk", vec![]).await?;
    let own: Vec<Vec<f32>> = chunks.iter().filter(|c| c["path"] == json!(link)).map(|c| vector(&c["embedding"])).collect();
    if own.is_empty() {
        return Ok(json!({"error": format!("{link} isn't in the index. Check the path, or that the page has text.")}));
    }
    let mut centre = vec![0f32; own[0].len()];
    for v in &own {
        for (c, x) in centre.iter_mut().zip(v) {
            *c += x / own.len() as f32;
        }
    }
    let mut best: std::collections::HashMap<String, f64> = std::collections::HashMap::new();
    for c in chunks.iter().filter(|c| c["path"] != json!(link)) {
        let score = cosine(&centre, &vector(&c["embedding"]));
        let entry = best.entry(c["path"].as_str().unwrap_or("").to_string()).or_insert(f64::MIN);
        *entry = entry.max(score);
    }
    let mut ranked: Vec<(String, f64)> = best.into_iter().collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1));
    ranked.truncate(limit);
    let pages = db::rows(
        &app.db,
        "SELECT record::id(id) AS path, title, details FROM wiki_page WHERE record::id(id) IN $paths",
        vec![("paths", json!(ranked.iter().map(|(p, _)| p).collect::<Vec<_>>()))],
    )
    .await?;
    let related: Vec<Value> = ranked
        .iter()
        .filter_map(|(path, score)| {
            let p = pages.iter().find(|p| p["path"] == json!(path))?;
            Some(json!({
                "path": format!("{}{path}", wiki.display()),
                "link": path,
                "title": p["title"],
                "score": (score * 10000.0).round() / 10000.0,
                "status": p["details"]["status"],
                "trust": p["details"]["trust"],
            }))
        })
        .collect();
    Ok(json!({"page": link, "related": related}))
}
