import {
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import {
  claudeProjectDir,
  claudeTranscriptPath,
  exec,
  omaHome,
} from "@oma/core";
import type {
  AgentAdapter,
  HeadlessOptions,
  Launch,
  LaunchContext,
  McpServerSpec,
  ResolveContext,
} from "@oma/core";

const BINARY = "claude";

/** Claude chooses the new id for `--fork-session`; starts are serialized. */
export function findClaudeTranscript(
  cwd: string,
  startedAt: Date,
  home = homedir(),
  excludeNativeSessionId?: string | null,
): string | null {
  const directory = claudeProjectDir(cwd, home);
  if (!existsSync(directory)) return null;
  const floor = startedAt.getTime() - 1_000;
  const candidates = readdirSync(directory, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isFile() &&
        entry.name.endsWith(".jsonl") &&
        entry.name !== `${excludeNativeSessionId}.jsonl`,
    )
    .map((entry) => {
      const path = join(directory, entry.name);
      return { path, mtimeMs: statSync(path).mtimeMs };
    })
    .filter((candidate) => candidate.mtimeMs >= floor)
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
  return candidates[0]?.path ?? null;
}

/**
 * Keep OMA's MCP config outside the repository. Worktrees are optional, so a
 * project may already own `.mcp.json`; overwriting it would be data loss.
 */
export function writeMcpConfig(
  sessionId: string,
  servers: McpServerSpec[],
): string {
  const config = {
    mcpServers: Object.fromEntries(
      servers.map((s) => [
        s.name,
        { command: s.command, args: s.args, ...(s.env ? { env: s.env } : {}) },
      ]),
    ),
  };
  const path = join(omaHome(), "claude", sessionId, "mcp.json");
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`);
  return path;
}

export const claudeAdapter: AgentAdapter = {
  name: "claude",
  binary: BINARY,
  supportsNativeFork: true,

  async isAvailable() {
    return (await exec(["which", BINARY])).code === 0;
  },

  buildLaunch(ctx: LaunchContext): Launch {
    const writtenFiles: string[] = [];
    const command = [BINARY];

    // `--mcp-config` and `--allowedTools` are variadic, so they swallow any
    // bare argument that follows them — including the prompt. They therefore
    // go first, and a single-value flag always separates them from the prompt.
    if (ctx.mcpServers?.length) {
      const path = writeMcpConfig(ctx.sessionId, ctx.mcpServers);
      writtenFiles.push(path);
      // `--strict-mcp-config` is deliberately not used: the user's own MCP
      // servers should stay available inside an OMA session.
      command.push("--mcp-config", path);

      // Without this the agent is prompted before every memory lookup, and in
      // headless mode it cannot answer the prompt at all — memory then silently
      // does nothing. The grant is narrow: these servers are OMA's own, and
      // reach no further than the memory store.
      command.push(
        "--allowedTools",
        ...ctx.mcpServers.map((server) => `mcp__${server.name}`),
      );
    }

    if (ctx.systemPrompt) {
      command.push("--append-system-prompt", ctx.systemPrompt);
    }

    // Claude accepts the session id, which makes the transcript path
    // deterministic instead of something we have to race to discover. It is
    // also the single-value flag that terminates any variadic list above.
    const nativeSessionId = ctx.forkNativeSessionId
      ? null
      : (ctx.resumeNativeSessionId ?? randomUUID());
    if (ctx.forkNativeSessionId) {
      command.push("--resume", ctx.forkNativeSessionId, "--fork-session");
    } else if (ctx.resumeNativeSessionId) {
      command.push("--resume", ctx.resumeNativeSessionId);
    } else {
      command.push("--session-id", nativeSessionId!);
    }

    if (ctx.prompt) command.push(ctx.prompt);

    return {
      command,
      nativeSessionId,
      transcriptPath: nativeSessionId
        ? claudeTranscriptPath(ctx.cwd, nativeSessionId)
        : null,
      writtenFiles,
    };
  },

  async resolveTranscript(ctx: ResolveContext): Promise<string | null> {
    if (!ctx.nativeSessionId) {
      return findClaudeTranscript(
        ctx.cwd,
        ctx.startedAt,
        homedir(),
        ctx.excludeNativeSessionId,
      );
    }
    const path = claudeTranscriptPath(ctx.cwd, ctx.nativeSessionId);
    // The file appears only once Claude writes its first event, so a caller
    // polling right after launch will legitimately see null for a moment.
    return existsSync(path) ? path : null;
  },

  headlessCommand(opts: HeadlessOptions): string[] {
    return [
      BINARY,
      "-p",
      ...(opts.json ? ["--output-format", "json"] : []),
      opts.prompt,
    ];
  },
};
