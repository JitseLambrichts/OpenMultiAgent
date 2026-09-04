import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseClaudeTranscript } from "./claude.ts";
import { BLOCKS_PER_LINE, MAX_TEXT_LENGTH } from "./types.ts";

const FIXTURE = readFileSync(
  join(import.meta.dir, "../../../testdata/transcripts/claude-sample.jsonl"),
  "utf8",
);

describe("parseClaudeTranscript", () => {
  const result = parseClaudeTranscript(FIXTURE);

  test("recovers session metadata from the first line that carries it", () => {
    expect(result.meta.nativeSessionId).toBe(
      "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    );
    expect(result.meta.cwd).toBe("/Users/dev/Projects/Demo");
    expect(result.meta.gitBranch).toBe("main");
  });

  test("reads a bare-string user turn", () => {
    const first = result.events[0]!;
    expect(first.role).toBe("user");
    expect(first.kind).toBe("text");
    expect(first.text).toContain("tmux");
  });

  test("splits an assistant message into one event per content block", () => {
    const kinds = result.events.map((e) => e.kind);
    expect(kinds).toContain("thinking");
    expect(kinds).toContain("text");
    expect(kinds).toContain("tool_use");
    expect(kinds).toContain("tool_result");
  });

  test("keeps tool input searchable and records the tool name", () => {
    const bash = result.events.find((e) => e.tool_name === "Bash");
    expect(bash?.text).toContain("bun test");
  });

  test("flattens a tool_result whose content is a block array", () => {
    const results = result.events.filter((e) => e.kind === "tool_result");
    expect(results.map((e) => e.text)).toContain("12 pass 0 fail");
  });

  test("collects written files from write tools and history snapshots", () => {
    expect(result.touchedFiles).toContain("/Users/dev/Projects/Demo/src/session.ts");
  });

  test("does not treat a read as a file change", () => {
    expect(result.touchedFiles).not.toContain("/Users/dev/Projects/Demo/README.md");
  });

  test("ignores unknown top-level event types without failing", () => {
    // The fixture contains a `telemetry-of-the-future` line.
    expect(result.events.every((e) => e.kind !== "meta")).toBe(true);
    expect(result.events.length).toBeGreaterThan(0);
  });

  test("counts a truncated trailing line as skipped instead of throwing", () => {
    expect(result.skippedLines).toBe(1);
  });

  test("assigns strictly increasing, line-anchored seq numbers", () => {
    const seqs = result.events.map((e) => e.seq);
    expect([...seqs].sort((a, b) => a - b)).toEqual(seqs);
    expect(new Set(seqs).size).toBe(seqs.length);
  });

  test("seq is stable when the transcript is appended to", () => {
    const half = FIXTURE.split("\n").slice(0, 5).join("\n");
    const partial = parseClaudeTranscript(half);
    const prefix = result.events.slice(0, partial.events.length);
    expect(partial.events.map((e) => e.seq)).toEqual(prefix.map((e) => e.seq));
  });

  test("blocks on the same line stay within that line's seq slot", () => {
    const line5 = result.events.filter(
      (e) => Math.floor(e.seq / BLOCKS_PER_LINE) === 4,
    );
    expect(line5.length).toBe(2); // Edit + Bash in one assistant message
  });

  test("caps event text so one huge tool result cannot dominate the index", () => {
    const huge = JSON.stringify({
      type: "assistant",
      timestamp: "2026-08-11T10:00:00.000Z",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "x".repeat(MAX_TEXT_LENGTH * 2) }],
      },
    });
    const capped = parseClaudeTranscript(huge);
    expect(capped.events[0]!.text.length).toBeLessThan(MAX_TEXT_LENGTH + 100);
    expect(capped.events[0]!.text).toEndWith("…[truncated]");
  });

  test("an empty transcript yields nothing rather than an error", () => {
    const empty = parseClaudeTranscript("");
    expect(empty.events).toEqual([]);
    expect(empty.skippedLines).toBe(0);
  });
});
