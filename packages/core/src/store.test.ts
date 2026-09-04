import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Database } from "bun:sqlite";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.ts";
import {
  createAgentRun,
  createMemory,
  createProject,
  createSession,
  countEvents,
  endSession,
  insertEvents,
  listEventsPage,
  listMemory,
  listProjects,
  listSessions,
  removeProject,
  resolveProject,
  resolveSession,
  search,
  searchEvents,
  searchMemory,
  supersedeMemory,
} from "./store.ts";
import type { NormalizedEvent } from "./types.ts";

let db: Database;
const tempDirs: string[] = [];

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

afterEach(() => {
  while (tempDirs.length) rmSync(tempDirs.pop()!, { recursive: true, force: true });
});

function event(partial: Partial<NormalizedEvent> & { seq: number }): NormalizedEvent {
  return {
    ts: "2026-08-11T10:00:00.000Z",
    role: "assistant",
    kind: "text",
    tool_name: null,
    text: "",
    raw: null,
    ...partial,
  };
}

describe("migrations", () => {
  test("are idempotent", () => {
    const again = openDb({ path: ":memory:" });
    expect(
      again
        .query<{ n: number }, []>("SELECT COUNT(*) AS n FROM schema_migrations")
        .get()?.n,
    ).toBe(6);
  });

  test("repairs duplicate v3 claims and installs both unique indexes", () => {
    const directory = mkdtempSync(join(tmpdir(), "oma-migrate-"));
    tempDirs.push(directory);
    const path = join(directory, "oma.db");
    const legacy = openDb({ path });
    legacy.run("DROP INDEX agent_run_native_unique");
    legacy.run("DROP INDEX agent_run_transcript_unique");
    legacy.run("DELETE FROM schema_migrations WHERE version >= 4");
    const first = createSession(legacy, { repo_path: "/r", worktree_path: "/r" });
    const second = createSession(legacy, { repo_path: "/r", worktree_path: "/r" });
    for (const session of [first, second]) {
      createAgentRun(legacy, {
        session_id: session.id,
        agent: "codex",
        native_session_id: "duplicate-native",
        transcript_path: "/tmp/duplicate-rollout.jsonl",
      });
    }
    legacy.close();

    const upgraded = openDb({ path });
    const indexes = upgraded
      .query<{ name: string; unique: number }, []>("PRAGMA index_list(agent_run)")
      .all();
    expect(indexes.find((index) => index.name === "agent_run_native_unique"))
      .toMatchObject({
      name: "agent_run_native_unique",
      unique: 1,
    });
    expect(indexes.find((index) => index.name === "agent_run_transcript_unique"))
      .toMatchObject({
      name: "agent_run_transcript_unique",
      unique: 1,
    });
    expect(
      upgraded
        .query<{ n: number }, []>(
          "SELECT COUNT(*) AS n FROM agent_run WHERE native_session_id = 'duplicate-native'",
        )
        .get()?.n,
    ).toBe(1);
    upgraded.close();
  });

  test("create the FTS5 virtual tables", () => {
    const names = db
      .query<{ name: string }, []>(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )
      .all()
      .map((r) => r.name);
    expect(names).toContain("memory_fts");
    expect(names).toContain("event_fts");
  });

  test("create the registered project table", () => {
    const names = db
      .query<{ name: string }, []>(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )
      .all()
      .map((row) => row.name);
    expect(names).toContain("project");
  });
});

describe("sessions", () => {
  test("round-trip and list newest first", () => {
    const a = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const b = createSession(db, { repo_path: "/r", worktree_path: "/w" });
    const ids = listSessions(db).map((s) => s.id);
    expect(ids).toContain(a.id);
    expect(ids).toContain(b.id);
  });

  test("resolve by unique id prefix, like a short git hash", () => {
    const s = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    expect(resolveSession(db, s.id.slice(0, 8)).id).toBe(s.id);
  });

  test("resolving an unknown prefix throws", () => {
    expect(() => resolveSession(db, "zzzzzzzz")).toThrow(/no session matches/);
  });

  test("ending a session also closes its open agent runs", () => {
    const s = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const run = createAgentRun(db, { session_id: s.id, agent: "claude" });
    endSession(db, s.id);
    const stored = db
      .query<{ ended_at: string | null }, [string]>(
        "SELECT ended_at FROM agent_run WHERE id = ?",
      )
      .get(run.id);
    expect(stored?.ended_at).not.toBeNull();
  });

  test("deleting a session cascades to its events", () => {
    const s = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const run = createAgentRun(db, { session_id: s.id, agent: "claude" });
    insertEvents(db, s.id, run.id, [event({ seq: 0, text: "hello" })]);
    db.run("DELETE FROM session WHERE id = ?", [s.id]);
    expect(
      db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM event").get()?.n,
    ).toBe(0);
  });
});

