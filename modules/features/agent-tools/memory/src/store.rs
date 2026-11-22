//! The truth: every point (item, topic, exchange) and every change to an item, in one SQLite file. Qdrant only indexes
//! what is here, so it can always be rebuilt from it.

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use serde::Serialize;
use serde_json::{Value, json};

pub const KINDS: &[&str] = &["fact", "preference", "procedure", "idea", "plan", "decision", "commitment"];
pub const STATUSES: &[&str] = &["open", "parked", "in_progress", "done", "dropped"];

/// Ideas, plans and commitments move through statuses; the other kinds just hold.
pub fn has_status(kind: &str) -> bool {
    matches!(kind, "idea" | "plan" | "commitment")
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL CHECK (type IN ('exchange', 'topic', 'item')),
    kind TEXT,
    status TEXT,
    core INTEGER NOT NULL DEFAULT 0,
    retracted INTEGER NOT NULL DEFAULT 0,
    content TEXT NOT NULL,
    room TEXT,
    source_event TEXT,
    links TEXT NOT NULL DEFAULT '[]',
    created TEXT NOT NULL,
    updated TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 0, -- bumped on every change, so indexing an old version doesn't count
    indexed TEXT -- the embedding model it is indexed with; NULL: (re)index it
);
CREATE UNIQUE INDEX IF NOT EXISTS exchange_source ON points (source_event) WHERE type = 'exchange';
CREATE INDEX IF NOT EXISTS points_room ON points (type, room, id);
CREATE TABLE IF NOT EXISTS changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item INTEGER NOT NULL REFERENCES points (id),
    action TEXT NOT NULL CHECK (action IN ('create', 'update', 'retract', 'restore')),
    before TEXT,
    after TEXT NOT NULL,
    origin TEXT NOT NULL,
    at TEXT NOT NULL,
    undoes INTEGER REFERENCES changes (id),
    undone_by INTEGER REFERENCES changes (id),
    notice TEXT -- the Matrix event that announced it; NULL: not announced yet
);
CREATE UNIQUE INDEX IF NOT EXISTS changes_notice ON changes (notice);
CREATE TABLE IF NOT EXISTS consolidated (room TEXT PRIMARY KEY, upto INTEGER NOT NULL);
";

#[derive(Clone, Debug, Serialize)]
pub struct Point {
    pub id: i64,
    #[serde(rename = "type")]
    pub kind_of: String,
    pub kind: Option<String>,
    pub status: Option<String>,
    pub core: bool,
    pub retracted: bool,
    pub content: String,
    pub room: Option<String>,
    pub links: Vec<i64>,
    pub created: String,
    pub updated: String,
    #[serde(skip)]
    pub version: i64,
}

impl Point {
    pub fn created_at(&self) -> i64 {
        DateTime::parse_from_rfc3339(&self.created).map(|t| t.timestamp()).unwrap_or(0)
    }
    pub fn date(&self) -> String {
        self.created.get(..10).unwrap_or_default().to_string()
    }
    /// The fields a change records before and after.
    fn snapshot(&self) -> Value {
        json!({ "kind": self.kind, "status": self.status, "core": self.core, "content": self.content,
                "links": self.links, "retracted": self.retracted })
    }
}

const POINT_FIELDS: &str = "id, type, kind, status, core, retracted, content, room, links, created, updated, version";

fn row_point(r: &Row) -> rusqlite::Result<Point> {
    let links: String = r.get(8)?;
    Ok(Point {
        id: r.get(0)?,
        kind_of: r.get(1)?,
        kind: r.get(2)?,
        status: r.get(3)?,
        core: r.get(4)?,
        retracted: r.get(5)?,
        content: r.get(6)?,
        room: r.get(7)?,
        links: serde_json::from_str(&links).unwrap_or_default(),
        created: r.get(9)?,
        updated: r.get(10)?,
        version: r.get(11)?,
    })
}

