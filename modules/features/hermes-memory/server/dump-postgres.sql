-- Everything the Rust service needs from the Python service's Postgres database, as one JSON document that
-- `hermes-memory --import` reads. Run it as hermes, with the Python service stopped so no change is missed:
--   sudo -u hermes psql -d memory -X -A -t -f dump-postgres.sql > memories.json
-- Embeddings are copied as they are (same model), and the wiki index is left out because it rebuilds itself.
select json_build_object(
  'memories', (
    select coalesce(json_agg(json_build_object(
      'id', m.id, 'kind', m.kind, 'content', m.content, 'embedding', m.embedding::text::json,
      'origin', m.origin, 'confidence', m.confidence, 'importance', m.importance, 'privacy', m.privacy,
      'platforms', m.platforms, 'valid_from', m.valid_from, 'valid_until', m.valid_until,
      'superseded_by', m.superseded_by, 'retracted', m.retracted, 'confirmed_at', m.confirmed_at,
      'created_at', m.created_at, 'updated_at', m.updated_at, 'last_recalled_at', m.last_recalled_at,
      'recall_count', m.recall_count,
      'sources', (
        select coalesce(json_agg(json_build_object(
          'platform', s.platform, 'session_id', s.session_id, 'said_at', s.said_at) order by s.id), '[]')
        from sources s where s.memory_id = m.id),
      'commitment', (
        select json_build_object('due_at', c.due_at, 'condition', c.condition, 'status', c.status,
                                 'resolved_at', c.resolved_at)
        from commitments c where c.memory_id = m.id)
    ) order by m.id), '[]')
    from memories m),
  'history', (
    select coalesce(json_agg(json_build_object(
      'memory_id', h.memory_id, 'action', h.action, 'before', h.before, 'after', h.after, 'actor', h.actor,
      'reason', h.reason, 'at', h.at) order by h.id), '[]')
    from history h),
  'observations', (
    select coalesce(json_agg(json_build_object(
      'platform', o.platform, 'remote', o.remote, 'session_id', o.session_id, 'user_message', o.user_message,
      'assistant_response', o.assistant_response, 'received_at', o.received_at, 'attempts', o.attempts)
      order by o.id), '[]')
    from observations o),
  -- Forgotten memories' numbers are never reused, even when the forgotten one was the newest.
  'last_id', (select last_value from memories_id_seq)
);
