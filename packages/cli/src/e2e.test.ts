import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Database } from "bun:sqlite";
import {
  claudeTranscriptPath,
  createAgentRun,
  createMemory,
  createSession,
  openDb,
} from "@oma/core";
import { ingestRun } from "@oma/ingest";
import { createMemoryServer } from "@oma/mcp";

/**
 * The M1 acceptance scenario, end to end and deterministic:
 *
 *   session A (Claude) makes a decision  →  its transcript is ingested
 *   →  session B (Codex, a *different* agent) asks why, over MCP
 *   →  it gets the answer.
 *
 * Both agents are stubbed at the transcript boundary rather than actually run,
 * so this proves the wiring — path derivation, parsing, storage, retrieval —
 * without a network call. `scripts/e2e-live.ts` runs the same scenario against
 * the real CLIs.
 */

let db: Database;
let repo: string;
let fakeHome: string;
const created: string[] = [];

beforeEach(() => {
  db = openDb({ path: ":memory:" });
  repo = mkdtempSync(join(tmpdir(), "oma-e2e-repo-"));
  fakeHome = mkdtempSync(join(tmpdir(), "oma-e2e-home-"));
  created.push(repo, fakeHome);
});

afterEach(() => {
  while (created.length) rmSync(created.pop()!, { recursive: true, force: true });
});

/** Writes a Claude-format transcript exactly where Claude would write it. */
function writeClaudeTranscript(
  cwd: string,
  sessionId: string,
  lines: unknown[],
): string {
  const path = claudeTranscriptPath(cwd, sessionId, fakeHome);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, lines.map((l) => `${JSON.stringify(l)}\n`).join(""));
  return path;
}

function claudeTurn(
  role: "user" | "assistant",
  text: string,
  cwd: string,
  sessionId: string,
): unknown {
  return {
    type: role,
    sessionId,
    cwd,
    gitBranch: "main",
    timestamp: new Date().toISOString(),
    message:
      role === "assistant"
        ? { role, content: [{ type: "text", text }] }
        : { role, content: text },
  };
}

async function connectAs(repoPath: string, sessionId?: string): Promise<Client> {
  const server = createMemoryServer({ db, repoPath, sessionId });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "agent", version: "0" });
  await Promise.all([
    server.connect(serverTransport),
    client.connect(clientTransport),
  ]);
  return client;
}

function textOf(result: unknown): string {
  return (result as { content: Array<{ text?: string }> }).content
    .map((c) => c.text ?? "")
    .join("\n");
}

describe("M1: what session A learns, session B finds", () => {
  test("a decision made by Claude is recalled by a later Codex session", async () => {
    // --- Session A: Claude, working in the repo ---------------------------
    const sessionA = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
      title: "pick a queue",
    });
    const nativeId = "aaaaaaaa-1111-2222-3333-444444444444";
    const transcript = writeClaudeTranscript(repo, nativeId, [
      claudeTurn("user", "Which queue should we use?", repo, nativeId),
      claudeTurn(
        "assistant",
        "We use Redis Streams rather than RabbitMQ, because the ops surface is " +
          "already there and we need replay of the last hour.",
        repo,
        nativeId,
      ),
    ]);

    const runA = createAgentRun(db, {
      session_id: sessionA.id,
      agent: "claude",
      native_session_id: nativeId,
      transcript_path: transcript,
    });

    // Session A ends; its transcript is ingested.
    const report = ingestRun(db, runA);
    expect(report?.inserted).toBe(2);

    // --- Session B: Codex, a different agent, same repo -------------------
    const sessionB = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
      title: "wire up the consumer",
    });
    const agentB = await connectAs(repo, sessionB.id);

    const answer = textOf(
      await agentB.callTool({
        name: "memory_search",
        arguments: { query: "which queue do we use and why?" },
      }),
    );

    expect(answer).toContain("Redis Streams");
    expect(answer).toContain("replay of the last hour");
    // Provenance: session B can see this came from an earlier Claude session.
    expect(answer).toContain("claude");
  });

  test("a promoted decision outranks the raw transcript line it came from", async () => {
    const sessionA = createSession(db, { repo_path: repo, worktree_path: repo });
    const nativeId = "bbbbbbbb-1111-2222-3333-444444444444";
    const transcript = writeClaudeTranscript(repo, nativeId, [
      claudeTurn("assistant", "maybe we should use Redis Streams", repo, nativeId),
    ]);
    const runA = createAgentRun(db, {
      session_id: sessionA.id,
      agent: "claude",
      native_session_id: nativeId,
      transcript_path: transcript,
    });
    ingestRun(db, runA);

    // Promotion is a trusted CLI workflow, not an agent-callable MCP mutation.
    createMemory(db, {
      kind: "decision",
      repo_path: repo,
      title: "Redis Streams for the event queue",
      body: "RabbitMQ was rejected: we need replay, and ops already run Redis.",
      confidence: 0.9,
      source_session_id: sessionA.id,
    });

    const agentB = await connectAs(repo);
    const answer = textOf(
      await agentB.callTool({
        name: "memory_search",
        arguments: { query: "Redis Streams" },
      }),
    );

    // Curated memory comes first, so a limited context window sees it first.
    expect(answer.indexOf("[decision]")).toBeLessThan(answer.indexOf("transcript"));
  });

  test("knowledge does not leak into an unrelated repository", async () => {
    const sessionA = createSession(db, { repo_path: repo, worktree_path: repo });
    createMemory(db, {
      kind: "decision",
      repo_path: repo,
      title: "Redis Streams for the event queue",
      body: "Specific to this service.",
      source_session_id: sessionA.id,
    });

    const elsewhere = await connectAs("/some/other/repo");
    const answer = textOf(
      await elsewhere.callTool({
        name: "memory_search",
        arguments: { query: "Redis Streams" },
      }),
    );
    expect(answer).toContain("No memory found");
  });

  test("re-ingesting a session that has grown adds only the new turns", async () => {
    const session = createSession(db, { repo_path: repo, worktree_path: repo });
    const nativeId = "cccccccc-1111-2222-3333-444444444444";
    const turns = [
      claudeTurn("user", "first question", repo, nativeId),
      claudeTurn("assistant", "first answer", repo, nativeId),
    ];
    const transcript = writeClaudeTranscript(repo, nativeId, turns);
    const run = createAgentRun(db, {
      session_id: session.id,
      agent: "claude",
      native_session_id: nativeId,
      transcript_path: transcript,
    });

    expect(ingestRun(db, run)?.inserted).toBe(2);
    expect(ingestRun(db, run)?.inserted).toBe(0);

    // The agent keeps working and the transcript grows.
    writeClaudeTranscript(repo, nativeId, [
      ...turns,
      claudeTurn("assistant", "a later decision about sharding", repo, nativeId),
    ]);
    expect(ingestRun(db, run)?.inserted).toBe(1);

    const agent = await connectAs(repo);
    const answer = textOf(
      await agent.callTool({
        name: "memory_search",
        arguments: { query: "sharding" },
      }),
    );
    expect(answer).toContain("a later decision about sharding");
  });
});
