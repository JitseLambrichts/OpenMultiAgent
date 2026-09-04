#!/usr/bin/env bun
/**
 * Deterministic JSON-RPC sidecar for UI tests. Speaks the same newline-delimited
 * protocol as @oma/desktop-api but answers from in-memory fixtures, so the UI
 * flow can be exercised without tmux, Git, or an agent CLI.
 */
const project = {
  id: "project-1",
  repo_path: "/Users/example/OpenMultiAgent",
  display_name: "OpenMultiAgent",
  created_at: "2026-08-11T10:00:00.000Z",
  last_opened_at: "2026-08-11T11:00:00.000Z",
};

const session = {
  session: {
    id: "session-1",
    repo_path: project.repo_path,
    worktree_path: `${project.repo_path}/.worktrees/m4`,
    branch: "oma/m4",
    title: "M4",
    status: "ended",
    started_at: "2026-08-11T10:00:00.000Z",
    ended_at: "2026-08-11T12:00:00.000Z",
  },
  runs: [
    {
      id: "run-1",
      session_id: "session-1",
      agent: "claude",
      native_session_id: "native-1",
      transcript_path: null,
      started_at: "2026-08-11T10:00:00.000Z",
      ended_at: "2026-08-11T12:00:00.000Z",
    },
  ],
  tmux_alive: false,
};

let extracted = false;

// Optional trace for debugging the launch path (FIXTURE_LOG=/path).
import { appendFileSync } from "node:fs";
const logPath = process.env.FIXTURE_LOG;
function log(message: string): void {
  if (logPath) appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`);
}
log(`start pid=${process.pid} cwd=${process.cwd()} argv=${process.argv.join(" ")}`);
process.on("uncaughtException", (error) => log(`uncaught ${String(error)}`));
process.on("exit", (code) => log(`exit ${code}`));

function result(method: string, params: Record<string, unknown>): unknown {
  switch (method) {
    case "system.hello":
      return { protocol_version: 1, app_version: "fixture", agents: ["claude", "codex", "gemini"] };
    case "system.health":
      return { ok: true, tmux_available: true };
    case "system.shutdown":
      return { shutting_down: true };
    case "project.list":
      return [project];
    case "project.detail":
      return { project, sessions: [session] };
    case "session.list":
      return [session];
    case "session.status":
      return {
        ...session,
        changed_files: [{ path: "README.md", status: "M" }],
        diff_stat: " README.md | 1 +",
        pane: "",
      };
    case "memory.list":
      return [];
    case "memory.search":
      return [];
    case "docs.list":
      return [];
    case "transcript.list":
      return { items: [], next_cursor: null };
    case "promotion.extract":
      extracted = true;
      return { candidate_count: 1 };
    case "promotion.preview":
      return extracted
        ? { diff: "--- .oma/docs/decisions.md\n+++ .oma/docs/decisions.md\n@@ -1,0 +1,1 @@\n+- Use native SwiftUI", candidate_count: 1 }
        : { diff: "No pending knowledge candidates.", candidate_count: 0 };
    case "promotion.apply":
      return { promoted: 1, files: [`${project.repo_path}/.oma/docs/decisions.md`] };
    case "terminal.attachment":
      return { executable: "/usr/bin/true", arguments: [], cwd: "/" };
    default:
      throw new Error(`unsupported ${method}`);
  }
}

let buffer = "";
// `process.stdin` events, not `Bun.stdin.stream()`: the latter only yields
// piped input after EOF on Bun 1.2, which would stall the app's first request.
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  log(`data ${JSON.stringify(chunk)}`);
  buffer += chunk;
  const lines = buffer.split("\n");
  buffer = lines.pop() ?? "";
  for (const line of lines) {
    if (!line.trim()) continue;
    const request = JSON.parse(line) as { id?: number; method: string; params?: Record<string, unknown> };
    let response: unknown;
    try {
      response = { jsonrpc: "2.0", id: request.id ?? null, result: result(request.method, request.params ?? {}) };
    } catch (error) {
      response = {
        jsonrpc: "2.0",
        id: request.id ?? null,
        error: { code: -32601, message: error instanceof Error ? error.message : String(error) },
      };
    }
    const written = process.stdout.write(`${JSON.stringify(response)}\n`);
    log(`wrote ${request.method} flushed=${written}`);
    if (request.method === "system.shutdown") process.exit(0);
  }
});
process.stdin.on("end", () => process.exit(0));
// Bun 1.2 caches process.ppid; probe the startup parent with signal 0 instead.
const initialParent = process.ppid;
setInterval(() => {
  try {
    process.kill(initialParent, 0);
  } catch {
    process.exit(0);
  }
}, 2000).unref?.();
process.stdin.on("error", (error) => log(`stdin error ${String(error)}`));
process.stdin.resume();
log("listening");
