CREATE TABLE promotion_candidate (
  id                     TEXT PRIMARY KEY,
  session_id             TEXT NOT NULL REFERENCES session (id) ON DELETE CASCADE,
  kind                   TEXT NOT NULL CHECK (kind IN ('decision', 'invariant', 'risk', 'ownership', 'howto')),
  title                  TEXT NOT NULL,
  body                   TEXT NOT NULL,
  confidence             REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  supersedes_memory_id   TEXT REFERENCES memory (id) ON DELETE SET NULL,
  status                 TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'promoted', 'rejected')),
  promoted_memory_id     TEXT REFERENCES memory (id) ON DELETE SET NULL,
  created_at             TEXT NOT NULL
);

CREATE INDEX promotion_candidate_session_idx
  ON promotion_candidate (session_id, status, created_at);
