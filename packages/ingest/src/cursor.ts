import { Database } from "bun:sqlite";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { NormalizedEvent } from "@oma/core";
import {
  asRecord,
  asString,
  emptyResult,
  seqFor,
  truncate,
  type ParseResult,
  type TranscriptParser,
} from "./types.ts";

/**
 * Cursor keeps a chat in `~/.cursor/chats/<workspaceHash>/<chatId>/`:
 *
 *   meta.json   title, cwd and createdAtMs, in plain JSON
 *   store.db    SQLite with `blobs(id, data)` and `meta(key, value)`
 *
 * The blobs are content-addressed and unordered. Messages are plain JSON, but
 * the conversation's order lives in a separate root blob - named by
 * `latestRootBlobId` in `meta` - which references each message blob by its raw
 * 32-byte id. That blob is protobuf-framed, so rather than decode a schema
 * Cursor never published, this scans it for the ids it already knows and reads
 * the order off their positions.
 *
 * None of this is a documented contract: it is the private store of a closed
 * CLI and a Cursor update may change it. The contract test in
 * `real-transcripts.test.ts` is what turns that into a loud failure rather
 * than a silent empty ingest.
 */

const WRITE_TOOLS = new Set(["Write", "StrReplace", "MultiEdit", "Edit"]);

interface Chat {
  agentId: string | null;
  rootBlobId: string | null;
}

function readStoreMeta(db: Database): Chat {
  const row = db
    .query<{ value: string | Uint8Array }, []>(
      "SELECT value FROM meta WHERE key = '0'",
    )
    .get();
  if (!row) return { agentId: null, rootBlobId: null };
  const raw =
    typeof row.value === "string"
      ? Buffer.from(row.value, "hex").toString("utf8")
      : Buffer.from(row.value).toString("utf8");
  const record = asRecord(JSON.parse(raw));
  return {
    agentId: asString(record?.agentId),
    rootBlobId: asString(record?.latestRootBlobId),
  };
}

/**
 * The order of first appearance inside the root blob. Ids that it does not
 * mention are attachments and index nodes, which carry no conversation.
 */
function orderedBlobIds(
  blobs: Map<string, Uint8Array>,
  rootBlobId: string | null,
): string[] {
  const root = rootBlobId ? blobs.get(rootBlobId) : undefined;
  if (!root) return [];
  const haystack = Buffer.from(root);
  const found: Array<{ at: number; id: string }> = [];
  for (const id of blobs.keys()) {
    if (id === rootBlobId) continue;
    const at = haystack.indexOf(Buffer.from(id, "hex"));
    if (at >= 0) found.push({ at, id });
  }
  return found.sort((a, b) => a.at - b.at).map((entry) => entry.id);
}

function messageOf(data: Uint8Array): Record<string, unknown> | null {
  if (data[0] !== 0x7b) return null; // not JSON: an image or an index node
  try {
    const value = asRecord(JSON.parse(Buffer.from(data).toString("utf8")));
    return value && typeof value.role === "string" ? value : null;
  } catch {
    return null;
  }
}

/** `content` is a bare string on the oldest messages and a part list since. */
function partsOf(content: unknown): Array<Record<string, unknown>> {
  if (typeof content === "string") {
    return content ? [{ type: "text", text: content }] : [];
  }
  if (!Array.isArray(content)) return [];
  return content.flatMap((part) => {
    const record = asRecord(part);
    return record ? [record] : [];
  });
}

export function parseCursorChat(chatDir: string): ParseResult {
  const storePath = join(chatDir, "store.db");
  if (!existsSync(storePath)) return emptyResult();

  let chat: Chat = { agentId: null, rootBlobId: null };
  const blobs = new Map<string, Uint8Array>();
  try {
    const db = new Database(storePath, { readonly: true });
    try {
      chat = readStoreMeta(db);
      for (const row of db
        .query<{ id: string; data: Uint8Array }, []>("SELECT id, data FROM blobs")
        .all()) {
        blobs.set(row.id, row.data);
      }
    } finally {
      db.close();
    }
  } catch {
    // Cursor may be mid-write, or the schema may have moved on. Either way an
    // empty read is recoverable: ingest re-reads the chat on the next sweep.
    return emptyResult();
  }

  const fileMeta = asRecord(
    (() => {
      try {
        return JSON.parse(readFileSync(join(chatDir, "meta.json"), "utf8"));
      } catch {
        return null;
      }
    })(),
  );
  const createdAt = fileMeta?.createdAtMs;
  const ts = new Date(
    typeof createdAt === "number" ? createdAt : 0,
  ).toISOString();

  const events: NormalizedEvent[] = [];
  const touchedFiles = new Set<string>();

  orderedBlobIds(blobs, chat.rootBlobId).forEach((id, index) => {
    const data = blobs.get(id);
    const message = data && messageOf(data);
    if (!message) return;
    // The system message is Cursor's own prompt, not this session's knowledge,
    // and it is large enough to crowd everything else out of extraction.
    if (message.role === "system") return;
    const fromUser = message.role === "user";
    let block = 0;

    for (const part of partsOf(message.content)) {
      const type = asString(part.type);

      if (type === "text") {
        const text = asString(part.text);
        if (!text) continue;
        events.push({
          seq: seqFor(index, block++),
          ts,
          role: fromUser ? "user" : "assistant",
          kind: "text",
          tool_name: null,
          text: truncate(text),
          raw: part,
        });
        continue;
      }

      if (type === "reasoning") {
        // Every reasoning part observed so far carries the provider's opaque
        // `signature` and an empty `text`: Cursor stores the receipt, not the
        // thinking. Handled anyway, in case a model ever returns it in clear.
        const text = asString(part.text);
        if (!text) continue;
        events.push({
          seq: seqFor(index, block++),
          ts,
          role: "assistant",
          kind: "thinking",
          tool_name: null,
          text: truncate(text),
          raw: part,
        });
        continue;
      }

      if (type === "tool-call") {
        const tool = asString(part.toolName);
        const args = asRecord(part.args) ?? {};
        const filePath = asString(args.path) ?? asString(args.file_path);
        if (tool && WRITE_TOOLS.has(tool) && filePath) touchedFiles.add(filePath);
        events.push({
          seq: seqFor(index, block++),
          ts,
          role: "assistant",
          kind: "tool_use",
          tool_name: tool,
          text: truncate(JSON.stringify(args)),
          raw: part,
        });
        continue;
      }

      if (type !== "tool-result") continue; // images carry no text to index
      const output = part.result;
      events.push({
        seq: seqFor(index, block++),
        ts,
        role: "user",
        kind: "tool_result",
        tool_name: asString(part.toolName),
        text: truncate(
          typeof output === "string" ? output : JSON.stringify(output ?? null),
        ),
        raw: part,
      });
    }
  });

  return {
    events,
    meta: {
      nativeSessionId: chat.agentId,
      cwd: asString(fileMeta?.cwd),
      gitBranch: null,
      parentSessionId: null,
    },
    touchedFiles: [...touchedFiles],
    skippedLines: 0,
  };
}

export const cursorParser: TranscriptParser = {
  agent: "cursor",
  readEvents: parseCursorChat,
};