/// A change to an item, as the agent announces it.
#[derive(Clone, Debug, Serialize)]
pub struct Change {
    pub change: i64,
    pub item: i64,
    pub action: String,
    pub origin: String,
    pub before: Option<Value>,
    pub after: Value,
    pub undoes: Option<i64>,
    /// The notice of the change this one undoes, so the agent can answer in its thread.
    pub thread_of: Option<String>,
    pub notice_text: String,
}

/// What an item should become; `None` leaves a field as it is.
#[derive(Default, Debug, Clone)]
pub struct Patch {
    pub kind: Option<String>,
    pub status: Option<String>,
    pub core: Option<bool>,
    pub content: Option<String>,
    pub links: Option<Vec<i64>>,
}

pub fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn status_word(status: &str) -> String {
    status.replace('_', " ")
}

/// The line the Memory room shows for a change.
pub fn notice_text(action: &str, item: i64, before: Option<&Value>, after: &Value, undo: bool) -> String {
    let kind = after["kind"].as_str().unwrap_or("item");
    let content = after["content"].as_str().unwrap_or("");
    let status = after["status"].as_str().map(|s| format!(" ({})", status_word(s))).unwrap_or_default();
    let core = if after["core"] == json!(true) { " ⭐" } else { "" };
    let prefix = if undo { "↩ Undone. " } else { "" };
    match action {
        "create" => format!("{prefix}🧠 New {kind} #{item}{status}{core}: {content}"),
        "retract" => format!("{prefix}🗑 Retracted {kind} #{item}: {content}"),
        "restore" => format!("{prefix}♻ Restored {kind} #{item}{status}{core}: {content}"),
        _ => {
            let before = before.cloned().unwrap_or(Value::Null);
            let mut what = Vec::new();
            if before["status"] != after["status"] {
                let from = before["status"].as_str().map(status_word).unwrap_or("none".into());
                let to = after["status"].as_str().map(status_word).unwrap_or("none".into());
                what.push(format!("{from} → {to}"));
            }
            if before["kind"] != after["kind"] {
                what.push(format!("now a {kind}"));
            }
            if before["core"] != after["core"] {
                what.push(if after["core"] == json!(true) { "now core ⭐".into() } else { "no longer core".into() });
            }
            if before["links"] != after["links"] {
                let links: Vec<String> =
                    after["links"].as_array().into_iter().flatten().map(|l| format!("#{l}")).collect();
                what.push(format!("linked to {}", if links.is_empty() { "nothing".into() } else { links.join(", ") }));
            }
            let what = if what.is_empty() { String::new() } else { format!(" ({})", what.join("; ")) };
            format!("{prefix}🧠 Updated {kind} #{item}{what}: {content}")
        }
    }
}

pub struct Store {
    db: Connection,
}

impl Store {
    pub fn open(path: &str) -> Result<Self> {
        let db = Connection::open(path).with_context(|| format!("opening {path}"))?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        db.pragma_update(None, "foreign_keys", "ON")?;
        db.execute_batch(SCHEMA)?;
        Ok(Store { db })
    }

    pub fn get(&self, id: i64) -> Result<Option<Point>> {
        Ok(self.db.query_row(&format!("SELECT {POINT_FIELDS} FROM points WHERE id = ?1"), [id], row_point).optional()?)
    }

    /// The points with these ids that still exist and aren't retracted, in the order asked.
    pub fn get_many(&self, ids: &[i64]) -> Result<Vec<Point>> {
        let mut out = Vec::new();
        for id in ids {
            if let Some(p) = self.get(*id)?.filter(|p| !p.retracted) {
                out.push(p);
            }
        }
        Ok(out)
    }

