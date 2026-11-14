"""Hermes' memory service: durable memories and the wiki index, in Postgres, behind a Unix socket.

The Hermes plugin is its only client. Each request carries who is asking: the platform, and whether
the caller may see memories at all, which the plugin decides. Recall combines meaning (pgvector) and
keyword (full-text) search over memories and wiki sections, and the local reranker orders the result.

Routes (POST, JSON in and out):
  /recall    memories and wiki sections for a query
  /remember  store a memory, or report the near-identical one that already exists
  /revise    replace, retract, confirm, complete, cancel or forget a memory
  /list      browse memories, such as open commitments
  /wiki/search, /wiki/related   wiki-only search, for the llm-wiki skill
  /export    rewrite the Obsidian export now
  /observe   queue a finished chat turn, for the helper model to pick out anything worth remembering
GET /health
"""

import argparse
import hashlib
import json
import logging
import os
import re
import socketserver
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler

import psycopg
import yaml
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

log = logging.getLogger("hermes-memory")

KINDS = ("fact", "preference", "procedure", "event", "commitment")
# Commitments need a due date or condition, which main sets with its tools, so capture leaves them out.
CAPTURE_KINDS = ("fact", "preference", "procedure", "event")
# Inferred memories rank below what the owner stated or confirmed.
INFERRED_CONFIDENCE = 0.7
CAPTURE_CONTEXT = 8
CAPTURE_MAX_MEMORIES = 5
CAPTURE_ATTEMPTS = 3
# Long turns are cut so a prompt leaves the helper's context room for Hermes' own tasks.
CAPTURE_USER_CHARS = 6000
CAPTURE_REPLY_CHARS = 3000
# A new memory this close to an existing one is the same memory said again.
DUPLICATE_SIMILARITY = 0.93
SIMILAR_SIMILARITY = 0.80
CANDIDATES = 30
# Reranker scores below these were unrelated in testing. The reranker ranks one-sentence memories
# correctly but scores them far lower than wiki sections, so memories get a lower floor, and a memory
# whose embedding is this close to the query is kept even when the reranker underrates it.
MIN_SCORE = 0.02
MIN_MEMORY_SCORE = 0.01
MIN_MEMORY_SIMILARITY = 0.70
# Wiki sections longer than this are split at paragraphs, so a query and one section fit the reranker's batch.
MAX_CHARS = 3000
RESERVED = {"index.md", "log.md"}

MIGRATIONS = [
    """
    create table memories (
        id bigserial primary key,
        kind text not null check (kind in ('fact', 'preference', 'procedure', 'event', 'commitment')),
        content text not null,
        embedding vector(768) not null,
        tsv tsvector generated always as (to_tsvector('english', content)) stored,
        origin text not null default 'stated' check (origin in ('stated', 'inferred', 'imported')),
        confidence real not null default 1.0 check (confidence between 0 and 1),
        importance smallint not null default 3 check (importance between 1 and 5),
        privacy text not null default 'normal' check (privacy in ('normal', 'local_only')),
        platforms text[] not null default '{}',
        valid_from timestamptz not null default now(),
        valid_until timestamptz,
        superseded_by bigint references memories (id) on delete set null,
        retracted boolean not null default false,
        confirmed_at timestamptz,
        created_at timestamptz not null default now(),
        updated_at timestamptz not null default now(),
        last_recalled_at timestamptz,
        recall_count integer not null default 0
    );
    create index memories_embedding on memories using hnsw (embedding vector_cosine_ops);
    create index memories_tsv on memories using gin (tsv);
    create index memories_current on memories (kind) where valid_until is null;

    create table sources (
        id bigserial primary key,
        memory_id bigint not null references memories (id) on delete cascade,
        platform text,
        session_id text,
        said_at timestamptz not null default now()
    );
    create index sources_memory on sources (memory_id);

    create table commitments (
        memory_id bigint primary key references memories (id) on delete cascade,
        due_at timestamptz,
        condition text,
        status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
        resolved_at timestamptz
    );

    -- No foreign key, so the record of a change outlives the memory. Forgetting blanks its content.
    create table history (
        id bigserial primary key,
        memory_id bigint not null,
        action text not null,
        before jsonb,
        after jsonb,
        actor text not null,
        reason text,
        at timestamptz not null default now()
    );
    create index history_memory on history (memory_id);

    create table wiki_pages (
        path text primary key,
        mtime double precision not null,
        size bigint not null,
        hash text not null,
        title text not null,
        info jsonb not null
    );
    create table wiki_chunks (
        id bigserial primary key,
        path text not null references wiki_pages (path) on delete cascade,
        heading text not null,
        text text not null,
        embedding vector(768) not null,
        tsv tsvector generated always as (to_tsvector('english', heading || ' ' || text)) stored
    );
    create index wiki_chunks_embedding on wiki_chunks using hnsw (embedding vector_cosine_ops);
    create index wiki_chunks_tsv on wiki_chunks using gin (tsv);
    create index wiki_chunks_path on wiki_chunks (path);
    """,
    """
    -- Finished turns waiting for capture. Each is deleted once processed, so no transcript is kept.
    create table observations (
        id bigserial primary key,
        platform text not null,
        remote boolean not null,
        session_id text,
        user_message text not null,
        assistant_response text not null,
        received_at timestamptz not null default now(),
        attempts smallint not null default 0
    );
    """,
]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--database", required=True, help="libpq connection string")
    parser.add_argument("--llama-swap-url", required=True)
    parser.add_argument("--wiki", required=True)
    parser.add_argument("--export-dir", required=True, help="inside the wiki; never indexed")
    parser.add_argument("--embedding-model", default="embedding")
    parser.add_argument("--reranker-model", default="reranker")
    parser.add_argument("--capture-model", default="helper")
    return parser.parse_args()


