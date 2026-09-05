import { existsSync } from "node:fs";
import type {
  AgentAdapter,
  HeadlessOptions,
  Launch,
  LaunchContext,
  ResolveContext,
} from "@oma/core";
import { exec } from "@oma/core";

function loginShell(): string {
  const shell = process.env.SHELL?.trim();
  if (shell && existsSync(shell)) return shell;
  for (const fallback of ["/bin/zsh", "/bin/bash", "/bin/sh"]) {
    if (existsSync(fallback)) return fallback;
  }
  return "/bin/sh";
}

function shellBinary(shell: string): string {
  return shell.split("/").at(-1) || shell;
}

export const terminalAdapter: AgentAdapter = {
  name: "terminal",
  binary: shellBinary(loginShell()),
  supportsNativeFork: false,

  async isAvailable() {
    return (await exec(["which", shellBinary(loginShell())])).code === 0;
  },

  buildLaunch(_ctx: LaunchContext): Launch {
    if (_ctx.resumeNativeSessionId || _ctx.forkNativeSessionId) {
      throw new Error(
        "'terminal' does not support resume or fork: it has no native session",
      );
    }
    return {
      command: [loginShell(), "-l"],
      nativeSessionId: null,
      transcriptPath: null,
      writtenFiles: [],
    };
  },

  async resolveTranscript(_ctx: ResolveContext): Promise<string | null> {
    return null;
  },

  headlessCommand(opts: HeadlessOptions): string[] {
    return [loginShell(), "-l", "-c", opts.prompt];
  },
};
