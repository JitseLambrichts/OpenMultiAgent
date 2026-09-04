import { describe, expect, test } from "bun:test";
import { formatStatus } from "./format.ts";

describe("formatStatus", () => {
  test("shows agent chain, changed files and diff without requiring a UI", () => {
    const output = formatStatus({
      session: {
        id: "12345678-aaaa-bbbb-cccc-dddddddddddd",
        repo_path: "/repo",
        worktree_path: "/repo/.worktrees/task",
        branch: "oma/task",
        title: "Task",
        status: "active",
        started_at: "2026-08-11T10:00:00.000Z",
        ended_at: null,
      },
      runs: [
        {
          id: "r1",
          session_id: "12345678-aaaa-bbbb-cccc-dddddddddddd",
          agent: "claude",
          native_session_id: "c1",
          transcript_path: null,
          started_at: "2026-08-11T10:00:00.000Z",
          ended_at: "2026-08-11T10:01:00.000Z",
        },
        {
          id: "r2",
          session_id: "12345678-aaaa-bbbb-cccc-dddddddddddd",
          agent: "codex",
          native_session_id: "x1",
          transcript_path: null,
          started_at: "2026-08-11T10:01:00.000Z",
          ended_at: null,
        },
      ],
      tmuxAlive: true,
      changedFiles: [{ status: "M", path: "src/worker.ts" }],
      diffStat: "src/worker.ts | 4 ++--",
      pane: "working on retry logic",
    });

    expect(output).toContain("claude → codex");
    expect(output).toContain("src/worker.ts");
    expect(output).toContain("4 ++--");
    expect(output).toContain("working on retry logic");
  });
});