ARGS = None


# ── Models ────────────────────────────────────────────────────────────────────────────────


def post_json(url, body, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def embed(texts):
    vectors = []
    for start in range(0, len(texts), 16):
        out = post_json(ARGS.llama_swap_url + "/v1/embeddings",
                        {"model": ARGS.embedding_model, "input": texts[start : start + 16]})
        vectors += [d["embedding"] for d in sorted(out["data"], key=lambda d: d["index"])]
    return ["[" + ",".join(f"{x:.7g}" for x in v) + "]" for v in vectors]


def rerank(query, documents):
    if not documents:
        return []
    out = post_json(ARGS.llama_swap_url + "/v1/rerank",
                    {"model": ARGS.reranker_model, "query": query, "documents": documents}, timeout=60)
    scores = [0.0] * len(documents)
    for result in out["results"]:
        scores[result["index"]] = result["relevance_score"]
    return scores


# EmbeddingGemma's own prompts for retrieval.
def query_text(query):
    return f"task: search result | query: {query}"


def memory_text(kind, content):
    return f"title: {kind} | text: {content}"


def wiki_text(title, heading, text):
    label = f"{title} - {heading}" if heading and heading != title else title
    return f"title: {label or 'none'} | text: {text}"


def ts_query(text):
    """Any of the query's words, quoted so punctuation can't break the syntax."""
    words = [w for w in re.findall(r"\w+", text.lower()) if len(w) > 1]
    return " | ".join(f"'{w}'" for w in words[:32]) or None


# ── Database ──────────────────────────────────────────────────────────────────────────────


def connect():
    return psycopg.connect(ARGS.database, row_factory=dict_row, autocommit=False)


def migrate():
    with connect() as db:
        db.execute("select pg_advisory_xact_lock(4111)")
        db.execute("create table if not exists schema_version (version integer not null)")
        row = db.execute("select max(version) as v from schema_version").fetchone()
        current = row["v"] or 0
        for version, sql in enumerate(MIGRATIONS, start=1):
            if version > current:
                db.execute(sql)
                db.execute("insert into schema_version values (%s)", (version,))
                log.info("applied schema version %d", version)


def memory_row(row, score=None):
    out = {
        "source": "memory",
        "id": row["id"],
        "kind": row["kind"],
        "content": row["content"],
        "origin": row["origin"],
        "confirmed": row["confirmed_at"] is not None,
        "importance": row["importance"],
        "privacy": row["privacy"],
        "platforms": row["platforms"] or ["all"],
        "since": row["valid_from"].date().isoformat(),
    }
    if row["valid_until"] is not None:
        out["until"] = row["valid_until"].date().isoformat()
        out["current"] = False
        if row.get("superseded_by"):
            out["replaced_by"] = row["superseded_by"]
    if row.get("status"):
        out["commitment"] = {
            "status": row["status"],
            "due": row["due_at"].isoformat() if row.get("due_at") else None,
            "condition": row.get("condition"),
        }
    if score is not None:
        out["score"] = round(float(score), 4)
    return out


MEMORY_COLUMNS = """
    m.id, m.kind, m.content, m.origin, m.confirmed_at, m.importance, m.privacy, m.platforms,
    m.valid_from, m.valid_until, m.superseded_by, c.status, c.due_at, c.condition
"""


def visibility(caller, include_past):
    """SQL and parameters that hide what this caller may not see."""
    return (
        """not m.retracted
           and (m.valid_until is null or %(past)s)
           and (m.privacy = 'normal' or not %(remote)s)
           and (cardinality(m.platforms) = 0 or %(platform)s = any (m.platforms))""",
        {"past": bool(include_past), "remote": caller["remote"], "platform": caller["platform"]},
    )


def record(db, memory_id, action, actor, before=None, after=None, reason=None):
    db.execute(
        "insert into history (memory_id, action, before, after, actor, reason) values (%s, %s, %s, %s, %s, %s)",
        (memory_id, action, Jsonb(before) if before else None, Jsonb(after) if after else None, actor, reason),
    )


def snapshot(db, memory_id):
    row = db.execute(
        "select kind, content, privacy, platforms, importance, valid_until, retracted from memories where id = %s",
        (memory_id,),
    ).fetchone()
    if row and row["valid_until"]:
        row["valid_until"] = row["valid_until"].isoformat()
    return row


# ── Wiki index ────────────────────────────────────────────────────────────────────────────

_wiki_checked = 0.0
_wiki_lock = threading.Lock()


def wiki_files():
    wiki = os.path.realpath(ARGS.wiki)
    export = os.path.realpath(ARGS.export_dir)
    for root, dirs, files in os.walk(wiki):
        # Skips .obsidian, .trash and the memory export.
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and os.path.join(root, d) != export)
        for name in sorted(files):
            # OKF reserves index.md and log.md at every level.
            if name.endswith(".md") and name not in RESERVED:
                yield "/" + os.path.relpath(os.path.join(root, name), wiki)


