"""Search for Hermes' wiki that finds pages by meaning, as an MCP server.

Pages are split into sections and embedded with the local embedding model. A search combines
those embeddings with keyword matching, then the local reranker orders the best candidates.
Each search first re-indexes pages that changed, so the index never needs a separate job.
Nothing here writes to the wiki.
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import time
import urllib.request
from datetime import datetime, timezone

import numpy as np
import yaml
from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wiki", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("--llama-swap-url", required=True)
    parser.add_argument("--embedding-model", default="embedding")
    parser.add_argument("--reranker-model", default="reranker")
    return parser.parse_args()


ARGS = parse_args()
WIKI = os.path.realpath(ARGS.wiki)
RESERVED = {"index.md", "log.md"}

# Sections longer than this are split at paragraphs. EmbeddingGemma reads up to 2048 tokens,
# and a query plus one section has to fit the reranker's 2048-token batch.
MAX_CHARS = 3000
CANDIDATES = 30
# Reranker scores below this were unrelated in testing, and an empty answer is better than a wrong page.
MIN_SCORE = 0.02

server = MCPServer(
    name="wiki-search",
    instructions=(
        "Searches the owner's research wiki at " + WIKI + " by meaning as well as by keyword. "
        "Use wiki_search before answering from the wiki or filing research into it, and "
        "wiki_related to find pages a new or updated page should link to. Read the pages it "
        "returns with read_file for the full text."
    ),
)
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)


# ── Models ────────────────────────────────────────────────────────────────────────────────


def post(path, body, timeout=120):
    req = urllib.request.Request(
        ARGS.llama_swap_url + path,
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def embed(texts):
    vectors = []
    for start in range(0, len(texts), 16):
        out = post("/v1/embeddings", {"model": ARGS.embedding_model, "input": texts[start : start + 16]})
        vectors += [d["embedding"] for d in sorted(out["data"], key=lambda d: d["index"])]
    matrix = np.asarray(vectors, dtype=np.float32)
    return matrix / np.maximum(np.linalg.norm(matrix, axis=1, keepdims=True), 1e-12)


# EmbeddingGemma's own prompts for retrieval.
def query_text(query):
    return f"task: search result | query: {query}"


def document_text(title, heading, text):
    label = f"{title} - {heading}" if heading and heading != title else title
    return f"title: {label or 'none'} | text: {text}"


def rerank(query, documents):
    out = post("/v1/rerank", {"model": ARGS.reranker_model, "query": query, "documents": documents}, timeout=60)
    scores = [0.0] * len(documents)
    for result in out["results"]:
        scores[result["index"]] = result["relevance_score"]
    return scores


# ── Pages ─────────────────────────────────────────────────────────────────────────────────


def wiki_files():
    for root, dirs, files in os.walk(WIKI):
        # Skips .obsidian, .trash and the like.
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            # OKF reserves index.md and log.md at every level.
            if name.endswith(".md") and name not in RESERVED:
                yield "/" + os.path.relpath(os.path.join(root, name), WIKI)


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
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def trust(meta):
    verified = meta.get("verified")
    if isinstance(verified, dict):
        verified = [verified]
    if not verified:
        return "unverified"
    by = [str(v.get("by", "")) for v in verified if isinstance(v, dict)]
    return "human-reviewed" if any(b.startswith("human:") for b in by) else "machine-confirmed"


def page_info(meta):
    stale_after = as_datetime(meta.get("stale_after")) if meta.get("stale_after") else None
    generated = meta.get("generated") if isinstance(meta.get("generated"), dict) else {}
    return {
        "type": str(meta.get("type") or ""),
        "status": str(meta.get("status") or "stable"),
        "trust": trust(meta),
        "stale": bool(stale_after and datetime.now(timezone.utc) >= stale_after),
        "generated_by": str(generated.get("by") or ""),
        "description": str(meta.get("description") or ""),
    }


# ── Index ─────────────────────────────────────────────────────────────────────────────────


def connect():
    os.makedirs(os.path.dirname(ARGS.index), exist_ok=True)
    db = sqlite3.connect(ARGS.index, timeout=60)
    db.execute("pragma journal_mode=wal")
    db.executescript(
        """
        create table if not exists pages (path text primary key, mtime real, size integer, hash text,
                                          title text, info text);
        create table if not exists chunks (id integer primary key, path text, heading text, text text,
                                           vec blob);
        create index if not exists chunks_path on chunks(path);
        create virtual table if not exists chunks_fts using fts5(heading, text, content='chunks',
                                                                 content_rowid='id');
        create table if not exists meta (key text primary key, value text);
        """
    )
    return db


def sync(db):
    """Re-index pages that changed since the last search. Returns how many changed."""
    on_disk = {}
    for path in wiki_files():
        try:
            st = os.stat(WIKI + path)
        except OSError:
            continue
        on_disk[path] = (st.st_mtime, st.st_size)

    known = {p: (m, s, h) for p, m, s, h in db.execute("select path, mtime, size, hash from pages")}
    changed = 0

    db.execute("begin immediate")
    try:
        for path in set(known) - set(on_disk):
            delete_page(db, path)
            changed += 1

        for path, (mtime, size) in on_disk.items():
            old = known.get(path)
            if old and old[0] == mtime and old[1] == size:
                continue
            try:
                with open(WIKI + path, encoding="utf-8", errors="replace") as f:
                    raw = f.read()
            except OSError:
                continue
            digest = hashlib.sha256(raw.encode()).hexdigest()
            if old and old[2] == digest:
                db.execute("update pages set mtime = ?, size = ? where path = ?", (mtime, size, path))
                continue

            meta, body = parse_page(raw)
            title = str(meta.get("title") or os.path.splitext(os.path.basename(path))[0])
            parts = sections(title, body)
            vectors = embed([document_text(title, h, t) for h, t in parts]) if parts else []

            delete_page(db, path)
            for (heading, text), vec in zip(parts, vectors):
                cur = db.execute(
                    "insert into chunks (path, heading, text, vec) values (?, ?, ?, ?)",
                    (path, heading, text, vec.tobytes()),
                )
                db.execute(
                    "insert into chunks_fts (rowid, heading, text) values (?, ?, ?)",
                    (cur.lastrowid, heading, text),
                )
            db.execute(
                "insert or replace into pages values (?, ?, ?, ?, ?, ?)",
                (path, mtime, size, digest, title, json.dumps(page_info(meta))),
            )
            changed += 1
        db.execute("insert or replace into meta values ('synced', ?)", (str(time.time()),))
        db.execute("commit")
    except BaseException:
        db.execute("rollback")
        raise
    return changed


def delete_page(db, path):
    for row_id, heading, text in db.execute("select id, heading, text from chunks where path = ?", (path,)).fetchall():
        db.execute("insert into chunks_fts (chunks_fts, rowid, heading, text) values ('delete', ?, ?, ?)",
                   (row_id, heading, text))
    db.execute("delete from chunks where path = ?", (path,))
    db.execute("delete from pages where path = ?", (path,))


def load_chunks(db):
    rows = db.execute(
        "select c.id, c.path, c.heading, c.text, c.vec, p.title, p.info from chunks c join pages p using (path)"
    ).fetchall()
    if not rows:
        return [], np.zeros((0, 0), dtype=np.float32)
    matrix = np.stack([np.frombuffer(r[4], dtype=np.float32) for r in rows])
    return rows, matrix


def keyword_ranks(db, query):
    # Every word as a quoted term, so punctuation in the query can't break FTS5's syntax.
    terms = [t for t in re.findall(r"\w+", query.lower()) if len(t) > 1]
    if not terms:
        return {}
    match = " OR ".join(f'"{t}"' for t in terms)
    rows = db.execute(
        "select rowid from chunks_fts where chunks_fts match ? order by bm25(chunks_fts) limit ?",
        (match, CANDIDATES),
    ).fetchall()
    return {row_id: rank for rank, (row_id,) in enumerate(rows)}


def result(row, score):
    row_id, path, heading, text, _vec, title, info = row
    snippet = text if len(text) <= 700 else text[:700].rsplit(" ", 1)[0] + " …"
    return {"path": WIKI + path, "link": path, "title": title, "section": heading,
            "score": round(float(score), 4), "excerpt": snippet, **json.loads(info)}


def with_index(fn):
    db = connect()
    try:
        notes = []
        try:
            changed = sync(db)
            if changed:
                notes.append(f"Re-indexed {changed} changed page(s).")
        except Exception as exc:
            notes.append(f"Couldn't update the index, so recent edits may be missing: {exc}")
        out = fn(db)
        if notes:
            out["notes"] = notes
        return out
    finally:
        db.close()


# ── Tools ─────────────────────────────────────────────────────────────────────────────────


@server.tool(annotations=READ_ONLY)
def wiki_search(query: str, limit: int = 6, include_deprecated: bool = False) -> dict:
    """Find wiki sections about a subject, by meaning as well as by keyword.

    query: a question or description in plain words, like "sensing people who sit still".
    limit: how many sections to return, up to 20.
    include_deprecated: also return pages marked deprecated.

    Each result has the page's absolute path for read_file, its wiki link, the matching section
    and an excerpt, plus its status, trust (unverified, machine-confirmed or human-reviewed) and
    whether it's past its stale_after date. At most two sections come from any one page.
    """
    limit = max(1, min(int(limit), 20))

    def run(db):
        rows, matrix = load_chunks(db)
        if not rows:
            return {"results": [], "message": "The wiki has no pages yet."}
        if not include_deprecated:
            keep = [i for i, r in enumerate(rows) if json.loads(r[6])["status"] != "deprecated"]
            rows, matrix = [rows[i] for i in keep], matrix[keep]
            if not rows:
                return {"results": []}

        fused = {}
        notes = []
        try:
            similarity = matrix @ embed([query_text(query)])[0]
            for rank, i in enumerate(np.argsort(-similarity)[:CANDIDATES]):
                fused[i] = fused.get(i, 0) + 1 / (60 + rank)
        except Exception as exc:
            notes.append(f"Meaning search unavailable, so only keywords were used: {exc}")
        by_id = {r[0]: i for i, r in enumerate(rows)}
        for row_id, rank in keyword_ranks(db, query).items():
            if row_id in by_id:
                fused[by_id[row_id]] = fused.get(by_id[row_id], 0) + 1 / (60 + rank)

        candidates = sorted(fused, key=fused.get, reverse=True)[:CANDIDATES]
        scores = [fused[i] for i in candidates]
        try:
            docs = [document_text(rows[i][5], rows[i][2], rows[i][3]) for i in candidates]
            scores = rerank(query, docs) if docs else []
            order = sorted(range(len(candidates)), key=lambda k: scores[k], reverse=True)
            order = [k for k in order if scores[k] >= MIN_SCORE]
            if not order:
                return {"results": [], "message": "No wiki pages closely match. The wiki may not cover this yet."}
        except Exception as exc:
            notes.append(f"Reranker unavailable, so results are in search order: {exc}")
            order = list(range(len(candidates)))

        results, per_page = [], {}
        for k in order:
            row = rows[candidates[k]]
            if per_page.get(row[1], 0) >= 2:
                continue
            per_page[row[1]] = per_page.get(row[1], 0) + 1
            results.append(result(row, scores[k]))
            if len(results) >= limit:
                break
        out = {"results": results}
        if notes:
            out["warnings"] = notes
        return out

    return with_index(run)


@server.tool(annotations=READ_ONLY)
def wiki_related(path: str, limit: int = 8) -> dict:
    """Pages closest in meaning to one wiki page, for choosing what it should link to.

    path: the page's wiki link, like /topics/mmwave-sensors.md, or its absolute path.
    limit: how many pages to return, up to 20.
    """
    limit = max(1, min(int(limit), 20))
    link = "/" + os.path.relpath(os.path.realpath(path), WIKI) if os.path.isabs(path) and path.startswith(WIKI) else path
    link = "/" + link.lstrip("/")

    def run(db):
        rows, matrix = load_chunks(db)
        mine = [i for i, r in enumerate(rows) if r[1] == link]
        if not mine:
            return {"error": f"{link} isn't in the index. Check the path, or that the page has text."}
        centre = matrix[mine].mean(axis=0)
        centre /= max(np.linalg.norm(centre), 1e-12)
        best = {}
        for i, score in enumerate(matrix @ centre):
            page = rows[i][1]
            if page != link and score > best.get(page, (-2, None))[0]:
                best[page] = (float(score), i)
        ranked = sorted(best.values(), reverse=True)[:limit]
        return {"page": link, "related": [
            {k: v for k, v in result(rows[i], score).items() if k not in ("excerpt", "section")}
            for score, i in ranked
        ]}

    return with_index(run)


if __name__ == "__main__":
    server.run("stdio")
