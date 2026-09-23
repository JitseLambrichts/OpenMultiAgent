import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import type { EventRole, NormalizedEvent } from "@oma/core";
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
 * OpenCode does not write a transcript file. It keeps a content-addressed tree
 * under its storage directory, three levels of it:
 *
 *   storage/session/<projectID>/<sessionID>.json   the session record
 *   storage/message/<sessionID>/<messageID>.json   one file per turn
 *   storage/part/<messageID>/<partID>.json         text, reasoning and tools
 *
 * The session record is the entry point, so that is what `resolveTranscript`
 * hands us and what the rest of ingest stores as the transcript path.
 */

const WRITE_TOOLS = new Set(["write", "edit", "patch"]);

interface Damage {
  skipped: number;
}

function readRecord(
  path: string,
  damage: Damage,
): Record<string, unknown> | null {
  try {
    const value = asRecord(JSON.parse(readFileSync(path, "utf8")));
    if (value) return value;
  } catch {
    // A half-written file is routine while a session is still running.
  }
  damage.skipped++;
  return null;
}

/** Sorted so a re-parse of a grown session keeps every existing `seq`. */
function readDirectory(path: string): string[] {
  if (!existsSync(path)) return [];
  return readdirSync(path)
    .filter((name) => name.endsWith(".json"))
    .sort();
}

function epochMillis(value: unknown): number | null {
  const time = asRecord(value);
  for (const key of ["start", "created"]) {
    const found = time?.[key];
    if (typeof found === "number" && Number.isFinite(found)) return found;
  }
  return null;
}

function isoFrom(millis: number | null, fallback: string): string {
  return millis === null ? fallback : new Date(millis).toISOString();
}

function textOf(part: Record<string, unknown>): string {
  return asString(part.text) ?? "";
}

export function parseOpenCodeSession(sessionFile: string): ParseResult {
  if (!existsSync(sessionFile)) return emptyResult();
  const damage: Damage = { skipped: 0 };
  const session = readRecord(sessionFile, damage);
  const sessionId = asString(session?.id);
  if (!session || !sessionId) {
    return { ...emptyResult(), skippedLines: damage.skipped };
  }

  // storage/session/<projectID>/<file> -> storage
  const storage = resolve(dirname(sessionFile), "..", "..");
  const messageDir = join(storage, "message", sessionId);

  const messages = readDirectory(messageDir)
    .flatMap((name) => {
      const value = readRecord(join(messageDir, name), damage);
      return value ? [value] : [];
    })
    .sort((a, b) => {
      const byTime =
        (epochMillis(a.time) ?? 0) - (epochMillis(b.time) ?? 0);
      return byTime !== 0 ? byTime : (asString(a.id) ?? "").localeCompare(asString(b.id) ?? "");
    });

  const events: NormalizedEvent[] = [];
  const touchedFiles = new Set<string>();

  messages.forEach((message, index) => {
    const messageId = asString(message.id);
    if (!messageId) return;
    const role: EventRole = message.role === "user" ? "user" : "assistant";
    const messageTs = isoFrom(
      epochMillis(message.time),
      new Date(0).toISOString(),
    );
    const partDir = join(storage, "part", messageId);
    let block = 0;

    for (const name of readDirectory(partDir)) {
      const part = readRecord(join(partDir, name), damage);
      if (!part) continue;
      const type = asString(part.type);
      const ts = isoFrom(epochMillis(part.time), messageTs);

      if (type === "text") {
        const text = textOf(part);
        if (!text) continue;
        events.push({
          seq: seqFor(index, block++),
          ts,
          role,
          kind: "text",
          tool_name: null,
          text: truncate(text),
          raw: part,
        });
        continue;
      }

      if (type === "reasoning") {
        const text = textOf(part);
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

      if (type !== "tool") continue; // step-start and step-finish carry no content

      const tool = asString(part.tool);
      const state = asRecord(part.state) ?? {};
      const input = asRecord(state.input) ?? {};
      const filePath = asString(input.filePath) ?? asString(input.path);
      if (tool && WRITE_TOOLS.has(tool) && filePath) touchedFiles.add(filePath);
      const toolTs = isoFrom(epochMillis(state.time), ts);

      events.push({
        seq: seqFor(index, block++),
        ts: toolTs,
        role: "assistant",
        kind: "tool_use",
        tool_name: tool,
        text: truncate(JSON.stringify(input)),
        raw: part,
      });

      if (state.output === undefined) continue;
      events.push({
        seq: seqFor(index, block++),
        ts: toolTs,
        role: "user",
        kind: "tool_result",
        tool_name: tool,
        text: truncate(
          typeof state.output === "string"
            ? state.output
            : JSON.stringify(state.output),
        ),
        raw: state.output,
      });
    }
  });

  return {
    events,
    meta: {
      nativeSessionId: sessionId,
      cwd: asString(session.directory),
      gitBranch: null,
      parentSessionId: asString(session.parentID),
    },
    touchedFiles: [...touchedFiles],
    skippedLines: damage.skipped,
  };
}

export const opencodeParser: TranscriptParser = {
  agent: "opencode",
  readEvents: parseOpenCodeSession,
};