describe("projects", () => {
  test("creating a session registers its canonical repository once", () => {
    const directory = mkdtempSync(join(tmpdir(), "oma-project-"));
    tempDirs.push(directory);

    createSession(db, {
      repo_path: join(directory, "."),
      worktree_path: directory,
    });
    createSession(db, {
      repo_path: directory,
      worktree_path: directory,
    });

    expect(listProjects(db)).toHaveLength(1);
    expect(listProjects(db)[0]).toMatchObject({
      repo_path: realpathSync(directory),
      display_name: directory.split("/").at(-1),
    });
  });

  test("explicit registration is idempotent and resolves by id prefix", () => {
    const directory = mkdtempSync(join(tmpdir(), "oma-project-"));
    tempDirs.push(directory);

    const first = createProject(db, {
      repo_path: directory,
      display_name: "OMA",
    });
    const second = createProject(db, { repo_path: directory });

    expect(second.id).toBe(first.id);
    expect(second.display_name).toBe("OMA");
    expect(resolveProject(db, first.id.slice(0, 8)).id).toBe(first.id);
  });

  test("removing a project registration never removes its sessions", () => {
    const session = createSession(db, {
      repo_path: "/registered/repo",
      worktree_path: "/registered/repo",
    });
    const project = listProjects(db)[0]!;

    removeProject(db, project.id);

    expect(listProjects(db)).toEqual([]);
    expect(resolveSession(db, session.id).id).toBe(session.id);
  });
});

describe("insertEvents", () => {
  test("one native transcript cannot be claimed by two agent runs", () => {
    const first = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const second = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    createAgentRun(db, {
      session_id: first.id,
      agent: "codex",
      native_session_id: "native-1",
      transcript_path: "/tmp/rollout-1.jsonl",
    });

    expect(() =>
      createAgentRun(db, {
        session_id: second.id,
        agent: "codex",
        native_session_id: "native-1",
        transcript_path: "/tmp/rollout-1.jsonl",
      }),
    ).toThrow();
  });

  test("is idempotent so a growing transcript can be re-read from the start", () => {
    const s = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const run = createAgentRun(db, { session_id: s.id, agent: "claude" });

    const first = [event({ seq: 0, text: "one" }), event({ seq: 1, text: "two" })];
    expect(insertEvents(db, s.id, run.id, first)).toBe(2);

    const appended = [...first, event({ seq: 2, text: "three" })];
    expect(insertEvents(db, s.id, run.id, appended)).toBe(1);
    expect(countEvents(db, run.id)).toBe(3);
  });

  test("pages a session transcript newest first without duplicates", () => {
    const session = createSession(db, {
      repo_path: "/r",
      worktree_path: "/r",
    });
    const run = createAgentRun(db, {
      session_id: session.id,
      agent: "claude",
    });
    insertEvents(db, session.id, run.id, [
      event({ seq: 0, ts: "2026-08-11T10:00:00.000Z", text: "zero" }),
      event({ seq: 1, ts: "2026-08-11T10:01:00.000Z", text: "one" }),
      event({ seq: 2, ts: "2026-08-11T10:02:00.000Z", text: "two" }),
      event({ seq: 3, ts: "2026-08-11T10:03:00.000Z", text: "three" }),
    ]);

    const newest = listEventsPage(db, { session_id: session.id, limit: 2 });
    expect(newest.items.map((item) => item.seq)).toEqual([3, 2]);
    expect(newest.next_cursor).not.toBeNull();

    const older = listEventsPage(db, {
      session_id: session.id,
      before: newest.next_cursor!,
      limit: 2,
    });
    expect(older.items.map((item) => item.seq)).toEqual([1, 0]);
    expect(older.next_cursor).toBeNull();
  });

  test("rejects a malformed transcript cursor", () => {
    const session = createSession(db, {
      repo_path: "/r",
      worktree_path: "/r",
    });
    expect(() =>
      listEventsPage(db, {
        session_id: session.id,
        before: "not-a-cursor",
      }),
    ).toThrow(/invalid transcript cursor/);
  });
});

