import { beforeEach, describe, expect, test } from "bun:test";
import type { Database } from "bun:sqlite";
import { openDb } from "./db.ts";
import { buildHandoffBrief } from "./handoff.ts";
import {
  createAgentRun,
  createMemory,
  createSession,
  insertEvents,
  recordArtifact,
} from "./store.ts";

let db: Database;

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

describe("buildHandoffBrief", () => {
  test("carries task, decisions, files, diff and recent conversation", () => {
    const session = createSession(db, {
      id: "session-1",
      repo_path: "/repo",
      worktree_path: "/repo/.worktrees/task",
      branch: "oma/task",
      title: "Implement queue consumer",
    });
    const run = createAgentRun(db, {
      session_id: session.id,
      agent: "claude",
      native_session_id: "claude-1",
    });
    insertEvents(db, session.id, run.id, [
      {
        seq: 1,
        ts: "2026-08-11T10:00:00.000Z",
        role: "user",
        kind: "text",
        tool_name: null,
        text: "Use Redis Streams for replay.",
        raw: {},
      },
      {
        seq: 2,
        ts: "2026-08-11T10:00:01.000Z",
        role: "assistant",
        kind: "text",
        tool_name: null,
        text: "I still need to add the retry path.",
        raw: {},
      },
    ]);
    createMemory(db, {
      kind: "invariant",
      repo_path: "/repo",
      title: "At-least-once delivery",
      body: "Acknowledge only after the database commit.",
      source_session_id: session.id,
    });
    recordArtifact(db, session.id, "src/worker.ts", "modified");

    const brief = buildHandoffBrief(db, session.id, {
      diffStat: " src/worker.ts | 12 ++++++------",
    });

    expect(brief).toContain("Implement queue consumer");
    expect(brief).toContain("At-least-once delivery");
    expect(brief).toContain("src/worker.ts");
    expect(brief).toContain("12 ++++++------");
    expect(brief).toContain("Use Redis Streams for replay.");
    expect(brief).toContain("I still need to add the retry path.");
    expect(brief).toContain("continuity of knowledge");
  });

  test("does not leak memory from another repository", () => {
    const session = createSession(db, {
      id: "session-1",
      repo_path: "/repo",
      worktree_path: "/repo",
    });
    createMemory(db, {
      kind: "risk",
      repo_path: "/other",
      title: "Secret other-repo risk",
      body: "Must stay scoped.",
    });

    expect(buildHandoffBrief(db, session.id)).not.toContain("Secret other-repo");
  });
});
