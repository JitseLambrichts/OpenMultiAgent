import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  cursorChatsDir,
  exec,
  opencodeStorageDir,
  type CustomAgentDef,
} from "@oma/core";
import type {
  AgentAdapter,
  HeadlessOptions,
  Launch,
  LaunchContext,
  ResolveContext,
} from "@oma/core";

function basename(binary: string): string {
  return binary.split("/").at(-1) ?? binary;
}

function isOpencodeBinary(binary: string): boolean {
  return basename(binary) === "opencode";
}

/**
 * What a run wrote, and where. `locator` is what ingest stores and hands back
 * to the parser: a file for OpenCode's session record, a directory for a
 * Cursor chat.
 */
interface Conversation {
  locator: string;
  id: string;
  directory: string;
  created: number;
}

function readJson(path: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(readFileSync(path, "utf8"));
    return value && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function subdirectories(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root)
    .map((name) => join(root, name))
    .filter((path) => statSync(path).isDirectory());
}

/**
 * Neither OpenCode nor Cursor accepts a caller-chosen session id, so a run is
 * correlated the way Codex's is: the newest conversation recorded for this cwd
 * since the run started.
 */
function newestForCwd(
  conversations: Conversation[],
  ctx: ResolveContext,
): string | null {
  const target = resolve(ctx.cwd);
  // One second of slack: clock skew between OMA and the agent is real.
  const floor = ctx.startedAt.getTime() - 1000;
  let best: Conversation | null = null;

  for (const conversation of conversations) {
    if (conversation.id === ctx.excludeNativeSessionId) continue;
    if (conversation.created < floor) continue;
    if (resolve(conversation.directory) !== target) continue;
    if (!best || conversation.created > best.created) best = conversation;
  }

  return best?.locator ?? null;
}

/** `storage/session/<projectID>/<sessionID>.json`, one record per session. */
function opencodeConversations(): Conversation[] {
  const found: Conversation[] = [];
  for (const project of subdirectories(join(opencodeStorageDir(), "session"))) {
    for (const name of readdirSync(project)) {
      if (!name.endsWith(".json")) continue;
      const locator = join(project, name);
      const record = readJson(locator);
      const time = record?.time as Record<string, unknown> | undefined;
      if (typeof record?.id !== "string") continue;
      if (typeof record.directory !== "string") continue;
      found.push({
        locator,
        id: record.id,
        directory: record.directory,
        created: typeof time?.created === "number" ? time.created : 0,
      });
    }
  }
  return found;
}

/**
 * `chats/<workspaceHash>/<chatID>/`, with the cwd in `meta.json`. The chat
 * directory is the locator: the conversation itself is a SQLite store inside
 * it, which the parser opens.
 */
function cursorConversations(): Conversation[] {
  const found: Conversation[] = [];
  for (const workspace of subdirectories(cursorChatsDir())) {
    for (const chat of subdirectories(workspace)) {
      const record = readJson(join(chat, "meta.json"));
      if (typeof record?.cwd !== "string") continue;
      found.push({
        locator: chat,
        id: chat.split("/").at(-1) ?? chat,
        directory: record.cwd,
        created:
          typeof record.createdAtMs === "number" ? record.createdAtMs : 0,
      });
    }
  }
  return found;
}

const DISCOVERY: Record<string, () => Conversation[]> = {
  opencode: opencodeConversations,
  "cursor-agent": cursorConversations,
};

function expandArg(arg: string, vars: Record<string, string>): string {
  return arg
    .replaceAll("{{prompt}}", vars.prompt ?? "")
    .replaceAll("{{system}}", vars.system ?? "")
    .replaceAll("{{cwd}}", vars.cwd ?? "");
}

function renderArgs(template: string[], ctx: LaunchContext): string[] {
  const prompt = ctx.prompt ?? "";
  const system = ctx.systemPrompt ?? "";
  const vars = { prompt, system, cwd: ctx.cwd };
  const hasPrompt = template.some((a) => a.includes("{{prompt}}"));
  const hasSystem = template.some((a) => a.includes("{{system}}"));
  const expanded = template
    .map((a) => expandArg(a, vars))
    .filter((a) => a !== "");
  if (!hasSystem && system) {
    if (!hasPrompt && prompt) return [...expanded, `${system}\n\n${prompt}`];
    if (hasPrompt && prompt) return [...expanded, system];
    return [...expanded, system];
  }
  if (!hasPrompt && prompt) return [...expanded, prompt];
  // `opencode run` (and the same pattern on other CLIs) exits immediately
  // without a message, which kills the tmux pane. Fall back to the TUI.
  if (expanded.length === 1 && expanded[0] === "run" && !prompt && !system) {
    return [];
  }
  return expanded;
}

export function renderCustomArgs(
  def: CustomAgentDef,
  ctx: LaunchContext,
): string[] {
  return renderArgs(def.launchArgs, ctx);
}

export function createGenericAdapter(def: CustomAgentDef): AgentAdapter {
  return {
    name: def.id,
    binary: def.binary,
    supportsNativeFork: false,

    async isAvailable() {
      return (await exec(["which", def.binary])).code === 0;
    },

    buildLaunch(ctx: LaunchContext): Launch {
      const command = [def.binary, ...renderCustomArgs(def, ctx)];
      if (ctx.resumeNativeSessionId || ctx.forkNativeSessionId) {
        throw new Error(
          `'${def.id}' does not support resume or fork: its native session id is unknown`,
        );
      }
      return {
        command,
        nativeSessionId: null,
        transcriptPath: null,
        writtenFiles: [],
      };
    },

    async resolveTranscript(ctx: ResolveContext): Promise<string | null> {
      const discover = DISCOVERY[basename(def.binary)];
      return discover ? newestForCwd(discover(), ctx) : null;
    },

    headlessCommand(opts: HeadlessOptions): string[] {
      const ctx = {
        sessionId: "",
        cwd: opts.cwd,
        prompt: opts.prompt,
        systemPrompt: "",
      };
      // A configured template always wins: only the person who installed the
      // CLI knows which flags its version accepts.
      if (def.headlessArgs.length > 0) {
        return [def.binary, ...renderArgs(def.headlessArgs, ctx)];
      }
      if (isOpencodeBinary(def.binary)) {
        // Interactive OpenCode is `opencode` (TUI). A bare positional is the
        // project path, so appending the extraction prompt made OpenCode
        // `lstat` a 80k-character filename and exit ENAMETOOLONG.
        return [
          def.binary,
          "run",
          ...(opts.json ? ["--format", "json"] : []),
          "--auto",
          "--",
          opts.prompt,
        ];
      }
      return [def.binary, ...renderArgs(def.launchArgs, ctx)];
    },
  };
}
