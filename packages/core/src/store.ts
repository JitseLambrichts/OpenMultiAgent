import type { Database } from "bun:sqlite";
import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { toFtsQuery } from "./fts.ts";
import { repoName } from "./git.ts";
import { resolveRealPath } from "./paths.ts";
import type {
  AgentName,
  AgentRun,
  ChangeKind,
  EventPage,
  EventRow,
  Memory,
  MemoryKind,
  MemoryScope,
  NormalizedEvent,
  Project,
  Session,
} from "./types.ts";

const now = () => new Date().toISOString();

// --- projects -------------------------------------------------------------

export interface CreateProjectInput {
  repo_path: string;
  display_name?: string;
}

export function createProject(
  db: Database,
  input: CreateProjectInput,
): Project {
  const repoPath = resolveRealPath(resolve(input.repo_path));
  const existing = db
    .query<Project, [string]>("SELECT * FROM project WHERE repo_path = ?")
    .get(repoPath);
  if (existing) {
    const openedAt = now();
    db.run("UPDATE project SET last_opened_at = ? WHERE id = ?", [
      openedAt,
      existing.id,
    ]);
    return { ...existing, last_opened_at: openedAt };
  }

  const createdAt = now();
  const project: Project = {
    id: randomUUID(),
    repo_path: repoPath,
    display_name: input.display_name?.trim() || repoName(repoPath),
    created_at: createdAt,
    last_opened_at: createdAt,
  };
  db.run(
    `INSERT INTO project (id, repo_path, display_name, created_at, last_opened_at)
     VALUES (?, ?, ?, ?, ?)`,
    [
      project.id,
      project.repo_path,
      project.display_name,
      project.created_at,
      project.last_opened_at,
    ],
  );
  return project;
}

export function listProjects(db: Database): Project[] {
  return db
    .query<Project, []>(
      "SELECT * FROM project ORDER BY last_opened_at DESC, display_name COLLATE NOCASE, id",
    )
    .all();
}

export function resolveProject(db: Database, idOrPrefix: string): Project {
  const exact = db
    .query<Project, [string]>("SELECT * FROM project WHERE id = ?")
    .get(idOrPrefix);
  if (exact) return exact;

  const matches = db
    .query<Project, [string]>("SELECT * FROM project WHERE id LIKE ? || '%'")
    .all(idOrPrefix);
  if (matches.length === 1) return matches[0]!;
  if (matches.length === 0) throw new Error(`no project matches '${idOrPrefix}'`);
  throw new Error(
    `'${idOrPrefix}' is ambiguous (${matches.length} projects match)`,
  );
}

export function removeProject(db: Database, idOrPrefix: string): void {
  const project = resolveProject(db, idOrPrefix);
  db.run("DELETE FROM project WHERE id = ?", [project.id]);
}

// --- sessions -------------------------------------------------------------

export interface CreateSessionInput {
  id?: string;
  repo_path: string;
  worktree_path: string;
  branch?: string | null;
  title?: string | null;
}

