CREATE TABLE IF NOT EXISTS project (
  id             TEXT PRIMARY KEY,
  repo_path      TEXT NOT NULL UNIQUE,
  display_name   TEXT NOT NULL,
  created_at     TEXT NOT NULL,
  last_opened_at TEXT NOT NULL
);

-- Existing sessions predate explicit project registration. Split each path
-- recursively so the final non-empty component becomes the initial display
-- name without relying on a platform-specific SQL extension.
WITH RECURSIVE
  repositories(repo_path, created_at, last_opened_at) AS (
    SELECT repo_path, min(started_at), max(started_at)
      FROM session
     GROUP BY repo_path
  ),
  path_parts(repo_path, rest, part, depth) AS (
    SELECT repo_path, trim(repo_path, '/') || '/', '', 0
      FROM repositories
    UNION ALL
    SELECT repo_path,
           substr(rest, instr(rest, '/') + 1),
           substr(rest, 1, instr(rest, '/') - 1),
           depth + 1
      FROM path_parts
     WHERE rest <> ''
  ),
  project_names(repo_path, display_name) AS (
    SELECT repo_path, part
      FROM path_parts
     WHERE rest = '' AND part <> ''
  )
INSERT OR IGNORE INTO project
  (id, repo_path, display_name, created_at, last_opened_at)
SELECT lower(hex(randomblob(16))),
       repositories.repo_path,
       coalesce(project_names.display_name, repositories.repo_path),
       repositories.created_at,
       repositories.last_opened_at
  FROM repositories
  LEFT JOIN project_names USING (repo_path);

CREATE INDEX IF NOT EXISTS project_last_opened_idx ON project (last_opened_at DESC);
