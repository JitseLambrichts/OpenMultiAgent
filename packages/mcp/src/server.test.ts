import { beforeEach, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import type { Database } from "bun:sqlite";
import {
  createAgentRun,
  createMemory,
  createSession,
  insertEvents,
  openDb,
} from "@oma/core";
import { createMemoryServer } from "./server.ts";

let db: Database;

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

async function connect(repoPath = "/repo", sessionId?: string): Promise<Client> {
  const server = createMemoryServer({ db, repoPath, sessionId });
  const [clientTransport, serverTransport] =
    InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "0" });
  await Promise.all([
    server.connect(serverTransport),
    client.connect(clientTransport),
  ]);
  return client;
}

function textOf(result: unknown): string {
  const content = (result as { content: Array<{ text?: string }> }).content;
  return content.map((c) => c.text ?? "").join("\n");
}

describe("oma memory MCP server", () => {
  test("advertises the tools an agent needs", async () => {
    const client = await connect();
    const names = (await client.listTools()).tools.map((t) => t.name);
    expect(names).toEqual(["memory_search"]);
  });

  test("memory_search answers a natural-language question with provenance", async () => {
    const session = createSession(db, {
      repo_path: "/repo",
      worktree_path: "/repo",
    });
    createMemory(db, {
      kind: "decision",
      repo_path: "/repo",
      title: "Memory search uses SQLite FTS5",
      body: "Chosen over a vector index because it is offline, free and dependency-free.",
      confidence: 0.9,
      source_session_id: session.id,
    });

    const client = await connect();
    const text = textOf(
      await client.callTool({
        name: "memory_search",
        arguments: { query: "why FTS5 instead of a vector index?" },
      }),
    );

    expect(text).toContain("SQLite FTS5");
    expect(text).toContain("[decision]");
    expect(text).toContain("confidence 0.90");
    expect(text).toContain(session.id.slice(0, 8));
  });

  test("memory_search reaches into transcripts of earlier sessions", async () => {
    const session = createSession(db, {
      repo_path: "/repo",
      worktree_path: "/repo",
    });
    const run = createAgentRun(db, { session_id: session.id, agent: "codex" });
    insertEvents(db, session.id, run.id, [
      {
        seq: 0,
        ts: "2026-08-11T10:00:00.000Z",
        role: "assistant",
        kind: "text",
        tool_name: null,
        text: "We picked tmux so sessions survive a daemon restart.",
        raw: null,
      },
    ]);

    const client = await connect();
    const text = textOf(
      await client.callTool({
        name: "memory_search",
        arguments: { query: "tmux" },
      }),
    );
    expect(text).toContain("transcript · codex");
    expect(text).toContain("survive a daemon restart");
  });

  test("include_transcripts=false returns curated memory only", async () => {
    const session = createSession(db, {
      repo_path: "/repo",
      worktree_path: "/repo",
    });
    const run = createAgentRun(db, { session_id: session.id, agent: "claude" });
    insertEvents(db, session.id, run.id, [
      {
        seq: 0,
        ts: "2026-08-11T10:00:00.000Z",
        role: "assistant",
        kind: "text",
        tool_name: null,
        text: "tmux tmux tmux",
        raw: null,
      },
    ]);

    const client = await connect();
    const text = textOf(
      await client.callTool({
        name: "memory_search",
        arguments: { query: "tmux", include_transcripts: false },
      }),
    );
    expect(text).toContain("No memory found");
  });

  test("says so plainly when it knows nothing", async () => {
    const client = await connect();
    const text = textOf(
      await client.callTool({
        name: "memory_search",
        arguments: { query: "kubernetes ingress" },
      }),
    );
    expect(text).toContain("No memory found");
  });

});