def parse_page(raw):
    meta, body = {}, raw
    match = re.match(r"\A---\s*\n(.*?)\n---\s*\n?", raw, re.S)
    if match:
        try:
            loaded = yaml.safe_load(match.group(1))
            meta = loaded if isinstance(loaded, dict) else {}
        except yaml.YAMLError:
            meta = {}
        body = raw[match.end() :]
    return meta, body


def sections(title, body):
    """(heading, text) pairs: one per heading, with long sections split at paragraphs."""
    parts, heading, lines = [], title, []
    for line in body.splitlines():
        found = re.match(r"^#{1,6}\s+(.*)", line)
        if found:
            parts.append((heading, "\n".join(lines)))
            heading, lines = found.group(1).strip(), []
        else:
            lines.append(line)
    parts.append((heading, "\n".join(lines)))

    out = []
    for heading, text in parts:
        # Footnote definitions only repeat source titles.
        text = re.sub(r"(?m)^\[\^[^\]]+\]:.*$", "", text).strip()
        if not text:
            continue
        chunk = ""
        for para in re.split(r"\n\s*\n", text):
            if chunk and len(chunk) + len(para) > MAX_CHARS:
                out.append((heading, chunk))
                chunk = ""
            chunk = f"{chunk}\n\n{para}" if chunk else para
            while len(chunk) > MAX_CHARS:
                out.append((heading, chunk[:MAX_CHARS]))
                chunk = chunk[MAX_CHARS:]
        if chunk:
            out.append((heading, chunk))
    return out


def as_datetime(value):
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def page_info(meta):
    verified = meta.get("verified")
    if isinstance(verified, dict):
        verified = [verified]
    by = [str(v.get("by", "")) for v in verified or [] if isinstance(v, dict)]
    trust = "human-reviewed" if any(b.startswith("human:") for b in by) else (
        "machine-confirmed" if by else "unverified")
    generated = meta.get("generated") if isinstance(meta.get("generated"), dict) else {}
    stale_after = as_datetime(meta["stale_after"]) if meta.get("stale_after") else None
    return {
        "type": str(meta.get("type") or ""),
        "status": str(meta.get("status") or "stable"),
        "trust": trust,
        "stale_after": stale_after.isoformat() if stale_after else None,
        "generated_by": str(generated.get("by") or ""),
        "description": str(meta.get("description") or ""),
    }


def sync_wiki(force=False):
    """Re-index wiki pages that changed. Returns how many changed."""
    global _wiki_checked
    with _wiki_lock:
        if not force and time.time() - _wiki_checked < 5:
            return 0
        wiki = os.path.realpath(ARGS.wiki)
        on_disk = {}
        for path in wiki_files():
            try:
                st = os.stat(wiki + path)
            except OSError:
                continue
            on_disk[path] = (st.st_mtime, st.st_size)

        changed = 0
        with connect() as db:
            db.execute("select pg_advisory_xact_lock(4112)")
            known = {r["path"]: r for r in db.execute("select path, mtime, size, hash from wiki_pages")}
            for path in set(known) - set(on_disk):
                db.execute("delete from wiki_pages where path = %s", (path,))
                changed += 1
            for path, (mtime, size) in on_disk.items():
                old = known.get(path)
                if old and old["mtime"] == mtime and old["size"] == size:
                    continue
                try:
                    with open(wiki + path, encoding="utf-8", errors="replace") as f:
                        raw = f.read()
                except OSError:
                    continue
                digest = hashlib.sha256(raw.encode()).hexdigest()
                if old and old["hash"] == digest:
                    db.execute("update wiki_pages set mtime = %s, size = %s where path = %s", (mtime, size, path))
                    continue
                meta, body = parse_page(raw)
                title = str(meta.get("title") or os.path.splitext(os.path.basename(path))[0])
                parts = sections(title, body)
                vectors = embed([wiki_text(title, h, t) for h, t in parts]) if parts else []
                db.execute("delete from wiki_pages where path = %s", (path,))
                db.execute(
                    "insert into wiki_pages values (%s, %s, %s, %s, %s, %s)",
                    (path, mtime, size, digest, title, Jsonb(page_info(meta))),
                )
                for (heading, text), vec in zip(parts, vectors):
                    db.execute(
                        "insert into wiki_chunks (path, heading, text, embedding) values (%s, %s, %s, %s::vector)",
                        (path, heading, text, vec),
                    )
                changed += 1
        _wiki_checked = time.time()
        return changed


def wiki_result(row, score):
    info = row["info"]
    stale_after = as_datetime(info["stale_after"]) if info.get("stale_after") else None
    text = row["text"]
    excerpt = text if len(text) <= 700 else text[:700].rsplit(" ", 1)[0] + " …"
    return {
        "source": "wiki",
        "path": os.path.realpath(ARGS.wiki) + row["path"],
        "link": row["path"],
        "title": row["title"],
        "section": row["heading"],
        "excerpt": excerpt,
        "status": info.get("status"),
        "trust": info.get("trust"),
        "stale": bool(stale_after and datetime.now(timezone.utc) >= stale_after),
        "generated_by": info.get("generated_by"),
        "score": round(float(score), 4),
    }