    pub fn items(&self, kind: Option<&str>, status: Option<&str>, core: Option<bool>, limit: i64) -> Result<Vec<Point>> {
        let mut stmt = self.db.prepare(&format!(
            "SELECT {POINT_FIELDS} FROM points WHERE type = 'item' AND retracted = 0
               AND (?1 IS NULL OR kind = ?1) AND (?2 IS NULL OR status = ?2) AND (?3 IS NULL OR core = ?3)
             ORDER BY updated DESC LIMIT ?4"
        ))?;
        let rows = stmt.query_map(params![kind, status, core, limit], row_point)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn history(&self, item: i64) -> Result<Vec<Value>> {
        let mut stmt = self.db.prepare(
            "SELECT id, action, origin, at, before, after, undone_by FROM changes WHERE item = ?1 ORDER BY id",
        )?;
        let rows = stmt.query_map([item], |r| {
            let before: Option<String> = r.get(4)?;
            let after: String = r.get(5)?;
            Ok(json!({
                "change": r.get::<_, i64>(0)?, "action": r.get::<_, String>(1)?, "origin": r.get::<_, String>(2)?,
                "at": r.get::<_, String>(3)?,
                "before": before.and_then(|b| serde_json::from_str::<Value>(&b).ok())
                    .map(|b| json!({"status": b["status"], "content": b["content"]})),
                "after": serde_json::from_str::<Value>(&after).ok().map(|a| json!({"status": a["status"], "content": a["content"]})),
                "undone": r.get::<_, Option<i64>>(6)?.is_some(),
            }))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    // ---- exchanges, topics and consolidation

    /// Stores one exchange; the same Matrix event again returns the first one's id.
    pub fn add_exchange(&mut self, room: &str, event: &str, content: &str, at: Option<&str>) -> Result<(i64, bool)> {
        let existing: Option<i64> = self
            .db
            .query_row("SELECT id FROM points WHERE type = 'exchange' AND source_event = ?1", [event], |r| r.get(0))
            .optional()?;
        if let Some(id) = existing {
            return Ok((id, false));
        }
        let at = at.map(str::to_string).unwrap_or_else(now);
        self.db.execute(
            "INSERT INTO points (type, content, room, source_event, created, updated) VALUES ('exchange', ?1, ?2, ?3, ?4, ?4)",
            params![content, room, event, at],
        )?;
        Ok((self.db.last_insert_rowid(), true))
    }

    /// A room's exchanges after the last consolidated one, oldest first.
    pub fn unconsolidated(&self, room: &str, limit: i64) -> Result<Vec<Point>> {
        let mut stmt = self.db.prepare(&format!(
            "SELECT {POINT_FIELDS} FROM points WHERE type = 'exchange' AND room = ?1
               AND id > COALESCE((SELECT upto FROM consolidated WHERE room = ?1), 0)
             ORDER BY id LIMIT ?2"
        ))?;
        let rows = stmt.query_map(params![room, limit], row_point)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn transaction(&mut self) -> Result<Transaction<'_>> {
        Ok(self.db.transaction()?)
    }

    // ---- items

    fn record(
        tx: &Transaction,
        item: i64,
        action: &str,
        before: Option<&Value>,
        after: &Value,
        origin: &str,
        undoes: Option<i64>,
    ) -> Result<i64> {
        tx.execute(
            "INSERT INTO changes (item, action, before, after, origin, at, undoes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![item, action, before.map(|b| b.to_string()), after.to_string(), origin, now(), undoes],
        )?;
        let id = tx.last_insert_rowid();
        if let Some(undone) = undoes {
            tx.execute("UPDATE changes SET undone_by = ?1 WHERE id = ?2", params![id, undone])?;
        }
        Ok(id)
    }

    fn get_in(tx: &Transaction, id: i64) -> Result<Option<Point>> {
        Ok(tx.query_row(&format!("SELECT {POINT_FIELDS} FROM points WHERE id = ?1"), [id], row_point).optional()?)
    }

    pub fn insert_topic(tx: &Transaction, room: &str, summary: &str, exchanges: &[i64]) -> Result<i64> {
        let at = now();
        tx.execute(
            "INSERT INTO points (type, content, room, links, created, updated) VALUES ('topic', ?1, ?2, ?3, ?4, ?4)",
            params![summary, room, serde_json::to_string(exchanges)?, at],
        )?;
        Ok(tx.last_insert_rowid())
    }

    pub fn mark_consolidated(tx: &Transaction, room: &str, upto: i64) -> Result<()> {
        tx.execute(
            "INSERT INTO consolidated (room, upto) VALUES (?1, ?2) ON CONFLICT (room) DO UPDATE SET upto = excluded.upto",
            params![room, upto],
        )?;
        Ok(())
    }

    fn check(kind: &str, status: Option<&str>) -> Result<Option<String>> {
        if !KINDS.contains(&kind) {
            bail!("kind must be one of {}", KINDS.join(", "));
        }
        match status {
            _ if !has_status(kind) => Ok(None),
            None => Ok(Some("open".into())),
            Some(s) if STATUSES.contains(&s) => Ok(Some(s.into())),
            Some(s) => bail!("status {s:?} must be one of {}", STATUSES.join(", ")),
        }
    }

    /// A new item, in the caller's transaction. Returns the change id.
    #[allow(clippy::too_many_arguments)]
    pub fn create_item(
        tx: &Transaction,
        kind: &str,
        content: &str,
        status: Option<&str>,
        core: bool,
        links: &[i64],
        room: Option<&str>,
        origin: &str,
    ) -> Result<i64> {
        let content = content.trim();
        if content.is_empty() {
            bail!("an item needs content");
        }
        let status = Self::check(kind, status)?;
        let at = now();
        tx.execute(
            "INSERT INTO points (type, kind, status, core, content, room, links, created, updated)
             VALUES ('item', ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
            params![kind, status, core, content, room, serde_json::to_string(links)?, at],
        )?;
        let id = tx.last_insert_rowid();
        let after = Self::get_in(tx, id)?.context("vanished")?.snapshot();
        Self::record(tx, id, "create", None, &after, origin, None)
    }

    /// Changes an item. Returns the change id, or None when nothing changed.
    pub fn update_item(tx: &Transaction, id: i64, patch: &Patch, origin: &str, undoes: Option<i64>) -> Result<Option<i64>> {
        let point = Self::get_in(tx, id)?.filter(|p| p.kind_of == "item").with_context(|| format!("there is no item #{id}"))?;
        if point.retracted && undoes.is_none() {
            bail!("item #{id} is retracted");
        }
        let kind = patch.kind.clone().or(point.kind.clone()).unwrap_or_else(|| "fact".into());
        let wanted_status = patch.status.as_deref().or(point.status.as_deref()).filter(|s| *s != "none");
        let status = Self::check(&kind, wanted_status)?;
        let content = patch.content.as_deref().map(str::trim).filter(|c| !c.is_empty()).unwrap_or(&point.content).to_string();
        let core = patch.core.unwrap_or(point.core);
        let links = patch.links.clone().unwrap_or(point.links.clone());
        let before = point.snapshot();
        tx.execute(
            "UPDATE points SET kind = ?1, status = ?2, core = ?3, content = ?4, links = ?5, updated = ?6, indexed = NULL, version = version + 1
             WHERE id = ?7",
            params![kind, status, core, content, serde_json::to_string(&links)?, now(), id],
        )?;
        let after = Self::get_in(tx, id)?.context("vanished")?.snapshot();
        if after == before {
            return Ok(None);
        }
        Ok(Some(Self::record(tx, id, "update", Some(&before), &after, origin, undoes)?))
    }

    pub fn set_retracted(tx: &Transaction, id: i64, retracted: bool, origin: &str, undoes: Option<i64>) -> Result<i64> {
        let point = Self::get_in(tx, id)?.filter(|p| p.kind_of == "item").with_context(|| format!("there is no item #{id}"))?;
        if point.retracted == retracted {
            bail!("item #{id} is already {}", if retracted { "retracted" } else { "current" });
        }
        let before = point.snapshot();
        tx.execute(
            "UPDATE points SET retracted = ?1, updated = ?2, indexed = NULL, version = version + 1 WHERE id = ?3",
            params![retracted, now(), id],
        )?;
        let after = Self::get_in(tx, id)?.context("vanished")?.snapshot();
        Self::record(tx, id, if retracted { "retract" } else { "restore" }, Some(&before), &after, origin, undoes)
    }

    /// Undoes one change, in a new change of its own.
    pub fn undo(&mut self, change: i64) -> Result<i64> {
        let tx = self.db.transaction()?;
        let (item, action, before, undone_by): (i64, String, Option<String>, Option<i64>) = tx
            .query_row("SELECT item, action, before, undone_by FROM changes WHERE id = ?1", [change], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .optional()?
            .with_context(|| format!("there is no change {change}"))?;
        if undone_by.is_some() {
            bail!("that change was already undone");
        }
        let id = match action.as_str() {
            "create" => Self::set_retracted(&tx, item, true, "undo", Some(change))?,
            "retract" => Self::set_retracted(&tx, item, false, "undo", Some(change))?,
            "restore" => Self::set_retracted(&tx, item, true, "undo", Some(change))?,
            _ => {
                let b: Value = serde_json::from_str(&before.unwrap_or_default()).context("no before state")?;
                let patch = Patch {
                    kind: b["kind"].as_str().map(Into::into),
                    status: Some(b["status"].as_str().unwrap_or("none").into()),
                    core: b["core"].as_bool(),
                    content: b["content"].as_str().map(Into::into),
                    links: serde_json::from_value(b["links"].clone()).ok(),
                };
                Self::update_item(&tx, item, &patch, "undo", Some(change))?.context("nothing to undo: it is already as it was")?
            }
        };
        tx.commit()?;
        Ok(id)
    }

    /// Items created or changed since a time, such as those saved during a session being consolidated.
    pub fn items_changed_since(&self, since: &str, limit: i64) -> Result<Vec<i64>> {
        let mut stmt = self.db.prepare(
            "SELECT DISTINCT c.item FROM changes c JOIN points p ON p.id = c.item
             WHERE c.at >= ?1 AND p.retracted = 0 ORDER BY c.item LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![since, limit], |r| r.get(0))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    // ---- announcements

    fn change_row(&self, r: &Row) -> rusqlite::Result<Change> {
        let before: Option<String> = r.get(4)?;
        let after: String = r.get(5)?;
        let before: Option<Value> = before.and_then(|b| serde_json::from_str(&b).ok());
        let after: Value = serde_json::from_str(&after).unwrap_or(Value::Null);
        let action: String = r.get(2)?;
        let undoes: Option<i64> = r.get(6)?;
        let item: i64 = r.get(1)?;
        Ok(Change {
            change: r.get(0)?,
            item,
            notice_text: notice_text(&action, item, before.as_ref(), &after, undoes.is_some()),
            action,
            origin: r.get(3)?,
            before,
            after,
            undoes,
            thread_of: r.get(7)?,
        })
    }

    const CHANGE_FIELDS: &str = "c.id, c.item, c.action, c.origin, c.before, c.after, c.undoes,
        (SELECT notice FROM changes u WHERE u.id = c.undoes)";

    pub fn unannounced(&self) -> Result<Vec<Change>> {
        let mut stmt = self
            .db
            .prepare(&format!("SELECT {} FROM changes c WHERE c.notice IS NULL ORDER BY c.id LIMIT 50", Self::CHANGE_FIELDS))?;
        let rows = stmt.query_map([], |r| self.change_row(r))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn announced(&self, change: i64, event: &str) -> Result<()> {
        self.db.execute("UPDATE changes SET notice = ?1 WHERE id = ?2", params![event, change])?;
        Ok(())
    }

    pub fn change_by_notice(&self, event: &str) -> Result<Option<Change>> {
        Ok(self
            .db
            .query_row(&format!("SELECT {} FROM changes c WHERE c.notice = ?1", Self::CHANGE_FIELDS), [event], |r| {
                self.change_row(r)
            })
            .optional()?)
    }

    pub fn change(&self, id: i64) -> Result<Option<Change>> {
        Ok(self
            .db
            .query_row(&format!("SELECT {} FROM changes c WHERE c.id = ?1", Self::CHANGE_FIELDS), [id], |r| self.change_row(r))
            .optional()?)
    }

    // ---- indexing

    /// Points to (re)index with `model`: new, changed, retracted (to delete), or indexed with another model.
    pub fn needs_index(&self, model: &str, limit: i64) -> Result<Vec<Point>> {
        let mut stmt = self.db.prepare(&format!(
            "SELECT {POINT_FIELDS} FROM points WHERE indexed IS NULL OR indexed != ?1 ORDER BY id LIMIT ?2"
        ))?;
        let rows = stmt.query_map(params![model, limit], row_point)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Marks these (id, version) pairs indexed; a point changed since keeps waiting.
    pub fn mark_indexed(&mut self, points: &[(i64, i64)], model: &str) -> Result<()> {
        let tx = self.db.transaction()?;
        for (id, version) in points {
            tx.execute("UPDATE points SET indexed = ?1 WHERE id = ?2 AND version = ?3", params![model, id, version])?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn mark_all_unindexed(&self) -> Result<()> {
        self.db.execute("UPDATE points SET indexed = NULL", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Store {
        Store::open(":memory:").unwrap()
    }

    #[test]
    fn create_update_undo() {
        let mut s = store();
        let tx = s.transaction().unwrap();
        let c1 = Store::create_item(&tx, "idea", "Separate ducts per P100.", None, false, &[], None, "test").unwrap();
        tx.commit().unwrap();
        let item = s.unannounced().unwrap()[0].item;
        assert_eq!(s.get(item).unwrap().unwrap().status.as_deref(), Some("open"));

        let tx = s.transaction().unwrap();
        let patch = Patch { status: Some("in_progress".into()), ..Default::default() };
        let c2 = Store::update_item(&tx, item, &patch, "test", None).unwrap().unwrap();
        tx.commit().unwrap();
        let changes = s.unannounced().unwrap();
        assert_eq!(changes.len(), 2);
        assert!(changes[1].notice_text.contains("open → in progress"), "{}", changes[1].notice_text);

        s.announced(c2, "$notice2").unwrap();
        let undo = s.undo(c2).unwrap();
        assert_eq!(s.get(item).unwrap().unwrap().status.as_deref(), Some("open"));
        let u = s.change(undo).unwrap().unwrap();
        assert_eq!(u.thread_of.as_deref(), Some("$notice2"));
        assert!(u.notice_text.starts_with("↩ Undone."));
        assert!(s.undo(c2).is_err(), "undone twice");

        s.undo(c1).unwrap();
        assert!(s.get(item).unwrap().unwrap().retracted);
        assert!(s.get_many(&[item]).unwrap().is_empty());
    }

    #[test]
    fn statuses_only_where_they_belong() {
        let mut s = store();
        let tx = s.transaction().unwrap();
        Store::create_item(&tx, "fact", "nabu has two P100s.", Some("open"), false, &[], None, "t").unwrap();
        assert!(Store::create_item(&tx, "idea", "x", Some("someday"), false, &[], None, "t").is_err());
        assert!(Store::create_item(&tx, "feeling", "x", None, false, &[], None, "t").is_err());
        tx.commit().unwrap();
        assert_eq!(s.items(Some("fact"), None, None, 10).unwrap()[0].status, None);
    }

    #[test]
    fn exchanges_and_consolidation_ranges() {
        let mut s = store();
        let (a, new) = s.add_exchange("!r", "$e1", "Owner: hi", None).unwrap();
        assert!(new);
        assert_eq!(s.add_exchange("!r", "$e1", "Owner: hi", None).unwrap(), (a, false));
        let (b, _) = s.add_exchange("!r", "$e2", "Owner: more", None).unwrap();
        s.add_exchange("!other", "$e3", "Owner: elsewhere", None).unwrap();
        assert_eq!(s.unconsolidated("!r", 10).unwrap().len(), 2);
        let tx = s.transaction().unwrap();
        Store::mark_consolidated(&tx, "!r", b).unwrap();
        tx.commit().unwrap();
        assert!(s.unconsolidated("!r", 10).unwrap().is_empty());
        assert_eq!(s.needs_index("m", 10).unwrap().len(), 3);
        s.mark_indexed(&[(a, 0), (b, 0)], "m").unwrap();
        assert_eq!(s.needs_index("m", 10).unwrap().len(), 1);
        assert_eq!(s.needs_index("other-model", 10).unwrap().len(), 3);
    }
}
