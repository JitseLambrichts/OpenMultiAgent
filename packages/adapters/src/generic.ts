import { exec, type CustomAgentDef } from "@oma/core";
import type {
  AgentAdapter,
  HeadlessOptions,
  Launch,
  LaunchContext,
  ResolveContext,
} from "@oma/core";

function expandArg(arg: string, vars: Record<string, string>): string {
  return arg
    .replaceAll("{{prompt}}", vars.prompt ?? "")
    .replaceAll("{{system}}", vars.system ?? "")
    .replaceAll("{{cwd}}", vars.cwd ?? "");
}

export function renderCustomArgs(
  def: CustomAgentDef,
  ctx: LaunchContext,
): string[] {
  const prompt = ctx.prompt ?? "";
  const system = ctx.systemPrompt ?? "";
  const vars = { prompt, system, cwd: ctx.cwd };
  const hasPrompt = def.launchArgs.some((a) => a.includes("{{prompt}}"));
  const hasSystem = def.launchArgs.some((a) => a.includes("{{system}}"));
  const expanded = def.launchArgs
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

    async resolveTranscript(_ctx: ResolveContext): Promise<string | null> {
      return null;
    },

    headlessCommand(opts: HeadlessOptions): string[] {
      const expanded = renderCustomArgs(def, {
        sessionId: "",
        cwd: opts.cwd,
        prompt: opts.prompt,
        systemPrompt: "",
      });
      return [def.binary, ...expanded];
    },
  };
}