# ── Recall ────────────────────────────────────────────────────────────────────────────────


def fuse(*ranked_lists):
    """Reciprocal rank fusion of several ranked id lists."""
    scores = {}
    for ids in ranked_lists:
        for rank, key in enumerate(ids):
            scores[key] = scores.get(key, 0) + 1 / (60 + rank)
    return sorted(scores, key=scores.get, reverse=True)


def memory_candidates(db, qvec, tsq, caller, include_past):
    where, params = visibility(caller, include_past)
    params |= {"q": qvec, "tsq": tsq, "n": CANDIDATES}
    by_meaning = [r["id"] for r in db.execute(
        f"select m.id from memories m where {where} order by m.embedding <=> %(q)s::vector limit %(n)s", params)]
    by_words = []
    if tsq:
        by_words = [r["id"] for r in db.execute(
            f"""select m.id from memories m, to_tsquery('english', %(tsq)s) q
                where {where} and m.tsv @@ q order by ts_rank_cd(m.tsv, q) desc limit %(n)s""", params)]
    ids = fuse(by_meaning, by_words)[:CANDIDATES]
    if not ids:
        return []
    rows = {r["id"]: r for r in db.execute(
        f"""select {MEMORY_COLUMNS}, 1 - (m.embedding <=> %s::vector) as similarity
            from memories m left join commitments c on c.memory_id = m.id where m.id = any(%s)""",
        (qvec, ids))}
    return [rows[i] for i in ids if i in rows]


def wiki_candidates(db, qvec, tsq, include_deprecated):
    params = {"q": qvec, "tsq": tsq, "n": CANDIDATES, "dep": bool(include_deprecated)}
    where = "(%(dep)s or p.info->>'status' is distinct from 'deprecated')"
    by_meaning = [r["id"] for r in db.execute(
        f"""select c.id from wiki_chunks c join wiki_pages p using (path) where {where}
            order by c.embedding <=> %(q)s::vector limit %(n)s""", params)]
    by_words = []
    if tsq:
        by_words = [r["id"] for r in db.execute(
            f"""select c.id from wiki_chunks c join wiki_pages p using (path), to_tsquery('english', %(tsq)s) q
                where {where} and c.tsv @@ q order by ts_rank_cd(c.tsv, q) desc limit %(n)s""", params)]
    ids = fuse(by_meaning, by_words)[:CANDIDATES]
    if not ids:
        return []
    rows = {r["id"]: r for r in db.execute(
        "select c.id, c.path, c.heading, c.text, p.title, p.info from wiki_chunks c join wiki_pages p using (path) "
        "where c.id = any(%s)", (ids,))}
    return [rows[i] for i in ids if i in rows]


def search(query, caller, limit, include_memories, include_wiki, include_past=False, include_deprecated=False):
    notes = []
    if include_wiki:
        try:
            changed = sync_wiki()
            if changed:
                notes.append(f"Re-indexed {changed} changed wiki page(s).")
        except Exception as exc:
            notes.append(f"Couldn't update the wiki index, so recent edits may be missing: {exc}")

    qvec = embed([query_text(query)])[0]
    tsq = ts_query(query)
    with connect() as db:
        memories = memory_candidates(db, qvec, tsq, caller, include_past) if include_memories else []
        chunks = wiki_candidates(db, qvec, tsq, include_deprecated) if include_wiki else []

        # Plain sentences ranked better than the embedding prompt format in testing.
        docs = [r["content"] for r in memories]
        docs += [wiki_text(r["title"], r["heading"], r["text"]) for r in chunks]
        try:
            scores = rerank(query, docs)
            reranked = True
        except Exception as exc:
            notes.append(f"Reranker unavailable, so results are in search order: {exc}")
            scores = [1 / (1 + i) for i in range(len(docs))]
            reranked = False

        items = []
        for row, score in zip(memories, scores):
            if reranked and score < MIN_MEMORY_SCORE and row["similarity"] < MIN_MEMORY_SIMILARITY:
                continue
            # What the owner said or confirmed outranks what was inferred.
            boost = 1.1 if row["origin"] == "stated" or row["confirmed_at"] else 1.0
            items.append((score * boost, "memory", row, score))
        for row, score in zip(chunks, scores[len(memories):]):
            if not reranked or score >= MIN_SCORE:
                items.append((score, "wiki", row, score))
        items.sort(key=lambda item: item[0], reverse=True)

        results, per_page = [], {}
        for _, source, row, score in items:
            if source == "wiki":
                if per_page.get(row["path"], 0) >= 2:
                    continue
                per_page[row["path"]] = per_page.get(row["path"], 0) + 1
                results.append(wiki_result(row, score))
            else:
                results.append(memory_row(row, score))
            if len(results) >= limit:
                break

        recalled = [r["id"] for r in results if r["source"] == "memory"]
        if recalled:
            db.execute(
                "update memories set last_recalled_at = now(), recall_count = recall_count + 1 where id = any(%s)",
                (recalled,),
            )

    out = {"results": results}
    if not results:
        out["message"] = "Nothing closely matches."
    if notes:
        out["notes"] = notes
    return out


