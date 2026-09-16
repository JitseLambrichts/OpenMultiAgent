import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Database } from "bun:sqlite";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentAdapter, ExecResult, LaunchContext } from "@oma/core";
import {
  createAgentRun,
  createMemory,
  createSession,
  insertEvents,
  openDb,
  searchMemory,
} from "@oma/core";
import {
  AUTO_EXTRACT_MIN_EVENTS,
  AUTO_EXTRACT_MIN_INTERVAL_MS,
  countPendingCandidates,
  extractSession,
  listCandidates,
  parseCandidateResponse,
  previewPromotion,
  promoteSession,
  saveCandidates,
  shouldAutoExtract,
} from "./index.ts";

let db: Database;
const tempDirs: string[] = [];

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

afterEach(() => {
  while (tempDirs.length) {
    const path = tempDirs.pop();
    if (path) rmSync(path, { recursive: true, force: true });
  }
});

describe("parseCandidateResponse", () => {
  test("unwraps agent JSON and enforces the candidate schema", () => {
    const response = JSON.stringify({
      result: JSON.stringify({
        candidates: [
          {
            kind: "decision",
            title: "Use Redis Streams",
            body: "Replay is required and Redis is already operated.",
            confidence: 0.9,
          },
        ],
      }),
    });
    expect(parseCandidateResponse(response)).toEqual([
      {
        kind: "decision",
        title: "Use Redis Streams",
        body: "Replay is required and Redis is already operated.",
        confidence: 0.9,
        supersedes_memory_id: null,
      },
    ]);
  });

  test("rejects output outside the strict enum and confidence range", () => {
    expect(() =>
      parseCandidateResponse(
        JSON.stringify({
          candidates: [
            { kind: "opinion", title: "x", body: "y", confidence: 2 },
          ],
        }),
      ),
    ).toThrow(/invalid candidate/);
  });

  test("unwraps OpenCode JSONL text events", () => {
    const payload = JSON.stringify({
      candidates: [
        {
          kind: "decision",
          title: "Use Redis Streams",
          body: "Replay is required.",
          confidence: 0.9,
        },
      ],
    });
    const stream = [
      JSON.stringify({
        type: "step_start",
        part: { type: "step-start" },
      }),
      JSON.stringify({
        type: "text",
        part: { type: "text", text: `\`\`\`json\n${payload}\n\`\`\`` },
      }),
      JSON.stringify({
        type: "step_finish",
        part: { type: "step-finish", reason: "stop" },
      }),
    ].join("\n");
    expect(parseCandidateResponse(stream)).toEqual([
      {
        kind: "decision",
        title: "Use Redis Streams",
        body: "Replay is required.",
        confidence: 0.9,
        supersedes_memory_id: null,
      },
    ]);
  });

  test("surfaces OpenCode JSONL error events", () => {
    expect(() =>
      parseCandidateResponse(
        JSON.stringify({
          type: "error",
          error: { name: "APIError", data: { message: "Rate limit exceeded" } },
        }),
      ),
    ).toThrow(/Rate limit exceeded/);
  });
});

describe("extractSession", () => {
  test("stores review candidates but does not promote memory", async () => {
    const repo = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repo);
    const session = createSession(db, {
      id: "session-1",
      repo_path: repo,
      worktree_path: repo,
      title: "Choose queue",
    });
    const run = createAgentRun(db, {
      session_id: session.id,
      agent: "claude",
    });
    insertEvents(db, session.id, run.id, [
      {
        seq: 1,
        ts: "2026-08-11T10:00:00.000Z",
        role: "assistant",
        kind: "text",
        tool_name: null,
        text: "We chose Redis Streams because replay is required.",
        raw: {},
      },
    ]);

    const commands: string[][] = [];
    const adapter: AgentAdapter = {
      name: "claude",
      binary: "fake",
      isAvailable: async () => true,
      buildLaunch: (_ctx: LaunchContext) => {
        throw new Error("not used");
      },
      resolveTranscript: async () => null,
      headlessCommand: ({ prompt }) => ["fake", prompt],
    };
    const runner = async (command: string[]): Promise<ExecResult> => {
      commands.push(command);
      return {
        code: 0,
        stderr: "",
        stdout: JSON.stringify({
          candidates: [
            {
              kind: "decision",
              title: "Use Redis Streams",
              body: "Replay is required.",
              confidence: 0.88,
            },
          ],
        }),
      };
    };

    const candidates = await extractSession(db, session.id, adapter, runner);

    expect(commands[0]?.[1]).toContain("Redis Streams because replay");
    expect(candidates).toHaveLength(1);
    expect(listCandidates(db, session.id)[0]?.status).toBe("pending");
    expect(db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM memory").get()?.n).toBe(0);
    expect(existsSync(join(repo, ".oma", "docs"))).toBe(false);
  });

  test("includes live memory bodies so the extractor can detect contradictions", async () => {
    const repo = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repo);
    const session = createSession(db, {
      id: "session-1",
      repo_path: repo,
      worktree_path: repo,
    });
    createMemory(db, {
      kind: "invariant",
      repo_path: repo,
      title: "Retention policy",
      body: "Events must be retained for exactly seven days.",
    });

    const { buildExtractionPrompt } = await import("./index.ts");
    const prompt = buildExtractionPrompt(db, session.id);

    expect(prompt).toContain("Events must be retained for exactly seven days.");
  });
});

