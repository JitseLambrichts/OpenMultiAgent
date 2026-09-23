import { Database } from "bun:sqlite";
import { afterAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseCursorChat } from "./cursor.ts";

const dirs: string[] = [];
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

function sha256(value: Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}

/**
 * Rebuilds what Cursor writes: a content-addressed blob store whose ordering
 * lives in a separate root blob that references the message blobs by their raw
 * 32-byte id. The framing bytes around those ids are protobuf in the real
 * thing; the parser only cares where the ids sit, so the fixture pads with
 * arbitrary bytes to prove that.
 */
function buildChat(
  messages: unknown[],
  meta: Record<string, unknown> = {},
): string {
  const dir = mkdtempSync(join(tmpdir(), "oma-cursor-"));
  dirs.push(dir);

  const blobs = messages.map((message) => {
    const data = new TextEncoder().encode(JSON.stringify(message));
    return { id: sha256(data), data };
  });

  const framing = new Uint8Array([0x0a, 0xb2, 0x01, 0x0a]);
  const chunks: number[] = [];
  for (const blob of blobs) {
    chunks.push(...framing, ...Buffer.from(blob.id, "hex"));
  }
  const rootData = new Uint8Array(chunks);
  const rootId = sha256(rootData);

  const db = new Database(join(dir, "store.db"));
  db.run("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)");
  db.run("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)");
  for (const blob of blobs) {
    db.run("INSERT INTO blobs (id, data) VALUES (?, ?)", [blob.id, blob.data]);
  }
  db.run("INSERT INTO blobs (id, data) VALUES (?, ?)", [rootId, rootData]);
  db.run("INSERT INTO meta (key, value) VALUES ('0', ?)", [
    Buffer.from(
      JSON.stringify({ agentId: "chat-uuid", latestRootBlobId: rootId }),
    ).toString("hex"),
  ]);
  db.close();

  writeFileSync(
    join(dir, "meta.json"),
    JSON.stringify({
      schemaVersion: 1,
      createdAtMs: 1788610719390,
      title: "Terminal Warning",
      cwd: "/Users/dev/Projects/Demo",
      ...meta,
    }),
  );
  return dir;
}

const CHAT = buildChat([
  { role: "system", content: "You are an AI coding assistant." },
  { role: "user", content: "Implement the queue consumer" },
  {
    role: "assistant",
    id: "a1",
    content: [
      { type: "reasoning", text: "Delivery is at-least-once, so dedupe." },
      { type: "text", text: "I will update the worker." },
      {
        type: "tool-call",
        toolCallId: "c1",
        toolName: "Write",
        args: { path: "/Users/dev/Projects/Demo/src/worker.ts", contents: "x" },
      },
      {
        type: "tool-call",
        toolCallId: "c2",
        toolName: "Read",
        args: { path: "/Users/dev/Projects/Demo/src/queue.ts" },
      },
    ],
  },
  {
    role: "tool",
    id: "t1",
    content: [
      {
        type: "tool-result",
        toolCallId: "c1",
        toolName: "Write",
        result: "Wrote 1 file.",
      },
    ],
  },
]);

describe("parseCursorChat", () => {
  const result = parseCursorChat(CHAT);

  test("recovers the chat id and cwd", () => {
    expect(result.meta.nativeSessionId).toBe("chat-uuid");
    expect(result.meta.cwd).toBe("/Users/dev/Projects/Demo");
  });

  test("replays the conversation in the order the root blob records", () => {
    expect(
      result.events.map((event) => [event.role, event.kind, event.tool_name]),
    ).toEqual([
      ["user", "text", null],
      ["assistant", "thinking", null],
      ["assistant", "text", null],
      ["assistant", "tool_use", "Write"],
      ["assistant", "tool_use", "Read"],
      ["user", "tool_result", "Write"],
    ]);
  });

  test("leaves the system prompt out, since it is the tool's, not the session's", () => {
    expect(result.events.some((event) => event.role === "system")).toBe(false);
    expect(
      result.events.some((event) => event.text.includes("coding assistant")),
    ).toBe(false);
  });

  test("keeps the text of every kind searchable", () => {
    const texts = result.events.map((event) => event.text);
    expect(texts).toContain("Implement the queue consumer");
    expect(texts).toContain("I will update the worker.");
    expect(texts.some((t) => t.includes("at-least-once"))).toBe(true);
    expect(texts.some((t) => t.includes("worker.ts"))).toBe(true);
    expect(texts).toContain("Wrote 1 file.");
  });

  test("collects only files a writing tool touched", () => {
    expect(result.touchedFiles).toEqual([
      "/Users/dev/Projects/Demo/src/worker.ts",
    ]);
  });

  test("dates every event from the chat, which records no per-message time", () => {
    const expected = new Date(1788610719390).toISOString();
    expect(result.events.every((event) => event.ts === expected)).toBe(true);
  });

  test("a chat directory without a store reads as empty, never as a throw", () => {
    const empty = parseCursorChat(join(tmpdir(), "oma-cursor-does-not-exist"));
    expect(empty.events).toEqual([]);
    expect(empty.meta.nativeSessionId).toBeNull();
  });

  test("a store whose root blob is missing yields no events, not a wrong order", () => {
    const dir = buildChat([{ role: "user", content: "hi" }]);
    const db = new Database(join(dir, "store.db"));
    const root = JSON.parse(
      Buffer.from(
        db.query<{ value: string }, []>("SELECT value FROM meta WHERE key='0'").get()
          ?.value ?? "",
        "hex",
      ).toString(),
    );
    db.run("DELETE FROM blobs WHERE id = ?", [root.latestRootBlobId]);
    db.close();

    const parsed = parseCursorChat(dir);
    expect(parsed.events).toEqual([]);
    expect(parsed.meta.nativeSessionId).toBe("chat-uuid");
  });
});