export function createSession(db: Database, input: CreateSessionInput): Session {
  createProject(db, { repo_path: input.repo_path });
  const session: Session = {
    id: input.id ?? randomUUID(),
    repo_path: input.repo_path,
    worktree_path: input.worktree_path,
    branch: input.branch ?? null,
    title: input.title ?? null,
    status: "active",
    started_at: now(),
    ended_at: null,
  };
  db.run(
    `INSERT INTO session (id, repo_path, worktree_path, branch, title, status, started_at, ended_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      session.id,
      session.repo_path,
      session.worktree_path,
      session.branch,
      session.title,
      session.status,
      session.started_at,
      session.ended_at,
    ],
  );
  return session;
}

export function getSession(db: Database, id: string): Session | null {
  return (
    db.query<Session, [string]>("SELECT * FROM session WHERE id = ?").get(id) ??
    null
  );
}

/**
 * Ids are UUIDs, which are unpleasant to type. A unique prefix resolves to the
 * full session, the way git resolves short hashes.
 */
export function resolveSession(db: Database, idOrPrefix: string): Session {
  const exact = getSession(db, idOrPrefix);
  if (exact) return exact;

  const matches = db
    .query<Session, [string]>("SELECT * FROM session WHERE id LIKE ? || '%'")
    .all(idOrPrefix);

  if (matches.length === 1) return matches[0]!;
  if (matches.length === 0) throw new Error(`no session matches '${idOrPrefix}'`);
  throw new Error(
    `'${idOrPrefix}' is ambiguous (${matches.length} sessions match)`,
  );
}

export function listSessions(
  db: Database,
  opts: { status?: Session["status"]; repo_path?: string } = {},
): Session[] {
  const where: string[] = [];
  const params: string[] = [];
  if (opts.status) {
    where.push("status = ?");
    params.push(opts.status);
  }
  if (opts.repo_path) {
    where.push("repo_path = ?");
    params.push(opts.repo_path);
  }
  const sql = `SELECT * FROM session ${
    where.length ? `WHERE ${where.join(" AND ")}` : ""
  } ORDER BY started_at DESC`;
  return db.query<Session, string[]>(sql).all(...params);
}

export function endSession(db: Database, id: string): void {
  db.run("UPDATE session SET status = 'ended', ended_at = ? WHERE id = ?", [
    now(),
    id,
  ]);
  db.run(
    "UPDATE agent_run SET ended_at = ? WHERE session_id = ? AND ended_at IS NULL",
    [now(), id],
  );
}

export function deleteSession(db: Database, id: string): void {
  db.run("DELETE FROM session WHERE id = ?", [id]);
}

// --- agent runs -----------------------------------------------------------

export interface CreateAgentRunInput {
  session_id: string;
  agent: AgentName;
  native_session_id?: string | null;
  transcript_path?: string | null;
}

export function createAgentRun(
  db: Database,
  input: CreateAgentRunInput,
): AgentRun {
  const run: AgentRun = {
    id: randomUUID(),
    session_id: input.session_id,
    agent: input.agent,
    native_session_id: input.native_session_id ?? null,
    transcript_path: input.transcript_path ?? null,
    started_at: now(),
    ended_at: null,
  };
  db.run(
    `INSERT INTO agent_run (id, session_id, agent, native_session_id, transcript_path, started_at, ended_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [
      run.id,
      run.session_id,
      run.agent,
      run.native_session_id,
      run.transcript_path,
      run.started_at,
      run.ended_at,
    ],
  );
  return run;
}

export function setTranscriptPath(
  db: Database,
  runId: string,
  transcriptPath: string,
): void {
  db.run("UPDATE agent_run SET transcript_path = ? WHERE id = ?", [
    transcriptPath,
    runId,
  ]);
}

export function setNativeSessionId(
  db: Database,
  runId: string,
  nativeSessionId: string,
): void {
  db.run("UPDATE agent_run SET native_session_id = ? WHERE id = ?", [
    nativeSessionId,
    runId,
  ]);
}

export function endActiveAgentRuns(db: Database, sessionId: string): void {
  db.run(
    "UPDATE agent_run SET ended_at = ? WHERE session_id = ? AND ended_at IS NULL",
    [now(), sessionId],
  );
}

export function reopenAgentRun(db: Database, runId: string): void {
  db.run("UPDATE agent_run SET ended_at = NULL WHERE id = ?", [runId]);
}

export function activateSession(db: Database, sessionId: string): void {
  db.run(
    "UPDATE session SET status = 'active', ended_at = NULL WHERE id = ?",
    [sessionId],
  );
}

export function listAgentRuns(db: Database, sessionId: string): AgentRun[] {
  return db
    .query<AgentRun, [string]>(
      "SELECT * FROM agent_run WHERE session_id = ? ORDER BY started_at ASC",
    )
    .all(sessionId);
}

export function listRunsWithTranscripts(db: Database): AgentRun[] {
  return db
    .query<AgentRun, []>(
      "SELECT * FROM agent_run WHERE transcript_path IS NOT NULL",
    )
    .all();
}

// --- events ---------------------------------------------------------------

/** Idempotent: re-ingesting an appended transcript inserts only the new rows. */
export function insertEvents(
  db: Database,
  sessionId: string,
  agentRunId: string,
  events: NormalizedEvent[],
): number {
  const stmt = db.prepare(
    `INSERT OR IGNORE INTO event
       (id, session_id, agent_run_id, seq, ts, role, kind, tool_name, text, raw_json)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  const before = countEvents(db, agentRunId);
  db.transaction(() => {
    for (const e of events) {
      stmt.run(
        randomUUID(),
        sessionId,
        agentRunId,
        e.seq,
        e.ts,
        e.role,
        e.kind,
        e.tool_name,
        e.text,
        e.raw === undefined ? null : JSON.stringify(e.raw),
      );
    }
  })();
  return countEvents(db, agentRunId) - before;
}

export function countEvents(db: Database, agentRunId: string): number {
  return (
    db
      .query<{ n: number }, [string]>(
        "SELECT COUNT(*) AS n FROM event WHERE agent_run_id = ?",
      )
      .get(agentRunId)?.n ?? 0
  );
}

interface EventCursor {
  agent_run_id: string;
  seq: number;
}

function encodeEventCursor(cursor: EventCursor): string {
  return Buffer.from(
    JSON.stringify([cursor.agent_run_id, cursor.seq]),
    "utf8",
  ).toString("base64url");
}

function decodeEventCursor(value: string): EventCursor {
  try {
    const parsed: unknown = JSON.parse(
      Buffer.from(value, "base64url").toString("utf8"),
    );
    if (
      !Array.isArray(parsed) ||
      parsed.length !== 2 ||
      typeof parsed[0] !== "string" ||
      typeof parsed[1] !== "number" ||
      !Number.isInteger(parsed[1])
    ) {
      throw new Error("invalid shape");
    }
    return { agent_run_id: parsed[0], seq: parsed[1] };
  } catch {
    throw new Error("invalid transcript cursor");
  }
}

interface StoredEvent extends Omit<EventRow, "raw"> {
  raw_json: string | null;
}

function hydratedEvent(row: StoredEvent): EventRow {
  let raw: unknown = null;
  if (row.raw_json !== null) {
    try {
      raw = JSON.parse(row.raw_json);
    } catch {
      raw = row.raw_json;
    }
  }
  const { raw_json: _, ...event } = row;
  return { ...event, raw };
}

export function listEventsPage(
  db: Database,
  opts: { session_id: string; before?: string; limit?: number },
): EventPage {
  const session = resolveSession(db, opts.session_id);
  const limit = opts.limit ?? 50;
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) {
    throw new Error("transcript limit must be between 1 and 200");
  }

  const conditions = ["e.session_id = ?"];
  const params: (string | number)[] = [session.id];
  if (opts.before) {
    const cursor = decodeEventCursor(opts.before);
    const boundary = db
      .query<
        { ts: string; agent_run_id: string; seq: number },
        [string, string, number]
      >(
        `SELECT ts, agent_run_id, seq
           FROM event
          WHERE session_id = ? AND agent_run_id = ? AND seq = ?`,
      )
      .get(session.id, cursor.agent_run_id, cursor.seq);
    if (!boundary) throw new Error("invalid transcript cursor");
    conditions.push(
      `(e.ts < ? OR
        (e.ts = ? AND e.agent_run_id < ?) OR
        (e.ts = ? AND e.agent_run_id = ? AND e.seq < ?))`,
    );
    params.push(
      boundary.ts,
      boundary.ts,
      boundary.agent_run_id,
      boundary.ts,
      boundary.agent_run_id,
      boundary.seq,
    );
  }
  params.push(limit + 1);

  const rows = db
    .query<StoredEvent, (string | number)[]>(
      `SELECT e.id, e.session_id, e.agent_run_id, e.seq, e.ts, e.role,
              e.kind, e.tool_name, e.text, e.raw_json
         FROM event e
        WHERE ${conditions.join(" AND ")}
        ORDER BY e.ts DESC, e.agent_run_id DESC, e.seq DESC
        LIMIT ?`,
    )
    .all(...params);
  const hasMore = rows.length > limit;
  const pageRows = rows.slice(0, limit);
  const last = pageRows.at(-1);
  return {
    items: pageRows.map(hydratedEvent),
    next_cursor:
      hasMore && last
        ? encodeEventCursor({
            agent_run_id: last.agent_run_id,
            seq: last.seq,
          })
        : null,
  };
}

export function recordArtifact(
  db: Database,
  sessionId: string,
  path: string,
  changeKind: ChangeKind,
): void {
  db.run(
    "INSERT OR IGNORE INTO artifact (id, session_id, path, change_kind) VALUES (?, ?, ?, ?)",
    [randomUUID(), sessionId, path, changeKind],
  );
}

// --- memory ---------------------------------------------------------------

export interface CreateMemoryInput {
  kind: MemoryKind;
  scope?: MemoryScope;
  repo_path?: string | null;
  title: string;
  body: string;
  confidence?: number;
  source_session_id?: string | null;
}

export function createMemory(db: Database, input: CreateMemoryInput): Memory {
  const requestedConfidence = input.confidence ?? 0.5;
  if (
    !Number.isFinite(requestedConfidence) ||
    requestedConfidence < 0 ||
    requestedConfidence > 1
  ) {
    throw new Error("memory confidence must be between 0 and 1");
  }
  const scope = input.scope ?? (input.repo_path ? "repo" : "global");
  const repoPath = input.repo_path ?? null;
  const existing = db
    .query<Memory, [MemoryKind, MemoryScope, string | null, string, string]>(
      `SELECT * FROM memory
        WHERE kind = ? AND scope = ? AND repo_path IS ? AND title = ? AND body = ?
          AND superseded_by IS NULL
        LIMIT 1`,
    )
    .get(input.kind, scope, repoPath, input.title, input.body);
  if (existing) {
    const confidence = Math.max(existing.confidence, requestedConfidence);
    if (confidence !== existing.confidence) {
      db.run("UPDATE memory SET confidence = ? WHERE id = ?", [
        confidence,
        existing.id,
      ]);
    }
    return { ...existing, confidence };
  }

  const memory: Memory = {
    id: randomUUID(),
    kind: input.kind,
    scope,
    repo_path: repoPath,
    title: input.title,
    body: input.body,
    confidence: requestedConfidence,
    source_session_id: input.source_session_id ?? null,
    created_at: now(),
    superseded_by: null,
  };
  db.run(
    `INSERT INTO memory (id, kind, scope, repo_path, title, body, confidence, source_session_id, created_at, superseded_by)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      memory.id,
      memory.kind,
      memory.scope,
      memory.repo_path,
      memory.title,
      memory.body,
      memory.confidence,
      memory.source_session_id,
      memory.created_at,
      memory.superseded_by,
    ],
  );
  return memory;
}