# ── Writes ────────────────────────────────────────────────────────────────────────────────


def parse_due(value):
    if not value:
        return None
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    # A date or time without an offset is lugh's local time.
    return parsed if parsed.tzinfo else parsed.astimezone()


def clean_platforms(values):
    out = sorted({str(v).strip().lower() for v in values or [] if str(v).strip()})
    return [] if "all" in out else out


def remember(body, caller, origin="stated"):
    kind = body.get("kind", "fact")
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    content = str(body.get("content") or "").strip()
    if not content:
        raise ValueError("content is empty")
    privacy = body.get("privacy", "normal")
    if privacy not in ("normal", "local_only"):
        raise ValueError("privacy must be normal or local_only")
    importance = max(1, min(int(body.get("importance", 3)), 5))
    platforms = clean_platforms(body.get("platforms"))
    due = parse_due(body.get("due"))
    condition = (body.get("condition") or "").strip() or None

    vec = embed([memory_text(kind, content)])[0]
    with connect() as db:
        near = db.execute(
            """select m.id, m.kind, m.content, 1 - (m.embedding <=> %s::vector) as similarity
               from memories m where m.valid_until is null and not m.retracted
               order by m.embedding <=> %s::vector limit 3""",
            (vec, vec),
        ).fetchall()
        if near and near[0]["similarity"] >= DUPLICATE_SIMILARITY:
            return {"status": "duplicate", "existing": {k: near[0][k] for k in ("id", "kind", "content")},
                    "message": "A near-identical memory already exists. Use memory_revise to change it."}

        row = db.execute(
            """insert into memories (kind, content, embedding, importance, privacy, platforms, origin, confidence)
               values (%s, %s, %s::vector, %s, %s, %s, %s, %s) returning id""",
            (kind, content, vec, importance, privacy, platforms, origin,
             INFERRED_CONFIDENCE if origin == "inferred" else 1.0),
        ).fetchone()
        memory_id = row["id"]
        db.execute("insert into sources (memory_id, platform, session_id) values (%s, %s, %s)",
                   (memory_id, caller["platform"], caller.get("session_id")))
        if kind == "commitment":
            db.execute("insert into commitments (memory_id, due_at, condition) values (%s, %s, %s)",
                       (memory_id, due, condition))
        record(db, memory_id, "create", caller["actor"], after=snapshot(db, memory_id))

    out = {"status": "saved", "id": memory_id}
    similar = [{k: n[k] for k in ("id", "kind", "content")} for n in near if n["similarity"] >= SIMILAR_SIMILARITY]
    if similar:
        out["similar"] = similar
        out["message"] = "Check these related memories. If the new one changes or contradicts one, revise it."
    schedule_export()
    return out


def revise(body, caller, origin="stated"):
    memory_id = int(body["id"])
    action = body.get("action")
    reason = (body.get("reason") or "").strip() or None
    with connect() as db:
        current = db.execute(
            f"select {MEMORY_COLUMNS}, m.retracted from memories m left join commitments c on c.memory_id = m.id "
            "where m.id = %s for update of m",
            (memory_id,),
        ).fetchone()
        where, params = visibility(caller, True)
        visible = current and db.execute(f"select 1 from memories m where m.id = %(id)s and {where}",
                                         params | {"id": memory_id}).fetchone()
        if not visible:
            return {"error": f"No memory #{memory_id} that you can change."}
        before = snapshot(db, memory_id)

        if action == "forget":
            db.execute("delete from memories where id = %s", (memory_id,))
            # Earlier records keep their dates and actions but lose the forgotten content.
            db.execute("update history set before = null, after = null where memory_id = %s", (memory_id,))
            record(db, memory_id, "forget", caller["actor"], reason=reason)
            result = {"status": "forgotten", "id": memory_id}

        elif action == "confirm":
            db.execute("update memories set confirmed_at = now(), updated_at = now() where id = %s", (memory_id,))
            record(db, memory_id, "confirm", caller["actor"], before=before, reason=reason)
            result = {"status": "confirmed", "id": memory_id}

        elif action in ("complete", "cancel"):
            if current["kind"] != "commitment":
                return {"error": f"#{memory_id} isn't a commitment."}
            db.execute("update commitments set status = %s, resolved_at = now() where memory_id = %s",
                       ("done" if action == "complete" else "cancelled", memory_id))
            db.execute("update memories set valid_until = now(), updated_at = now() where id = %s", (memory_id,))
            record(db, memory_id, action, caller["actor"], before=before, reason=reason)
            result = {"status": "done" if action == "complete" else "cancelled", "id": memory_id}

        elif action in ("replace", "retract"):
            if current["valid_until"] is not None:
                return {"error": f"#{memory_id} is no longer current, so it can't be replaced."}
            content = (body.get("content") or "").strip()
            new_id = None
            if content:
                kind = current["kind"]
                vec = embed([memory_text(kind, content)])[0]
                new_id = db.execute(
                    """insert into memories (kind, content, embedding, importance, privacy, platforms, origin,
                                             confidence)
                       values (%s, %s, %s::vector, %s, %s, %s, %s, %s) returning id""",
                    (kind, content, vec, current["importance"], current["privacy"], current["platforms"], origin,
                     INFERRED_CONFIDENCE if origin == "inferred" else 1.0),
                ).fetchone()["id"]
                db.execute("insert into sources (memory_id, platform, session_id) values (%s, %s, %s)",
                           (new_id, caller["platform"], caller.get("session_id")))
                if kind == "commitment":
                    db.execute("insert into commitments (memory_id, due_at, condition) values (%s, %s, %s)",
                               (new_id, parse_due(body.get("due")) or current["due_at"],
                                (body.get("condition") or "").strip() or current["condition"]))
                record(db, new_id, "create", caller["actor"], after=snapshot(db, new_id),
                       reason=f"replaces #{memory_id}")
            elif action == "replace":
                return {"error": "replace needs the new content."}
            # A retracted memory was never true, so recall leaves it out even when asked about the past.
            db.execute(
                """update memories set valid_until = now(), superseded_by = %s, retracted = %s, updated_at = now()
                   where id = %s""",
                (new_id, action == "retract", memory_id),
            )
            record(db, memory_id, action, caller["actor"], before=before, after=snapshot(db, memory_id),
                   reason=reason)
            result = {"status": "replaced" if action == "replace" else "retracted", "id": memory_id}
            if new_id:
                result["new_id"] = new_id
        else:
            raise ValueError("action must be replace, retract, confirm, complete, cancel or forget")

    schedule_export()
    return result


