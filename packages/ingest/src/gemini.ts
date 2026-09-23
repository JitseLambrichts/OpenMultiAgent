import type { NormalizedEvent } from "@oma/core";
import {
  asRecord,
  asString,
  parseLines,
  fromTranscriptFile,
  seqFor,
  truncate,
  type ParseResult,
  type TranscriptParser,
} from "./types.ts";

const WRITE_TOOLS = new Set(["write_file", "replace", "apply_patch"]);

function textContent(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value
    .map((part) =>
      typeof part === "string" ? part : (asString(asRecord(part)?.text) ?? ""),
    )
    .filter(Boolean)
    .join("\n");
}

function recordsFromTranscript(content: string): {
  meta: Record<string, unknown> | null;
  records: Array<{ index: number; value: Record<string, unknown> }>;
  skipped: number;
} {
  try {
    const whole = asRecord(JSON.parse(content));
    if (whole && Array.isArray(whole.messages)) {
      return {
        meta: whole,
        records: whole.messages.flatMap((message, index) => {
          const value = asRecord(message);
          return value ? [{ index: index + 1, value }] : [];
        }),
        skipped: 0,
      };
    }
  } catch {
    // Current Gemini transcripts are JSONL; fall through to tolerant parsing.
  }

  const parsed = parseLines(content);
  const header = parsed.lines.find(({ value }) => asString(value.sessionId));
  return {
    meta: header?.value ?? null,
    records: parsed.lines.filter(({ value }) => asString(value.type) !== null),
    skipped: parsed.skipped,
  };
}

export function parseGeminiTranscript(content: string): ParseResult {
  const { meta, records, skipped } = recordsFromTranscript(content);
  const events: NormalizedEvent[] = [];
  const touchedFiles = new Set<string>();

  for (const { index, value } of records) {
    const type = asString(value.type);
    if (type !== "user" && type !== "gemini") continue;
    const ts = asString(value.timestamp) ?? new Date(0).toISOString();
    const role = type === "user" ? "user" : "assistant";
    let block = 0;
    const text = textContent(value.content);
    if (text) {
      events.push({
        seq: seqFor(index, block++),
        ts,
        role,
        kind: "text",
        tool_name: null,
        text: truncate(text),
        raw: value,
      });
    }

    if (Array.isArray(value.thoughts)) {
      for (const rawThought of value.thoughts) {
        const thought = asRecord(rawThought);
        if (!thought) continue;
        const body = [asString(thought.subject), asString(thought.description)]
          .filter((part): part is string => Boolean(part))
          .join(": ");
        events.push({
          seq: seqFor(index, block++),
          ts: asString(thought.timestamp) ?? ts,
          role: "assistant",
          kind: "thinking",
          tool_name: null,
          text: truncate(body),
          raw: thought,
        });
      }
    }

    if (!Array.isArray(value.toolCalls)) continue;
    for (const rawCall of value.toolCalls) {
      const call = asRecord(rawCall);
      if (!call) continue;
      const name = asString(call.name);
      const args = asRecord(call.args) ?? {};
      const filePath =
        asString(args.file_path) ??
        asString(args.absolute_path) ??
        asString(args.path);
      if (name && WRITE_TOOLS.has(name) && filePath) touchedFiles.add(filePath);
      events.push({
        seq: seqFor(index, block++),
        ts: asString(call.timestamp) ?? ts,
        role: "assistant",
        kind: "tool_use",
        tool_name: name,
        text: truncate(JSON.stringify(args)),
        raw: call,
      });
      if (call.result !== undefined) {
        events.push({
          seq: seqFor(index, block++),
          ts: asString(call.timestamp) ?? ts,
          role: "user",
          kind: "tool_result",
          tool_name: name,
          text: truncate(
            typeof call.result === "string"
              ? call.result
              : JSON.stringify(call.result),
          ),
          raw: call.result,
        });
      }
    }
  }

  const directories = Array.isArray(meta?.directories) ? meta.directories : [];
  return {
    events,
    meta: {
      nativeSessionId: asString(meta?.sessionId),
      cwd: directories.map(asString).find(Boolean) ?? null,
      gitBranch: null,
      parentSessionId: null,
    },
    touchedFiles: [...touchedFiles],
    skippedLines: skipped,
  };
}

export const geminiParser: TranscriptParser = {
  agent: "gemini",
  readEvents: fromTranscriptFile(parseGeminiTranscript),
};
