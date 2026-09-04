-- An OMA session spans multiple agent runs; that is what makes an agent switch
-- possible without losing the thread.
CREATE TABLE session (
  id            TEXT PRIMARY KEY,
  repo_path     TEXT NOT NULL,
  worktree_path TEXT NOT NULL,
  branch        TEXT,
  title         TEXT,
  status        TEXT NOT NULL CHECK (status IN ('active', 'ended')),
  started_at    TEXT NOT NULL,
  ended_at      TEXT
);

CREATE INDEX session_repo_idx ON session (repo_path);
CREATE INDEX session_status_idx ON session (status);

CREATE TABLE agent_run (
  id                TEXT PRIMARY KEY,
  session_id        TEXT NOT NULL REFERENCES session (id) ON DELETE CASCADE,
  agent             TEXT NOT NULL,
  native_session_id TEXT,
  transcript_path   TEXT,
  started_at        TEXT NOT NULL,
  ended_at          TEXT
);

CREATE INDEX agent_run_session_idx ON agent_run (session_id);
CREATE INDEX agent_run_native_idx ON agent_run (agent, native_session_id);

CREATE TABLE event (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES session (id) ON DELETE CASCADE,
  agent_run_id TEXT NOT NULL REFERENCES agent_run (id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,
  ts           TEXT NOT NULL,
  role         TEXT NOT NULL,
  kind         TEXT NOT NULL,
  tool_name    TEXT,
  text         TEXT NOT NULL DEFAULT '',
  raw_json     TEXT,
  -- Re-ingesting an appended transcript must not duplicate rows.
  UNIQUE (agent_run_id, seq)
);

CREATE INDEX event_session_idx ON event (session_id, ts);

CREATE TABLE artifact (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES session (id) ON DELETE CASCADE,
  path        TEXT NOT NULL,
  change_kind TEXT NOT NULL CHECK (change_kind IN ('created', 'modified', 'deleted')),
  UNIQUE (session_id, path, change_kind)
);

CREATE TABLE memory (
  id                TEXT PRIMARY KEY,
  kind              TEXT NOT NULL CHECK (kind IN ('decision', 'invariant', 'risk', 'ownership', 'howto')),
  scope             TEXT NOT NULL CHECK (scope IN ('repo', 'global')),
  repo_path         TEXT,
  title             TEXT NOT NULL,
  body              TEXT NOT NULL,
  confidence        REAL NOT NULL DEFAULT 0.5,
  source_session_id TEXT REFERENCES session (id) ON DELETE SET NULL,
  created_at        TEXT NOT NULL,
  -- Corrections supersede rather than overwrite, so history stays intact.
  superseded_by     TEXT REFERENCES memory (id) ON DELETE SET NULL
);

CREATE INDEX memory_scope_idx ON memory (scope, repo_path);
CREATE INDEX memory_live_idx ON memory (superseded_by);

-- FTS5 over the searchable columns, external-content so there is one copy of
-- the text. Triggers keep the index in sync.
CREATE VIRTUAL TABLE memory_fts USING fts5 (
  title,
  body,
  content = 'memory',
  content_rowid = 'rowid'
);

CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
  INSERT INTO memory_fts (rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;

CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN
  INSERT INTO memory_fts (memory_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
END;

CREATE TRIGGER memory_au AFTER UPDATE ON memory BEGIN
  INSERT INTO memory_fts (memory_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
  INSERT INTO memory_fts (rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;

CREATE VIRTUAL TABLE event_fts USING fts5 (
  text,
  content = 'event',
  content_rowid = 'rowid'
);

CREATE TRIGGER event_ai AFTER INSERT ON event BEGIN
  INSERT INTO event_fts (rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TRIGGER event_ad AFTER DELETE ON event BEGIN
  INSERT INTO event_fts (event_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;

CREATE TRIGGER event_au AFTER UPDATE ON event BEGIN
  INSERT INTO event_fts (event_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
  INSERT INTO event_fts (rowid, text) VALUES (new.rowid, new.text);
END;