def list_memories(body, caller):
    kind = body.get("kind")
    if kind and kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    limit = max(1, min(int(body.get("limit", 30)), 100))
    where, params = visibility(caller, body.get("include_past", False))
    params |= {"kind": kind, "limit": limit, "status": body.get("status")}
    with connect() as db:
        rows = db.execute(
            f"""select {MEMORY_COLUMNS} from memories m left join commitments c on c.memory_id = m.id
                where {where} and (%(kind)s::text is null or m.kind = %(kind)s)
                  and (%(status)s::text is null or c.status = %(status)s)
                order by c.due_at asc nulls last, m.updated_at desc limit %(limit)s""",
            params,
        ).fetchall()
    return {"memories": [memory_row(r) for r in rows]}


def wiki_related(body):
    link = "/" + str(body.get("path") or "").removeprefix(os.path.realpath(ARGS.wiki)).lstrip("/")
    limit = max(1, min(int(body.get("limit", 8)), 20))
    sync_wiki()
    with connect() as db:
        centre = db.execute("select avg(embedding) as v from wiki_chunks where path = %s", (link,)).fetchone()["v"]
        if centre is None:
            return {"error": f"{link} isn't in the index. Check the path, or that the page has text."}
        rows = db.execute(
            """select p.path, p.title, p.info, max(1 - (c.embedding <=> %(v)s::vector)) as score
               from wiki_chunks c join wiki_pages p using (path) where c.path <> %(link)s
               group by p.path, p.title, p.info order by score desc limit %(n)s""",
            {"v": centre, "link": link, "n": limit},
        ).fetchall()
    root = os.path.realpath(ARGS.wiki)
    return {"page": link, "related": [
        {"path": root + r["path"], "link": r["path"], "title": r["title"], "score": round(float(r["score"]), 4),
         "status": r["info"].get("status"), "trust": r["info"].get("trust")}
        for r in rows
    ]}


# ── Obsidian export ───────────────────────────────────────────────────────────────────────

_export_timer = None
_export_lock = threading.Lock()

EXPORT_FILES = {
    "preference": ("preferences.md", "Preferences"),
    "procedure": ("procedures.md", "How the owner likes things done"),
    "fact": ("facts.md", "Facts"),
    "event": ("events.md", "Events"),
    "commitment": ("commitments.md", "Commitments"),
}


def schedule_export():
    """Rewrite the export shortly after the last change, so a burst of edits writes once."""
    global _export_timer
    with _export_lock:
        if _export_timer:
            _export_timer.cancel()
        _export_timer = threading.Timer(3, safe_export)
        _export_timer.daemon = True
        _export_timer.start()


def safe_export():
    try:
        export()
    except Exception:
        log.exception("export failed")


def export():
    """One OKF page per kind. Local-only memories never leave lugh, so they're left out."""
    os.makedirs(ARGS.export_dir, exist_ok=True)
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    with connect() as db:
        rows = db.execute(
            f"""select {MEMORY_COLUMNS} from memories m left join commitments c on c.memory_id = m.id
                where m.privacy = 'normal' and not m.retracted and m.valid_until is null
                order by m.importance desc, m.valid_from"""
        ).fetchall()
    for kind, (filename, title) in EXPORT_FILES.items():
        lines = [
            "---",
            "type: Memory Export",
            f"title: {json.dumps(title)}",
            f"description: {json.dumps(f'Hermes memory: {title.lower()}. Generated, so edits here are overwritten.')}",
            f"generated: {{ by: process:hermes-memory, at: {now} }}",
            "---",
            "",
            f"# {title}",
            "",
            "Generated from Hermes' memory database. To change something, tell Hermes.",
            "",
        ]
        for r in (r for r in rows if r["kind"] == kind):
            notes = [r["origin"]]
            if r["confirmed_at"]:
                notes.append("confirmed")
            if r["platforms"]:
                notes.append("only " + ", ".join(r["platforms"]))
            if kind == "commitment":
                if r["due_at"]:
                    notes.append("due " + r["due_at"].astimezone().strftime("%Y-%m-%d %H:%M"))
                if r["condition"]:
                    notes.append("when " + r["condition"])
            notes.append("since " + r["valid_from"].date().isoformat())
            lines.append(f"- **#{r['id']}** {r['content']} _({'; '.join(notes)})_")
        path = os.path.join(ARGS.export_dir, filename)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, path)