describe("promotion", () => {
  test("previews first, then writes live Markdown with provenance and supersession", () => {
    const repo = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repo);
    const session = createSession(db, {
      id: "session-1",
      repo_path: repo,
      worktree_path: repo,
      title: "Replace queue",
    });
    const old = createMemory(db, {
      kind: "decision",
      repo_path: repo,
      title: "Use RabbitMQ",
      body: "Original queue choice.",
    });
    saveCandidates(db, session.id, [
      {
        kind: "decision",
        title: "Use Redis Streams",
        body: "Replay is now required and Redis is already operated.",
        confidence: 0.92,
        supersedes_memory_id: old.id,
      },
    ]);
    mkdirSync(join(repo, ".oma", "docs"), { recursive: true });
    writeFileSync(
      join(repo, ".oma", "docs", "decisions.md"),
      "# Decisions\n\n## Use RabbitMQ\n\nOriginal queue choice.\n",
    );

    const preview = previewPromotion(db, session.id);
    expect(preview).toContain("+++ .oma/docs/decisions.md");
    expect(preview).toContain("-## Use RabbitMQ");
    expect(preview).toContain("+## Use Redis Streams");
    expect(readFileSync(join(repo, ".oma", "docs", "decisions.md"), "utf8"))
      .toContain("Use RabbitMQ");

    const result = promoteSession(db, session.id);

    expect(result.promoted).toBe(1);
    expect(searchMemory(db, "RabbitMQ", { repo_path: repo })).toHaveLength(0);
    const markdown = readFileSync(
      join(repo, ".oma", "docs", "decisions.md"),
      "utf8",
    );
    expect(markdown).toContain("## Use Redis Streams");
    expect(markdown).toContain("Source session: `session-1`");
    expect(markdown).not.toContain("Use RabbitMQ");
    expect(listCandidates(db, session.id)[0]?.status).toBe("promoted");
  });

  test("refuses to supersede memory owned by another repository", () => {
    const repo = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repo);
    const session = createSession(db, {
      id: "session-1",
      repo_path: repo,
      worktree_path: repo,
    });
    const foreign = createMemory(db, {
      kind: "decision",
      repo_path: "/another-repo",
      title: "Foreign decision",
      body: "Must remain isolated.",
    });
    saveCandidates(db, session.id, [
      {
        kind: "decision",
        title: "Replacement",
        body: "This is not allowed to cross repository scope.",
        confidence: 0.8,
        supersedes_memory_id: foreign.id,
      },
    ]);

    expect(() => promoteSession(db, session.id)).toThrow(/another repository/);
    expect(searchMemory(db, "Foreign", { repo_path: "/another-repo" })).toHaveLength(1);
  });
});

describe("shouldAutoExtract", () => {
  test("is due once inserted events reach the minimum threshold", () => {
    expect(shouldAutoExtract(db, "session-1", AUTO_EXTRACT_MIN_EVENTS)).toBe(
      true,
    );
  });

  test("is not due below the threshold with no prior candidate batch", () => {
    expect(
      shouldAutoExtract(db, "session-1", AUTO_EXTRACT_MIN_EVENTS - 1),
    ).toBe(false);
  });

  test("is not due with zero newly inserted events even if a prior batch is old", () => {
    const repo = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repo);
    const session = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    saveCandidates(db, session.id, [
      {
        kind: "decision",
        title: "Use Redis Streams",
        body: "Replay is required.",
        confidence: 0.9,
        supersedes_memory_id: null,
      },
    ]);

    expect(shouldAutoExtract(db, session.id, 0)).toBe(false);
  });

  test("is due once the minimum interval has passed since the last candidate batch", () => {
    const repo = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repo);
    const session = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    saveCandidates(db, session.id, [
      {
        kind: "decision",
        title: "Use Redis Streams",
        body: "Replay is required.",
        confidence: 0.9,
        supersedes_memory_id: null,
      },
    ]);
    const past = Date.now() + AUTO_EXTRACT_MIN_INTERVAL_MS + 1_000;

    expect(shouldAutoExtract(db, session.id, 1, past)).toBe(true);
    expect(shouldAutoExtract(db, session.id, 1, Date.now())).toBe(false);
  });
});

describe("countPendingCandidates", () => {
  test("sums pending candidates across every session", () => {
    const repoA = mkdtempSync(join(tmpdir(), "oma-docs-"));
    const repoB = mkdtempSync(join(tmpdir(), "oma-docs-"));
    tempDirs.push(repoA, repoB);
    const sessionA = createSession(db, {
      repo_path: repoA,
      worktree_path: repoA,
    });
    const sessionB = createSession(db, {
      repo_path: repoB,
      worktree_path: repoB,
    });
    expect(countPendingCandidates(db)).toBe(0);

    saveCandidates(db, sessionA.id, [
      {
        kind: "decision",
        title: "A",
        body: "a",
        confidence: 0.9,
        supersedes_memory_id: null,
      },
    ]);
    saveCandidates(db, sessionB.id, [
      {
        kind: "risk",
        title: "B1",
        body: "b1",
        confidence: 0.8,
        supersedes_memory_id: null,
      },
      {
        kind: "howto",
        title: "B2",
        body: "b2",
        confidence: 0.7,
        supersedes_memory_id: null,
      },
    ]);
    expect(countPendingCandidates(db)).toBe(3);

    promoteSession(db, sessionA.id);
    expect(countPendingCandidates(db)).toBe(2);
  });
});