describe("search", () => {
  test("lists live project and global memory without leaking another repo", () => {
    const local = createMemory(db, {
      kind: "decision",
      repo_path: "/r",
      title: "Local",
      body: "Visible in this project.",
    });
    createMemory(db, {
      kind: "risk",
      repo_path: "/other",
      title: "Foreign",
      body: "Must not be listed.",
    });
    createMemory(db, {
      kind: "howto",
      scope: "global",
      title: "Global",
      body: "Visible in every project.",
    });
    const replacement = createMemory(db, {
      kind: "decision",
      repo_path: "/r",
      title: "Replacement",
      body: "This replaces local memory.",
    });
    supersedeMemory(db, local.id, replacement.id);

    expect(
      listMemory(db, { repo_path: "/r" })
        .map((item) => item.title)
        .sort(),
    ).toEqual(["Global", "Replacement"]);
  });

  test("rejects confidence outside the documented range", () => {
    expect(() =>
      createMemory(db, {
        kind: "risk",
        title: "Invalid confidence",
        body: "Must never be stored.",
        confidence: 1.5,
      }),
    ).toThrow(/between 0 and 1/);
  });

  test("deduplicates an identical live memory record", () => {
    const input = {
      kind: "decision" as const,
      repo_path: "/r",
      title: "Use SQLite",
      body: "It is local and requires no service.",
      confidence: 0.9,
    };
    const first = createMemory(db, input);
    const second = createMemory(db, input);

    expect(second.id).toBe(first.id);
    expect(
      db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM memory").get()?.n,
    ).toBe(1);
  });

  test("finds memory by natural-language question with punctuation", () => {
    createMemory(db, {
      kind: "decision",
      repo_path: "/r",
      title: "tmux as session substrate",
      body: "Sessions survive a daemon crash and tmux attach is the escape hatch.",
    });
    const hits = searchMemory(db, "why do we use tmux?", { repo_path: "/r" });
    expect(hits).toHaveLength(1);
    expect(hits[0]!.title).toContain("tmux");
  });

  test("repo-scoped memory does not leak to another repo, global does", () => {
    createMemory(db, {
      kind: "invariant",
      repo_path: "/r",
      title: "repo-only rule about widgets",
      body: "widgets",
    });
    createMemory(db, {
      kind: "howto",
      scope: "global",
      title: "global note about widgets",
      body: "widgets",
    });
    const hits = searchMemory(db, "widgets", { repo_path: "/other" });
    expect(hits.map((h) => h.scope)).toEqual(["global"]);
  });

  test("superseded memory is hidden unless explicitly requested", () => {
    const old = createMemory(db, {
      kind: "decision",
      title: "we use Postgres",
      body: "chosen for embeddings",
    });
    const replacement = createMemory(db, {
      kind: "decision",
      title: "we use SQLite FTS5",
      body: "no dependencies, offline",
    });
    supersedeMemory(db, old.id, replacement.id);

    expect(searchMemory(db, "Postgres")).toHaveLength(0);
    expect(searchMemory(db, "Postgres", { includeSuperseded: true })).toHaveLength(1);
  });

  test("searches transcript events too", () => {
    const s = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const run = createAgentRun(db, { session_id: s.id, agent: "codex" });
    insertEvents(db, s.id, run.id, [
      event({ seq: 0, text: "we picked bun:sqlite because FTS5 ships with it" }),
    ]);
    const hits = searchEvents(db, "bun:sqlite", { repo_path: "/r" });
    expect(hits).toHaveLength(1);
    expect(hits[0]!.agent).toBe("codex");
  });

  test("ranks promoted memory above raw transcript lines", () => {
    const s = createSession(db, { repo_path: "/r", worktree_path: "/r" });
    const run = createAgentRun(db, { session_id: s.id, agent: "claude" });
    insertEvents(db, s.id, run.id, [event({ seq: 0, text: "worktree worktree worktree" })]);
    createMemory(db, {
      kind: "invariant",
      repo_path: "/r",
      title: "worktree isolation",
      body: "each session gets its own worktree",
    });

    const hits = search(db, "worktree", { repo_path: "/r" });
    expect(hits[0]!.type).toBe("memory");
    expect(hits.some((h) => h.type === "event")).toBe(true);
  });

  test("a query with no searchable terms returns nothing instead of throwing", () => {
    expect(search(db, "??? ...")).toEqual([]);
  });
});