# ── Capture ───────────────────────────────────────────────────────────────────────────────

CAPTURE_PROMPT = """You keep the long-term memory of a personal AI assistant about its owner. You'll get one \
exchange between the owner and the assistant, and the memories already kept that are closest to it. Decide \
whether the owner revealed anything worth remembering for months: facts about them, their life, work, people \
or setup; their preferences; how they want things done; or notable events in their life.

Rules:
- Only what the owner said or clearly confirmed. Ignore the assistant's claims, web pages and tool output, and \
don't treat a question the owner asked as a fact about them.
- Skip details of the task at hand, small talk, and anything a known memory already says. Keep standing \
instructions about how the owner wants a kind of task done from now on.
- Never record passwords, keys, account numbers or other secrets.
- kind: "preference" for what the owner likes, wants or asks of the assistant; "procedure" for how they \
want a particular task done; "event" for something that happened to them; "fact" for anything else true \
about them or their setup.
- Write each memory as one self-contained sentence about "the owner", using they/them, that makes sense \
months later without the conversation. Date events, and only events.
- When the owner says a known memory has changed or was wrong, use "replace" with that memory's id and the \
new content. Otherwise use "add".
- importance: 1 minor, 3 typical, 5 essential to know about them.
- When nothing is worth remembering, return an empty list.

Examples:
- "from now on keep code reviews short" -> preference: The owner wants code reviews kept short.
- "when you write emails for me, sign them 'Cheers, J'" -> procedure: When writing emails for the owner, \
sign them "Cheers, J".
- "my sister Ana is visiting next week" -> fact: The owner has a sister named Ana.
- "fix the typo on line 12" -> nothing: it's about the task at hand.
- "how do hnsw indexes work?" -> nothing: a question isn't a fact about the owner.
- "ugh, my coffee spilled" -> nothing: passing."""

CAPTURE_SCHEMA = {
    "type": "object",
    "properties": {
        "memories": {
            "type": "array",
            "maxItems": CAPTURE_MAX_MEMORIES,
            "items": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["add", "replace"]},
                    "replaces": {"type": "integer"},
                    "kind": {"type": "string", "enum": list(CAPTURE_KINDS)},
                    "content": {"type": "string"},
                    "importance": {"type": "integer", "minimum": 1, "maximum": 5},
                },
                "required": ["action", "kind", "content", "importance"],
            },
        }
    },
    "required": ["memories"],
}

_capture_wake = threading.Event()


def observe(body, caller):
    user = str(body.get("user_message") or "").strip()
    reply = str(body.get("assistant_response") or "").strip()
    if not user:
        return {"status": "skipped"}
    with connect() as db:
        db.execute(
            """insert into observations (platform, remote, session_id, user_message, assistant_response)
               values (%s, %s, %s, %s, %s)""",
            (caller["platform"], caller["remote"], caller.get("session_id"),
             user[:CAPTURE_USER_CHARS], reply[:CAPTURE_REPLY_CHARS]),
        )
    _capture_wake.set()
    return {"status": "queued"}


def capture_context(db, text, caller):
    """The current memories closest to a turn that its chat may see, so a local-only detail never
    turns up in a memory that chat can show."""
    where, params = visibility(caller, False)
    vec = embed([query_text(text[:2000])])[0]
    return db.execute(
        f"""select m.id, m.kind, m.content from memories m where {where}
            order by m.embedding <=> %(vec)s::vector limit %(limit)s""",
        params | {"vec": vec, "limit": CAPTURE_CONTEXT},
    ).fetchall()


def extract(obs, known):
    known_text = "\n".join(f"#{m['id']} ({m['kind']}) {m['content']}" for m in known) or "(none)"
    prompt = (
        f"Today is {datetime.now().astimezone().date().isoformat()}.\n\n"
        f"Known memories:\n{known_text}\n\n"
        f"Owner:\n{obs['user_message']}\n\n"
        f"Assistant:\n{obs['assistant_response'] or '(no reply)'}"
    )
    out = post_json(ARGS.llama_swap_url + "/v1/chat/completions", {
        "model": ARGS.capture_model,
        "messages": [{"role": "system", "content": CAPTURE_PROMPT}, {"role": "user", "content": prompt}],
        "temperature": 0.2,
        "max_tokens": 800,
        "response_format": {"type": "json_schema", "json_schema": {"name": "memories", "schema": CAPTURE_SCHEMA}},
    }, timeout=300)
    items = json.loads(out["choices"][0]["message"]["content"]).get("memories") or []
    return items[:CAPTURE_MAX_MEMORIES]


