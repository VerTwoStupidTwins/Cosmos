-- The memory database. Every statement can run again, so the whole file is applied at each start.

-- English words reduced to their stems, as Postgres' 'english' configuration did.
DEFINE ANALYZER IF NOT EXISTS english TOKENIZERS class FILTERS lowercase, snowball(english);

-- ── Memories ──────────────────────────────────────────────────────────────────────────────
-- Record ids are the numbers the owner, Hermes and the capture prompt refer to, like memory:12.
DEFINE TABLE IF NOT EXISTS memory SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS kind ON memory TYPE string
    ASSERT $value IN ['fact', 'preference', 'procedure', 'event', 'commitment'];
DEFINE FIELD IF NOT EXISTS content ON memory TYPE string;
DEFINE FIELD IF NOT EXISTS embedding ON memory TYPE array<float>;
DEFINE FIELD IF NOT EXISTS origin ON memory TYPE string DEFAULT 'stated'
    ASSERT $value IN ['stated', 'inferred', 'imported'];
DEFINE FIELD IF NOT EXISTS confidence ON memory TYPE float DEFAULT 1.0 ASSERT $value >= 0 AND $value <= 1;
DEFINE FIELD IF NOT EXISTS importance ON memory TYPE int DEFAULT 3 ASSERT $value >= 1 AND $value <= 5;
DEFINE FIELD IF NOT EXISTS privacy ON memory TYPE string DEFAULT 'normal'
    ASSERT $value IN ['normal', 'local_only'];
-- Empty means every platform.
DEFINE FIELD IF NOT EXISTS platforms ON memory TYPE array<string> DEFAULT [];
DEFINE FIELD IF NOT EXISTS valid_from ON memory TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS valid_until ON memory TYPE option<datetime>;
-- A retracted memory was never true, so recall leaves it out even when asked about the past.
DEFINE FIELD IF NOT EXISTS retracted ON memory TYPE bool DEFAULT false;
DEFINE FIELD IF NOT EXISTS confirmed_at ON memory TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS created_at ON memory TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS updated_at ON memory TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS last_recalled_at ON memory TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS recall_count ON memory TYPE int DEFAULT 0;
-- Where the owner said it.
DEFINE FIELD IF NOT EXISTS sources ON memory TYPE array<object> DEFAULT [];
DEFINE FIELD IF NOT EXISTS sources[*].platform ON memory TYPE option<string>;
DEFINE FIELD IF NOT EXISTS sources[*].session_id ON memory TYPE option<string>;
DEFINE FIELD IF NOT EXISTS sources[*].said_at ON memory TYPE datetime;
-- Only commitments have one.
DEFINE FIELD IF NOT EXISTS commitment ON memory TYPE option<object>;
DEFINE FIELD IF NOT EXISTS commitment.due_at ON memory TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS commitment.condition ON memory TYPE option<string>;
DEFINE FIELD IF NOT EXISTS commitment.status ON memory TYPE string ASSERT $value IN ['open', 'done', 'cancelled'];
DEFINE FIELD IF NOT EXISTS commitment.resolved_at ON memory TYPE option<datetime>;
DEFINE INDEX IF NOT EXISTS memory_content ON memory FIELDS content FULLTEXT ANALYZER english BM25;

-- A replacement points at the memory it replaced: memory:40->supersedes->memory:12.
DEFINE TABLE IF NOT EXISTS supersedes TYPE RELATION IN memory OUT memory SCHEMAFULL;

-- The record of every change. It holds the memory's number rather than a link, so it outlives a
-- forgotten memory; forgetting blanks the content here too.
DEFINE TABLE IF NOT EXISTS history SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS memory_id ON history TYPE int;
DEFINE FIELD IF NOT EXISTS action ON history TYPE string;
DEFINE FIELD IF NOT EXISTS before ON history TYPE option<object> FLEXIBLE;
DEFINE FIELD IF NOT EXISTS after ON history TYPE option<object> FLEXIBLE;
DEFINE FIELD IF NOT EXISTS actor ON history TYPE string;
DEFINE FIELD IF NOT EXISTS reason ON history TYPE option<string>;
DEFINE FIELD IF NOT EXISTS at ON history TYPE datetime DEFAULT time::now();
DEFINE INDEX IF NOT EXISTS history_memory ON history FIELDS memory_id;

-- The last number given to each table, since memory numbers are counted, not random.
DEFINE TABLE IF NOT EXISTS counter SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS n ON counter TYPE int DEFAULT 0;

-- ── Wiki index ────────────────────────────────────────────────────────────────────────────
-- Keyed by the page's path in the wiki, like wiki_page:⟨/topics/x.md⟩.
DEFINE TABLE IF NOT EXISTS wiki_page SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS mtime ON wiki_page TYPE float;
DEFINE FIELD IF NOT EXISTS size ON wiki_page TYPE int;
DEFINE FIELD IF NOT EXISTS hash ON wiki_page TYPE string;
DEFINE FIELD IF NOT EXISTS title ON wiki_page TYPE string;
DEFINE FIELD IF NOT EXISTS details ON wiki_page TYPE object FLEXIBLE;

DEFINE TABLE IF NOT EXISTS wiki_chunk SCHEMAFULL;
-- A page's sections go with it.
DEFINE FIELD IF NOT EXISTS page ON wiki_chunk TYPE record<wiki_page> REFERENCE ON DELETE CASCADE;
DEFINE FIELD IF NOT EXISTS heading ON wiki_chunk TYPE string;
DEFINE FIELD IF NOT EXISTS text ON wiki_chunk TYPE string;
-- What keyword search reads: the heading and the text together.
DEFINE FIELD IF NOT EXISTS search_text ON wiki_chunk TYPE string;
DEFINE FIELD IF NOT EXISTS embedding ON wiki_chunk TYPE array<float>;
DEFINE INDEX IF NOT EXISTS wiki_chunk_text ON wiki_chunk FIELDS search_text FULLTEXT ANALYZER english BM25;
DEFINE INDEX IF NOT EXISTS wiki_chunk_page ON wiki_chunk FIELDS page;

-- ── Capture queue ─────────────────────────────────────────────────────────────────────────
-- Finished turns waiting for capture. Each is deleted once processed, so no transcript is kept.
DEFINE TABLE IF NOT EXISTS observation SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS platform ON observation TYPE string;
DEFINE FIELD IF NOT EXISTS remote ON observation TYPE bool;
DEFINE FIELD IF NOT EXISTS session_id ON observation TYPE option<string>;
DEFINE FIELD IF NOT EXISTS user_message ON observation TYPE string;
DEFINE FIELD IF NOT EXISTS assistant_response ON observation TYPE string;
DEFINE FIELD IF NOT EXISTS received_at ON observation TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS attempts ON observation TYPE int DEFAULT 0;
