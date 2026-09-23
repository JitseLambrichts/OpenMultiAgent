import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { parseOpenCodeSession } from "./opencode.ts";

const SESSION = join(
  import.meta.dir,
  "../../../testdata/transcripts/opencode-storage/session/proj-demo/ses_demo.json",
);

describe("parseOpenCodeSession", () => {
  const result = parseOpenCodeSession(SESSION);

  test("recovers metadata from the session record", () => {
    expect(result.meta).toEqual({
      nativeSessionId: "ses_demo",
      cwd: "/Users/dev/Projects/Demo",
      gitBranch: null,
      parentSessionId: null,
    });
  });

  test("normalizes user and assistant text", () => {
    expect(
      result.events.map((event) => [event.role, event.kind, event.text]),
    ).toContainEqual(["user", "text", "Implement the queue consumer"]);
    expect(
      result.events.map((event) => [event.role, event.kind, event.text]),
    ).toContainEqual([
      "assistant",
      "text",
      "The consumer now dedupes on message id.",
    ]);
  });

  test("keeps reasoning, tool calls and their output searchable", () => {
    expect(
      result.events.some(
        (event) =>
          event.kind === "thinking" && event.text.includes("at-least-once"),
      ),
    ).toBe(true);
    expect(
      result.events.some(
        (event) =>
          event.kind === "tool_use" &&
          event.tool_name === "write" &&
          event.text.includes("worker.ts"),
      ),
    ).toBe(true);
    expect(
      result.events.some(
        (event) =>
          event.kind === "tool_result" &&
          event.text.includes("File written successfully."),
      ),
    ).toBe(true);
  });

  test("orders events by message and then by part", () => {
    expect(result.events.map((event) => event.seq)).toEqual(
      [...result.events.map((event) => event.seq)].sort((a, b) => a - b),
    );
    expect(result.events[0]?.text).toBe("Implement the queue consumer");
    expect(result.events.at(-1)?.text).toBe(
      "The consumer now dedupes on message id.",
    );
  });

  test("dates events from the part, falling back to its message", () => {
    const first = result.events[0];
    expect(first?.ts).toBe(new Date(1770980286849).toISOString());
    const write = result.events.find((event) => event.kind === "tool_use");
    expect(write?.ts).toBe(new Date(1770980291000).toISOString());
  });

  test("collects only files a write tool touched", () => {
    expect(result.touchedFiles).toEqual([
      "/Users/dev/Projects/Demo/src/worker.ts",
    ]);
  });

  test("skips bookkeeping parts without counting them as damage", () => {
    expect(
      result.events.some((event) => event.kind === "unknown"),
    ).toBe(false);
    // Only the truncated part is damage; step-start and step-finish are not.
    expect(result.skippedLines).toBe(1);
  });

  test("returns an empty result for a session file that is not there", () => {
    const missing = parseOpenCodeSession(
      join(import.meta.dir, "../../../testdata/transcripts/nope/ses_x.json"),
    );
    expect(missing.events).toEqual([]);
    expect(missing.meta.nativeSessionId).toBeNull();
  });
});
