import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseGeminiTranscript } from "./gemini.ts";

const FIXTURE = readFileSync(
  join(import.meta.dir, "../../../testdata/transcripts/gemini-sample.jsonl"),
  "utf8",
);

describe("parseGeminiTranscript", () => {
  const result = parseGeminiTranscript(FIXTURE);

  test("recovers metadata from the JSONL header", () => {
    expect(result.meta.nativeSessionId).toBe(
      "99999999-aaaa-bbbb-cccc-dddddddddddd",
    );
  });

  test("normalizes user and Gemini text", () => {
    expect(result.events.map((event) => [event.role, event.kind, event.text])).toContainEqual([
      "user",
      "text",
      "Implement the queue consumer",
    ]);
    expect(result.events.map((event) => [event.role, event.kind, event.text])).toContainEqual([
      "assistant",
      "text",
      "I will update the worker.",
    ]);
  });

  test("keeps thoughts, tool calls and results searchable", () => {
    expect(result.events.some((event) => event.kind === "thinking" && event.text.includes("at-least-once"))).toBe(true);
    expect(result.events.some((event) => event.kind === "tool_use" && event.tool_name === "write_file" && event.text.includes("worker.ts"))).toBe(true);
    expect(result.events.some((event) => event.kind === "tool_result" && event.text.includes("ok"))).toBe(true);
  });

  test("collects files changed through structured tools", () => {
    expect(result.touchedFiles).toEqual([
      "/Users/dev/Projects/Demo/src/worker.ts",
    ]);
  });

  test("ignores patch records and survives a truncated tail", () => {
    expect(result.skippedLines).toBe(1);
    expect(result.events.every((event) => event.kind !== "unknown")).toBe(true);
  });

  test("also accepts legacy whole-document chat files", () => {
    const legacy = JSON.stringify({
      sessionId: "legacy-id",
      messages: [
        { id: "u", timestamp: "2026-01-01T00:00:00Z", type: "user", content: [{ text: "hello" }] },
        { id: "g", timestamp: "2026-01-01T00:00:01Z", type: "gemini", content: "hi" },
      ],
    });
    const parsed = parseGeminiTranscript(legacy);
    expect(parsed.meta.nativeSessionId).toBe("legacy-id");
    expect(parsed.events.map((event) => event.text)).toEqual(["hello", "hi"]);
  });
});