export function supersedeMemory(
  db: Database,
  oldId: string,
  newId: string,
): void {
  db.run("UPDATE memory SET superseded_by = ? WHERE id = ?", [newId, oldId]);
}

export function listMemory(
  db: Database,
  opts: { repo_path?: string; limit?: number } = {},
): Memory[] {
  const limit = opts.limit ?? 100;
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) {
    throw new Error("memory limit must be between 1 and 200");
  }
  if (opts.repo_path) {
    return db
      .query<Memory, [string, number]>(
        `SELECT * FROM memory
          WHERE superseded_by IS NULL
            AND (scope = 'global' OR repo_path = ?)
          ORDER BY created_at DESC, id DESC
          LIMIT ?`,
      )
      .all(opts.repo_path, limit);
  }
  return db
    .query<Memory, [number]>(
      `SELECT * FROM memory
        WHERE superseded_by IS NULL
        ORDER BY created_at DESC, id DESC
        LIMIT ?`,
    )
    .all(limit);
}

// --- search ---------------------------------------------------------------

export interface MemoryHit {
  type: "memory";
  id: string;
  kind: MemoryKind;
  scope: MemoryScope;
  repo_path: string | null;
  title: string;
  body: string;
  confidence: number;
  created_at: string;
  source_session_id: string | null;
  score: number;
}

