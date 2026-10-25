-- Honcho 3.4.0 requires vector and optionally uses the other two for indexes.
-- Run as postgres after the native module has ensured the database and owner.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
