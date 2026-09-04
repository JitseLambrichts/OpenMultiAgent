import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type {
  AgentAdapter,
  HeadlessOptions,
  Launch,
  LaunchContext,
  McpServerSpec,
  ResolveContext,
} from "@oma/core";
import { exec, omaHome } from "@oma/core";

const BINARY = "gemini";

/** Write a session-only system settings file, leaving user settings untouched. */
export function writeGeminiSettings(
  sessionId: string,
  servers: McpServerSpec[],
): string {
  const path = join(omaHome(), "gemini", sessionId, "settings.json");
  mkdirSync(dirname(path), { recursive: true });
  const mcpServers = Object.fromEntries(
    servers.map((server) => [
      server.name,
      {
        command: server.command,
        args: server.args,
        ...(server.env ? { env: server.env } : {}),
        trust: true,
      },
    ]),
  );
  writeFileSync(
    path,
    `${JSON.stringify(
      {
        mcpServers,
        mcp: {
          allowed: servers.map((server) => server.name),
          autoAllowInHeadless: true,
        },
      },
      null,
      2,
    )}\n`,
  );
  return path;
}

interface Candidate {
  path: string;
  mtimeMs: number;
}

function transcriptCandidates(root: string): Candidate[] {
  if (!existsSync(root)) return [];
  const candidates: Candidate[] = [];
  const walk = (dir: string, depth: number): void => {
    if (depth > 4) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path, depth + 1);
      else if (
        entry.name.startsWith("session-") &&
        (entry.name.endsWith(".json") || entry.name.endsWith(".jsonl"))
      ) {
        candidates.push({ path, mtimeMs: statSync(path).mtimeMs });
      }
    }
  };
  walk(root, 0);
  return candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
}

function transcriptSessionId(path: string): string | null {
  try {
    const content = readFileSync(path, "utf8");
    const first = path.endsWith(".jsonl")
      ? content.split("\n", 1)[0]
      : content;
    if (!first) return null;
    const value = JSON.parse(first) as { sessionId?: unknown };
    return typeof value.sessionId === "string" ? value.sessionId : null;
  } catch {
    return null;
  }
}

export const geminiAdapter: AgentAdapter = {
  name: "gemini",
  binary: BINARY,
  supportsNativeFork: false,

  async isAvailable() {
    return (await exec(["which", BINARY])).code === 0;
  },

  buildLaunch(ctx: LaunchContext): Launch {
    const command = [BINARY];
    const nativeSessionId = ctx.resumeNativeSessionId ?? randomUUID();
    if (ctx.resumeNativeSessionId) {
      command.push("--resume", ctx.resumeNativeSessionId);
    } else {
      command.push("--session-id", nativeSessionId);
    }

    const writtenFiles: string[] = [];
    let env: Record<string, string> | undefined;
    if (ctx.mcpServers?.length) {
      const settingsPath = writeGeminiSettings(ctx.sessionId, ctx.mcpServers);
      writtenFiles.push(settingsPath);
      env = { GEMINI_CLI_SYSTEM_SETTINGS_PATH: settingsPath };
      command.push(
        "--allowed-mcp-server-names",
        ...ctx.mcpServers.map((server) => server.name),
      );
    }

    const prompt = [ctx.systemPrompt, ctx.prompt]
      .filter((part): part is string => Boolean(part))
      .join("\n\n");
    if (prompt) command.push("--prompt-interactive", prompt);

    return {
      command,
      env,
      nativeSessionId,
      transcriptPath: null,
      writtenFiles,
    };
  },

  async resolveTranscript(ctx: ResolveContext): Promise<string | null> {
    if (!ctx.nativeSessionId) return null;
    const root = join(
      process.env.GEMINI_CLI_HOME ?? join(homedir(), ".gemini"),
      "tmp",
    );
    const floor = ctx.startedAt.getTime() - 1_000;
    for (const candidate of transcriptCandidates(root)) {
      if (candidate.mtimeMs < floor) break;
      if (transcriptSessionId(candidate.path) === ctx.nativeSessionId) {
        return candidate.path;
      }
    }
    return null;
  },

  headlessCommand(opts: HeadlessOptions): string[] {
    return [
      BINARY,
      ...(opts.json ? ["--output-format", "json"] : []),
      "--prompt",
      opts.prompt,
    ];
  },
};
