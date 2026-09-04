import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { codexSessionsDir, exec } from "@oma/core";
import type {
  AgentAdapter,
  HeadlessOptions,
  Launch,
  LaunchContext,
  McpServerSpec,
  ResolveContext,
} from "@oma/core";

const BINARY = "codex";

/**
 * Codex has no project-scoped MCP file; servers live in
 * `~/.codex/config.toml`. Passing them as `-c` overrides gives per-session MCP
 * access without editing the user's global config.
 */
export function mcpConfigArgs(servers: McpServerSpec[]): string[] {
  return servers.flatMap((s) => [
    "-c",
    `mcp_servers.${s.name}.command=${JSON.stringify(s.command)}`,
    "-c",
    `mcp_servers.${s.name}.args=${JSON.stringify(s.args)}`,
    // Codex's default startup window is tight for a server that has to boot a
    // runtime and open the database; a server that times out is silently absent.
    "-c",
    `mcp_servers.${s.name}.startup_timeout_sec=${MCP_STARTUP_TIMEOUT_SEC}`,
    ...(s.env
      ? Object.entries(s.env).flatMap(([k, v]) => [
          "-c",
          `mcp_servers.${s.name}.env.${k}=${JSON.stringify(v)}`,
        ])
      : []),
  ]);
}

const MCP_STARTUP_TIMEOUT_SEC = 30;

interface RolloutCandidate {
  path: string;
  mtimeMs: number;
}

function listRollouts(dir: string): RolloutCandidate[] {
  if (!existsSync(dir)) return [];
  const out: RolloutCandidate[] = [];

  // Layout is YYYY/MM/DD/rollout-*.jsonl — a fixed depth of three.
  const walk = (current: string, depth: number): void => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name);
      if (entry.isDirectory()) {
        if (depth < 3) walk(path, depth + 1);
      } else if (entry.name.startsWith("rollout-") && entry.name.endsWith(".jsonl")) {
        out.push({ path, mtimeMs: statSync(path).mtimeMs });
      }
    }
  };

  walk(dir, 0);
  return out.sort((a, b) => b.mtimeMs - a.mtimeMs);
}

/** Reads only the `session_meta` line, which Codex always writes first. */
function rolloutMeta(path: string): { cwd: string | null; id: string | null } {
  try {
    const firstLine = readFileSync(path, "utf8").split("\n", 1)[0];
    if (!firstLine) return { cwd: null, id: null };
    const parsed = JSON.parse(firstLine) as {
      type?: string;
      payload?: { cwd?: string };
    };
    if (parsed.type !== "session_meta") return { cwd: null, id: null };
    const payload = parsed.payload as
      | { cwd?: string; id?: string; session_id?: string }
      | undefined;
    return {
      cwd: payload?.cwd ?? null,
      id: payload?.id ?? payload?.session_id ?? null,
    };
  } catch {
    return { cwd: null, id: null };
  }
}

export const codexAdapter: AgentAdapter = {
  name: "codex",
  binary: BINARY,
  supportsNativeFork: true,

  async isAvailable() {
    return (await exec(["which", BINARY])).code === 0;
  },

  buildLaunch(ctx: LaunchContext): Launch {
    const command = [BINARY];

    if (ctx.forkNativeSessionId) {
      command.push("fork", ctx.forkNativeSessionId);
    } else if (ctx.resumeNativeSessionId) {
      command.push("resume", ctx.resumeNativeSessionId);
    }

    command.push("-C", ctx.cwd);

    if (ctx.mcpServers?.length) {
      command.push(...mcpConfigArgs(ctx.mcpServers));
    }

    // Codex has no `--append-system-prompt`. The Handoff Brief is prepended to
    // the prompt instead — the same information, delivered the only way this
    // CLI accepts it.
    const prompt = [ctx.systemPrompt, ctx.prompt]
      .filter((part): part is string => Boolean(part))
      .join("\n\n");
    if (prompt) command.push(prompt);

    return {
      command,
      // Codex picks its own id; it is discovered afterwards from the rollout.
      nativeSessionId: null,
      transcriptPath: null,
      writtenFiles: [],
    };
  },

  /**
   * With no way to pin the id, the run is identified by matching
   * `session_meta.cwd` against the worktree and requiring the file to be newer
   * than the launch. Because each OMA session gets its own worktree path, the
   * cwd match is what makes this reliable; the mtime bound only guards against
   * adopting an older run in the same directory.
   *
   * Two Codex launches in the *same* directory within the same instant would
   * still be ambiguous, which is why `SessionManager` serialises Codex starts.
   */
  async resolveTranscript(ctx: ResolveContext): Promise<string | null> {
    const target = resolve(ctx.cwd);
    // One second of slack: mtime granularity and clock skew are both real.
    const floor = ctx.startedAt.getTime() - 1000;

    for (const candidate of listRollouts(codexSessionsDir())) {
      if (candidate.mtimeMs < floor) break; // sorted newest-first
      const meta = rolloutMeta(candidate.path);
      if (meta.id === ctx.excludeNativeSessionId) continue;
      if (meta.cwd && resolve(meta.cwd) === target) return candidate.path;
    }
    return null;
  },

  headlessCommand(opts: HeadlessOptions): string[] {
    return [
      BINARY,
      "exec",
      "-C",
      opts.cwd,
      ...(opts.json ? ["--json"] : []),
      opts.prompt,
    ];
  },
};
