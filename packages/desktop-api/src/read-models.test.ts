import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Database } from "bun:sqlite";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAgentRun,
  createMemory,
  createSession,
  insertEvents,
  openDb,
  searchMemory,
} from "@oma/core";
import { saveCandidates } from "@oma/docs";
import {
  createDesktopServices,
  type SessionOperations,
} from "./services.ts";

let db: Database;
const tempDirs: string[] = [];

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

afterEach(() => {
  db.close();
  while (tempDirs.length) {
    rmSync(tempDirs.pop()!, { recursive: true, force: true });
  }
});

function manager(): SessionOperations {
  return {
    list: async () => [],
    status: async () => {
      throw new Error("not used");
    },
    create: async () => {
      throw new Error("not used");
    },
    resume: async () => {
      throw new Error("not used");
    },
    switchAgent: async () => {
      throw new Error("not used");
    },
    end: async () => undefined,
    remove: async () => undefined,
  };
}

function makeSession() {
  const repo = realpathSync(mkdtempSync(join(tmpdir(), "oma-read-models-")));
  tempDirs.push(repo);
  const session = createSession(db, {
    repo_path: repo,
    worktree_path: repo,
    title: "Desktop read models",
  });
  const run = createAgentRun(db, {
    session_id: session.id,
    agent: "claude",
  });
  return { repo, session, run };
}

describe("desktop read models", () => {
  test("returns cursor-paginated normalized transcript events", async () => {
    const { session, run } = makeSession();
    insertEvents(db, session.id, run.id, [
      {
        seq: 0,
        ts: "2026-08-11T10:00:00.000Z",
        role: "user",
        kind: "text",
        tool_name: null,
        text: "first",
        raw: {},
      },
      {
        seq: 1,
        ts: "2026-08-11T10:01:00.000Z",
        role: "assistant",
        kind: "text",
        tool_name: null,
        text: "second",
        raw: {},
      },
    ]);
    const service = createDesktopServices({ db, manager: manager() });

    const page = await service.transcriptList({
      session_id: session.id,
      limit: 1,
    });

    expect(page.items.map((event) => event.text)).toEqual(["second"]);
    expect(page.next_cursor).not.toBeNull();
  });

  test("lists and searches project-scoped plus global memory", async () => {
    const { repo } = makeSession();
    createMemory(db, {
      kind: "decision",
      repo_path: repo,
      title: "Use SwiftUI",
      body: "Native macOS behavior matters.",
    });
    createMemory(db, {
      kind: "risk",
      repo_path: "/other",
      title: "Foreign",
      body: "Must remain isolated.",
    });
    const service = createDesktopServices({ db, manager: manager() });

    expect((await service.memoryList({ repo_path: repo })).map((item) => item.title))
      .toEqual(["Use SwiftUI"]);
    expect(
      (await service.memorySearch({ query: "SwiftUI", repo_path: repo }))
        .map((item) => item.type),
    ).toEqual(["memory"]);
  });

  test("returns a tmux executable and arguments instead of a shell command", async () => {
    const { repo, session } = makeSession();
    const service = createDesktopServices({
      db,
      manager: manager(),
      findTmuxExecutable: async () => "/opt/homebrew/bin/tmux",
    });

    expect(await service.terminalAttachment({ session_id: session.id })).toEqual({
      executable: "/opt/homebrew/bin/tmux",
      arguments: ["attach", "-t", `oma-${session.id}`],
      cwd: repo,
    });
  });

  test("extracts, previews, and applies knowledge as separate operations", async () => {
    const { repo, session } = makeSession();
    const service = createDesktopServices({
      db,
      manager: manager(),
      extractKnowledge: async () => {
        saveCandidates(db, session.id, [
          {
            kind: "decision",
            title: "Use native SwiftUI",
            body: "It provides the strongest Mac experience.",
            confidence: 0.94,
            supersedes_memory_id: null,
          },
        ]);
        return 1;
      },
    });

    expect(await service.promotionExtract({ session_id: session.id })).toEqual({
      candidate_count: 1,
    });
    const preview = await service.promotionPreview({ session_id: session.id });
    expect(preview.diff).toContain("+++ .oma/docs/decisions.md");
    expect(searchMemory(db, "SwiftUI", { repo_path: repo })).toEqual([]);

    const applied = await service.promotionApply({ session_id: session.id });
    expect(applied.promoted).toBe(1);
    expect(searchMemory(db, "SwiftUI", { repo_path: repo })).toHaveLength(1);
    expect((await service.docsList({ repo_path: repo }))[0]).toMatchObject({
      kind: "decision",
      title: "Decisions",
    });
  });
});