export interface EventHit {
  type: "event";
  id: string;
  session_id: string;
  agent: AgentName;
  ts: string;
  role: string;
  kind: string;
  tool_name: string | null;
  text: string;
  score: number;
}

export type SearchHit = MemoryHit | EventHit;

export interface SearchOptions {
  limit?: number;
  /** Repo-scoped memory outside this path is filtered out; global always matches. */
  repo_path?: string;
  includeEvents?: boolean;
  includeSuperseded?: boolean;
}

export function searchMemory(
  db: Database,
  query: string,
  opts: SearchOptions = {},
): MemoryHit[] {
  const fts = toFtsQuery(query);
  if (!fts) return [];
  const limit = opts.limit ?? 10;

  const conditions = ["memory_fts MATCH ?"];
  const params: (string | number)[] = [fts];
  if (!opts.includeSuperseded) conditions.push("m.superseded_by IS NULL");
  if (opts.repo_path) {
    conditions.push("(m.scope = 'global' OR m.repo_path = ?)");
    params.push(opts.repo_path);
  }
  params.push(limit);

  return db
    .query<Omit<MemoryHit, "type">, (string | number)[]>(
      `SELECT m.id, m.kind, m.scope, m.repo_path, m.title, m.body, m.confidence,
              m.created_at, m.source_session_id, bm25(memory_fts, 2.0, 1.0) AS score
         FROM memory_fts
         JOIN memory m ON m.rowid = memory_fts.rowid
        WHERE ${conditions.join(" AND ")}
        ORDER BY score
        LIMIT ?`,
    )
    .all(...params)
    .map((row) => ({ type: "memory" as const, ...row }));
}

