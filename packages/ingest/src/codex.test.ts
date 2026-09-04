import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseCodexTranscript } from "./codex.ts";

const FIXTURE = readFileSync(
  join(import.meta.dir, "../../../testdata/transcripts/codex-sample.jsonl"),
  "utf8",
);

describe("parseCodexTranscript", () => {
  const result = parseCodexTranscript(FIXTURE);

  test("recovers the native session id and cwd from session_meta", () => {
    expect(result.meta.nativeSessionId).toBe(
      "019ff1c2-1111-2222-3333-444455556666",
    );
    expect(result.meta.cwd).toBe("/Users/dev/Projects/Demo");
  });

  test("uses the rollout's own id, not the parent's, for a subagent thread", () => {
    // Verified against every rollout on disk: for `thread_source: subagent`,
    // `session_id` names the parent thread while `id` names this rollout.
    const line = JSON.stringify({
      timestamp: "2026-08-11T11:00:00.000Z",
      type: "session_meta",
      payload: {
        session_id: "parent-thread-id",
        id: "own-rollout-id",
        cwd: "/Users/dev/Projects/Demo",
        thread_source: "subagent",
        parent_thread_id: "parent-thread-id",
      },
    });
    const meta = parseCodexTranscript(line).meta;
    expect(meta.nativeSessionId).toBe("own-rollout-id");
    expect(meta.parentSessionId).toBe("parent-thread-id");
  });

  test("a normal user thread has no parent", () => {
    expect(result.meta.parentSessionId).toBeNull();
  });

  test("normalises the assistant answer", () => {
    const assistant = result.events.filter(
      (e) => e.role === "assistant" && e.kind === "text",
    );
    expect(assistant).toHaveLength(1);
    expect(assistant[0]!.text).toContain("FTS5");
  });

  test("marks the developer preamble as system, not as a user turn", () => {
    const users = result.events.filter(
      (e) => e.role === "user" && e.kind === "text",
    );
    expect(users).toHaveLength(1);
    expect(users[0]!.text).toContain("Which database");
  });

  test("does not double-index the agent_message event_msg echo", () => {
    const withFts5 = result.events.filter((e) =>
      e.text.includes("no extra dependency"),
    );
    expect(withFts5).toHaveLength(1);
  });

  test("handles both function_call and custom_tool_call argument shapes", () => {
    const calls = result.events.filter((e) => e.kind === "tool_use");
    expect(calls.map((e) => e.tool_name)).toEqual(["exec_command", "exec"]);
    expect(calls[0]!.text).toContain("grep -rn fts5");
    expect(calls[1]!.text).toContain("bun test");
  });

  test("captures both tool output shapes", () => {
    const outputs = result.events.filter((e) => e.kind === "tool_result");
    expect(outputs).toHaveLength(2);
    expect(outputs[1]!.text).toBe("14 pass 0 fail");
  });

  test("keeps the readable reasoning summary and drops encrypted content", () => {
    const thinking = result.events.find((e) => e.kind === "thinking");
    expect(thinking?.text).toBe("Recall the storage decision.");
  });

  test("survives an unknown top-level type and a truncated final line", () => {
    expect(result.skippedLines).toBe(1);
    expect(result.events.length).toBeGreaterThan(5);
  });

  test("seq is stable when the transcript is appended to", () => {
    const half = FIXTURE.split("\n").slice(0, 8).join("\n");
    const partial = parseCodexTranscript(half);
    const prefix = result.events.slice(0, partial.events.length);
    expect(partial.events.map((e) => e.seq)).toEqual(prefix.map((e) => e.seq));
  });
});