def capture_one(obs):
    caller = {"platform": obs["platform"], "remote": obs["remote"], "session_id": obs["session_id"],
              "actor": "hermes/capture"}
    with connect() as db:
        known = capture_context(db, obs["user_message"], caller)
    known_ids = {m["id"] for m in known}
    saved = 0
    for item in extract(obs, known):
        content = str(item.get("content") or "").strip()
        kind = item.get("kind")
        if not content or kind not in CAPTURE_KINDS:
            continue
        if item.get("action") == "replace" and item.get("replaces") in known_ids:
            result = revise({"id": item["replaces"], "action": "replace", "content": content,
                             "reason": "the owner said it changed"}, caller, origin="inferred")
        else:
            result = remember({"kind": kind, "content": content, "importance": item.get("importance", 3)},
                              caller, origin="inferred")
        if result.get("status") in ("saved", "replaced"):
            saved += 1
    return saved


def capture_loop():
    while True:
        _capture_wake.wait(60)
        _capture_wake.clear()
        while True:
            with connect() as db:
                obs = db.execute(
                    "select * from observations where attempts < %s order by id limit 1",
                    (CAPTURE_ATTEMPTS,),
                ).fetchone()
            if not obs:
                break
            try:
                saved = capture_one(obs)
                with connect() as db:
                    db.execute("delete from observations where id = %s", (obs["id"],))
                log.info("capture: turn %d gave %d memory change(s)", obs["id"], saved)
            except Exception as exc:
                with connect() as db:
                    attempts = db.execute(
                        "update observations set attempts = attempts + 1 where id = %s returning attempts",
                        (obs["id"],),
                    ).fetchone()["attempts"]
                    if attempts >= CAPTURE_ATTEMPTS:
                        db.execute("delete from observations where id = %s", (obs["id"],))
                log.warning("capture: turn %d failed (attempt %d): %s", obs["id"], attempts,
                            f"{type(exc).__name__}: {exc}"[:300])
                if attempts < CAPTURE_ATTEMPTS:
                    # Most failures are the helper model being busy or reloading.
                    time.sleep(30)
                    break


def safe_capture_loop():
    while True:
        try:
            capture_loop()
        except Exception:
            log.exception("capture loop failed")
            time.sleep(60)


# ── HTTP over the Unix socket ─────────────────────────────────────────────────────────────


def caller_from(body):
    ctx = body.get("caller") or {}
    platform = str(ctx.get("platform") or "unknown")
    return {
        "platform": platform,
        "remote": bool(ctx.get("remote", True)),
        "session_id": ctx.get("session_id"),
        "actor": str(ctx.get("actor") or "hermes/main"),
    }


ROUTES = {
    "/recall": lambda b: search(str(b["query"]), caller_from(b), max(1, min(int(b.get("limit", 8)), 25)),
                                True, bool(b.get("include_wiki", True)), bool(b.get("include_past", False))),
    "/remember": lambda b: remember(b, caller_from(b)),
    "/revise": lambda b: revise(b, caller_from(b)),
    "/list": lambda b: list_memories(b, caller_from(b)),
    "/wiki/search": lambda b: search(str(b["query"]), caller_from(b), max(1, min(int(b.get("limit", 6)), 20)),
                                     False, True, include_deprecated=bool(b.get("include_deprecated", False))),
    "/wiki/related": wiki_related,
    "/export": lambda b: (export(), {"status": "exported"})[1],
    "/observe": lambda b: observe(b, caller_from(b)),
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def address_string(self):
        return "socket"

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)

    def reply(self, status, body):
        data = json.dumps(body, default=str).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/health":
            return self.reply(404, {"error": "not found"})
        try:
            with connect() as db:
                count = db.execute("select count(*) as n from memories where valid_until is null").fetchone()["n"]
                queued = db.execute("select count(*) as n from observations").fetchone()["n"]
            self.reply(200, {"status": "ok", "memories": count, "turns_waiting": queued})
        except Exception as exc:
            self.reply(503, {"status": "error", "error": str(exc)})

    def do_POST(self):
        route = ROUTES.get(self.path)
        if not route:
            return self.reply(404, {"error": "not found"})
        started = time.time()
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            result = route(body)
            status = 200
        except (KeyError, ValueError, TypeError) as exc:
            result, status = {"error": f"Bad request: {exc}"}, 400
        except Exception as exc:
            log.exception("%s failed", self.path)
            result, status = {"error": f"{type(exc).__name__}: {exc}"}, 500
        # Never logs what was asked or stored.
        log.info("%s %d in %.2fs", self.path, status, time.time() - started)
        self.reply(status, result)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    global ARGS
    ARGS = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    migrate()
    try:
        os.unlink(ARGS.socket)
    except FileNotFoundError:
        pass
    server = Server(ARGS.socket, Handler)
    # Hermes runs as the same user. The hermes group, which twins is in, may connect too.
    os.chmod(ARGS.socket, 0o660)
    threading.Thread(target=lambda: (safe_sync_wiki(), safe_export()), daemon=True).start()
    threading.Thread(target=safe_capture_loop, daemon=True).start()
    log.info("listening on %s", ARGS.socket)
    server.serve_forever()


def safe_sync_wiki():
    try:
        log.info("wiki index: %d page(s) changed", sync_wiki(force=True))
    except Exception:
        log.exception("wiki sync failed")


if __name__ == "__main__":
    main()