export function searchEvents(
  db: Database,
  query: string,
  opts: SearchOptions = {},
): EventHit[] {
  const fts = toFtsQuery(query);
  if (!fts) return [];
  const limit = opts.limit ?? 10;

  const conditions = ["event_fts MATCH ?", "e.text != ''"];
  const params: (string | number)[] = [fts];
  if (opts.repo_path) {
    conditions.push("s.repo_path = ?");
    params.push(opts.repo_path);
  }
  params.push(limit);

  return db
    .query<Omit<EventHit, "type">, (string | number)[]>(
      `SELECT e.id, e.session_id, r.agent, e.ts, e.role, e.kind, e.tool_name, e.text,
              bm25(event_fts) AS score
         FROM event_fts
         JOIN event e ON e.rowid = event_fts.rowid
         JOIN agent_run r ON r.id = e.agent_run_id
         JOIN session s ON s.id = e.session_id
        WHERE ${conditions.join(" AND ")}
        ORDER BY score
        LIMIT ?`,
    )
    .all(...params)
    .map((row) => ({ type: "event" as const, ...row }));
}

/**
 * Memory first, then transcript events. Promoted memory is curated knowledge and
 * should outrank a raw line from a transcript even when the line scores better.
 */
export function search(
  db: Database,
  query: string,
  opts: SearchOptions = {},
): SearchHit[] {
  const limit = opts.limit ?? 10;
  const memories = searchMemory(db, query, opts);
  if (opts.includeEvents === false || memories.length >= limit) {
    return memories.slice(0, limit);
  }
  const events = searchEvents(db, query, {
    ...opts,
    limit: limit - memories.length,
  });
  return [...memories, ...events];
}
