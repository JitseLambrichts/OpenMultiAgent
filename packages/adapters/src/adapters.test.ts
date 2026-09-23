import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { adapterFor } from "./index.ts";
import { createGenericAdapter } from "./generic.ts";
import { claudeAdapter, findClaudeTranscript } from "./claude.ts";
import { codexAdapter, mcpConfigArgs } from "./codex.ts";
import { geminiAdapter } from "./gemini.ts";
import { claudeProjectDir, type McpServerSpec } from "@oma/core";

const tempDirs: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oma-adapter-"));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length)
    rmSync(tempDirs.pop()!, { recursive: true, force: true });
});

const MEMORY_SERVER: McpServerSpec = {
  name: "oma",
  command: "bun",
  args: ["run", "/opt/oma/mcp.ts"],
};

describe("adapterFor", () => {
  test("returns the right adapter", () => {
    expect(adapterFor("claude").name).toBe("claude");
    expect(adapterFor("codex").name).toBe("codex");
    expect(adapterFor("gemini").name).toBe("gemini");
  });

  test("rejects unknown agents", () => {
    expect(() => adapterFor("nope-not-installed-xyz")).toThrow(/unknown agent/);
  });
});

describe("generic adapter", () => {
  test("appends the prompt when no placeholder is used", () => {
    const adapter = createGenericAdapter({
      id: "opencode",
      name: "Opencode",
      binary: "opencode",
      launchArgs: ["run"],
      headlessArgs: [],
      symbol: "terminal",
    });
    const launch = adapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      systemPrompt: "BRIEF",
      prompt: "do the thing",
    });
    expect(launch.command).toEqual([
      "opencode",
      "run",
      "BRIEF\n\ndo the thing",
    ]);
    expect(launch.nativeSessionId).toBeNull();
    expect(launch.transcriptPath).toBeNull();
  });

  test("expands placeholders instead of appending", () => {
    const adapter = createGenericAdapter({
      id: "opencode",
      name: "Opencode",
      binary: "opencode",
      launchArgs: ["run", "{{system}}", "--", "{{prompt}}"],
      headlessArgs: [],
      symbol: "terminal",
    });
    const launch = adapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      systemPrompt: "BRIEF",
      prompt: "do it",
    });
    expect(launch.command).toEqual(["opencode", "run", "BRIEF", "--", "do it"]);
  });

  test("starts the TUI when run would have no message", () => {
    for (const launchArgs of [["run"], ["run", "{{prompt}}"]]) {
      const adapter = createGenericAdapter({
        id: "opencode",
        name: "Opencode",
        binary: "opencode",
        launchArgs,
        headlessArgs: [],
        symbol: "terminal",
      });
      const launch = adapter.buildLaunch({
        sessionId: "oma-1",
        cwd: "/tmp/x",
      });
      expect(launch.command).toEqual(["opencode"]);
    }
  });

  test("headless OpenCode uses run so the prompt is not a project path", () => {
    for (const launchArgs of [[], ["run"], ["run", "{{prompt}}"]]) {
      const adapter = createGenericAdapter({
        id: "opencode",
        name: "Opencode",
        binary: "opencode",
        launchArgs,
        headlessArgs: [],
        symbol: "terminal",
      });
      expect(
        adapter.headlessCommand({
          cwd: "/tmp/x",
          prompt: "Extract only durable knowledge",
          json: true,
        }),
      ).toEqual([
        "opencode",
        "run",
        "--format",
        "json",
        "--auto",
        "--",
        "Extract only durable knowledge",
      ]);
    }
  });

  test("headless OpenCode matches the binary basename, not launchArgs", () => {
    const adapter = createGenericAdapter({
      id: "ocode",
      name: "OpenCode",
      binary: "/usr/local/bin/opencode",
      launchArgs: [],
      headlessArgs: [],
      symbol: "terminal",
    });
    expect(
      adapter.headlessCommand({ cwd: "/tmp/x", prompt: "hi", json: false }),
    ).toEqual(["/usr/local/bin/opencode", "run", "--auto", "--", "hi"]);
  });

  test("headless custom agents still append the prompt", () => {
    const adapter = createGenericAdapter({
      id: "grok",
      name: "Grok",
      binary: "grok",
      launchArgs: [],
      headlessArgs: [],
      symbol: "sparkle",
    });
    expect(
      adapter.headlessCommand({ cwd: "/tmp/x", prompt: "Extract knowledge" }),
    ).toEqual(["grok", "Extract knowledge"]);
  });

  test("headlessArgs expand the prompt in place", () => {
    const adapter = createGenericAdapter({
      id: "cursor",
      name: "Cursor",
      binary: "cursor-agent",
      launchArgs: [],
      headlessArgs: ["-p", "--output-format", "json", "{{prompt}}"],
      symbol: "cursorarrow",
    });
    expect(
      adapter.headlessCommand({
        cwd: "/tmp/x",
        prompt: "Extract knowledge",
        json: true,
      }),
    ).toEqual([
      "cursor-agent",
      "-p",
      "--output-format",
      "json",
      "Extract knowledge",
    ]);
  });

  test("headlessArgs without a placeholder get the prompt appended", () => {
    const adapter = createGenericAdapter({
      id: "cursor",
      name: "Cursor",
      binary: "cursor-agent",
      launchArgs: [],
      headlessArgs: ["-p", "--output-format", "json"],
      symbol: "cursorarrow",
    });
    expect(
      adapter.headlessCommand({ cwd: "/tmp/x", prompt: "Extract knowledge" }),
    ).toEqual([
      "cursor-agent",
      "-p",
      "--output-format",
      "json",
      "Extract knowledge",
    ]);
  });

  test("headlessArgs override the built-in OpenCode guess", () => {
    const adapter = createGenericAdapter({
      id: "opencode",
      name: "Opencode",
      binary: "opencode",
      launchArgs: [],
      headlessArgs: ["run", "--format", "json", "--", "{{prompt}}"],
      symbol: "terminal",
    });
    expect(
      adapter.headlessCommand({ cwd: "/tmp/x", prompt: "hi", json: true }),
    ).toEqual(["opencode", "run", "--format", "json", "--", "hi"]);
  });

  test("headlessArgs expand the working directory", () => {
    const adapter = createGenericAdapter({
      id: "grok",
      name: "Grok",
      binary: "grok",
      launchArgs: [],
      headlessArgs: ["--cwd", "{{cwd}}", "{{prompt}}"],
      symbol: "sparkle",
    });
    expect(
      adapter.headlessCommand({ cwd: "/tmp/x", prompt: "hi" }),
    ).toEqual(["grok", "--cwd", "/tmp/x", "hi"]);
  });

  test("OpenCode transcripts are discovered by cwd and start time", async () => {
    const data = tempDir();
    const previous = process.env.XDG_DATA_HOME;
    process.env.XDG_DATA_HOME = data;
    try {
      const sessions = join(data, "opencode", "storage", "session", "proj");
      mkdirSync(sessions, { recursive: true });
      const write = (id: string, directory: string, created: number): string => {
        const path = join(sessions, `${id}.json`);
        writeFileSync(
          path,
          JSON.stringify({ id, directory, time: { created } }),
        );
        return path;
      };
      const startedAt = new Date(2_000_000);
      const wanted = write("ses_wanted", "/repo/worktree", 2_500_000);
      write("ses_elsewhere", "/other/repo", 2_500_000);
      write("ses_earlier", "/repo/worktree", 1_000_000);

      const adapter = createGenericAdapter({
        id: "ocode",
        name: "Opencode",
        binary: "opencode",
        launchArgs: [],
        headlessArgs: [],
        symbol: "terminal",
      });

      expect(
        await adapter.resolveTranscript({ cwd: "/repo/worktree", startedAt }),
      ).toBe(wanted);
      expect(
        await adapter.resolveTranscript({ cwd: "/nowhere", startedAt }),
      ).toBeNull();
      expect(
        await adapter.resolveTranscript({
          cwd: "/repo/worktree",
          startedAt,
          excludeNativeSessionId: "ses_wanted",
        }),
      ).toBeNull();
    } finally {
      if (previous === undefined) delete process.env.XDG_DATA_HOME;
      else process.env.XDG_DATA_HOME = previous;
    }
  });

  test("Cursor chats are discovered by cwd and start time", async () => {
    const home = tempDir();
    const previous = process.env.HOME;
    process.env.HOME = home;
    try {
      const chat = (id: string, cwd: string, createdAtMs: number): string => {
        const dir = join(home, ".cursor", "chats", "workspace-hash", id);
        mkdirSync(dir, { recursive: true });
        writeFileSync(
          join(dir, "meta.json"),
          JSON.stringify({ schemaVersion: 1, createdAtMs, cwd, title: id }),
        );
        return dir;
      };
      const startedAt = new Date(2_000_000);
      const wanted = chat("chat-wanted", "/repo/worktree", 2_500_000);
      chat("chat-elsewhere", "/other/repo", 2_500_000);
      chat("chat-earlier", "/repo/worktree", 1_000_000);

      const adapter = createGenericAdapter({
        id: "cursor",
        name: "Cursor",
        binary: "cursor-agent",
        launchArgs: [],
        headlessArgs: [],
        symbol: "hammer",
      });

      expect(
        await adapter.resolveTranscript({ cwd: "/repo/worktree", startedAt }),
      ).toBe(wanted);
      expect(
        await adapter.resolveTranscript({ cwd: "/nowhere", startedAt }),
      ).toBeNull();
      expect(
        await adapter.resolveTranscript({
          cwd: "/repo/worktree",
          startedAt,
          excludeNativeSessionId: "chat-wanted",
        }),
      ).toBeNull();
    } finally {
      if (previous === undefined) delete process.env.HOME;
      else process.env.HOME = previous;
    }
  });

  test("an agent with no known storage layout still reports no transcript", async () => {
    const adapter = createGenericAdapter({
      id: "grok",
      name: "Grok",
      binary: "grok",
      launchArgs: [],
      headlessArgs: [],
      symbol: "sparkle",
    });
    expect(
      await adapter.resolveTranscript({
        cwd: "/repo",
        startedAt: new Date(0),
      }),
    ).toBeNull();
  });

  test("resume and fork are rejected with a clear error", () => {
    const adapter = createGenericAdapter({
      id: "opencode",
      name: "Opencode",
      binary: "opencode",
      launchArgs: [],
      headlessArgs: [],
      symbol: "terminal",
    });
    expect(() =>
      adapter.buildLaunch({
        sessionId: "oma-1",
        cwd: "/tmp/x",
        resumeNativeSessionId: "abc",
      }),
    ).toThrow(/does not support resume/);
  });
});

describe("gemini adapter", () => {
  test("pins a new native session and isolates MCP settings outside the repo", () => {
    const launch = geminiAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: tempDir(),
      mcpServers: [MEMORY_SERVER],
    });

    expect(launch.command).toContain("--session-id");
    expect(launch.nativeSessionId).not.toBeNull();
    const settingsPath = launch.env?.GEMINI_CLI_SYSTEM_SETTINGS_PATH;
    expect(settingsPath).toEndWith("/gemini/oma-1/settings.json");
    if (!settingsPath) throw new Error("missing Gemini settings path");
    expect(launch.writtenFiles).toEqual([settingsPath]);

    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(settings.mcpServers.oma).toEqual({
      command: "bun",
      args: ["run", "/opt/oma/mcp.ts"],
      trust: true,
    });
  });

  test("resumes by native session id", () => {
    const launch = geminiAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      resumeNativeSessionId: "existing-id",
    });
    expect(launch.command).toContain("--resume");
    expect(launch.command).not.toContain("--session-id");
    expect(launch.nativeSessionId).toBe("existing-id");
  });

  test("discovers the transcript that carries the pinned session id", async () => {
    const home = tempDir();
    const previous = process.env.GEMINI_CLI_HOME;
    process.env.GEMINI_CLI_HOME = home;
    try {
      const chatDir = join(home, "tmp", "demo", "chats");
      await Bun.write(
        join(chatDir, "session-now-abcd1234.jsonl"),
        `${JSON.stringify({ sessionId: "abcd1234-full", startTime: new Date().toISOString() })}\n`,
      );
      expect(
        await geminiAdapter.resolveTranscript({
          cwd: "/tmp/x",
          startedAt: new Date(Date.now() - 1_000),
          nativeSessionId: "abcd1234-full",
        }),
      ).toEndWith("session-now-abcd1234.jsonl");
    } finally {
      if (previous === undefined) delete process.env.GEMINI_CLI_HOME;
      else process.env.GEMINI_CLI_HOME = previous;
    }
  });

  test("headless invocation asks for JSON output", () => {
    expect(
      geminiAdapter.headlessCommand({
        cwd: "/tmp/x",
        prompt: "hi",
        json: true,
      }),
    ).toEqual(["gemini", "--output-format", "json", "--prompt", "hi"]);
  });
});

describe("claude adapter", () => {
  test("pins the session id so the transcript path is known upfront", () => {
    const launch = claudeAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/Users/dev/Projects/Demo",
    });
    expect(launch.command).toContain("--session-id");
    expect(launch.nativeSessionId).not.toBeNull();
    expect(launch.transcriptPath).toBe(
      `${process.env.HOME}/.claude/projects/-Users-dev-Projects-Demo/${launch.nativeSessionId}.jsonl`,
    );
  });

  test("resumes by native session id instead of pinning a new one", () => {
    const launch = claudeAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      resumeNativeSessionId: "existing-id",
    });
    expect(launch.command).toContain("--resume");
    expect(launch.command).not.toContain("--session-id");
    expect(launch.nativeSessionId).toBe("existing-id");
  });

  test("forks a native conversation without reusing its session id", () => {
    const launch = claudeAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      forkNativeSessionId: "existing-id",
    });
    expect(launch.command).toContain("--fork-session");
    expect(launch.command).toContain("--resume");
    expect(launch.command).not.toContain("--session-id");
    expect(launch.nativeSessionId).toBeNull();
  });

  test("writes session-private MCP config without touching the repository", async () => {
    const cwd = tempDir();
    const omaHome = tempDir();
    const projectConfig = join(cwd, ".mcp.json");
    await Bun.write(projectConfig, '{"mcpServers":{"project":{}}}\n');
    const previous = process.env.OMA_HOME;
    process.env.OMA_HOME = omaHome;
    try {
      const launch = claudeAdapter.buildLaunch({
        sessionId: "oma-1",
        cwd,
        mcpServers: [MEMORY_SERVER],
      });

      const path = join(omaHome, "claude", "oma-1", "mcp.json");
      expect(launch.writtenFiles).toEqual([path]);
      expect(launch.command).toContain("--mcp-config");
      expect(readFileSync(projectConfig, "utf8")).toBe(
        '{"mcpServers":{"project":{}}}\n',
      );
      const config = JSON.parse(readFileSync(path, "utf8"));
      expect(config.mcpServers.oma).toEqual({
        command: "bun",
        args: ["run", "/opt/oma/mcp.ts"],
      });
    } finally {
      if (previous === undefined) delete process.env.OMA_HOME;
      else process.env.OMA_HOME = previous;
    }
  });

  test("never lets a variadic flag sit directly before the prompt", () => {
    // Regression: `--mcp-config` and `--allowedTools` take an unbounded list,
    // so with the prompt straight after them Claude consumed it as a value and
    // exited with "Input must be provided either through stdin or as a prompt".
    const cwd = tempDir();
    const launch = claudeAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd,
      mcpServers: [MEMORY_SERVER],
      systemPrompt: "BRIEF",
      prompt: "do the thing",
    });

    const VARIADIC = new Set(["--mcp-config", "--allowedTools"]);
    const promptIndex = launch.command.lastIndexOf("do the thing");
    expect(promptIndex).toBe(launch.command.length - 1);

    // Walk back to the flag that owns the argument before the prompt.
    const owner = launch.command
      .slice(0, promptIndex)
      .reverse()
      .find((arg) => arg.startsWith("--"));
    expect(VARIADIC.has(owner!)).toBe(false);
    expect(owner).toBe("--session-id");
  });

  test("pre-allows its own MCP tools so headless memory lookups are not blocked", () => {
    const launch = claudeAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: tempDir(),
      mcpServers: [MEMORY_SERVER],
    });
    const i = launch.command.indexOf("--allowedTools");
    expect(i).toBeGreaterThan(-1);
    expect(launch.command[i + 1]).toBe("mcp__oma");
  });

  test("passes the handoff brief as a system-prompt suffix", () => {
    const launch = claudeAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      systemPrompt: "BRIEF",
      prompt: "carry on",
    });
    const i = launch.command.indexOf("--append-system-prompt");
    expect(launch.command[i + 1]).toBe("BRIEF");
    expect(launch.command.at(-1)).toBe("carry on");
  });

  test("resolveTranscript stays null until the agent writes its first event", async () => {
    const cwd = tempDir();
    expect(
      await claudeAdapter.resolveTranscript({
        cwd,
        startedAt: new Date(),
        nativeSessionId: "nope",
      }),
    ).toBeNull();
  });

  test("finds the new transcript of a fork whose id is assigned by Claude", async () => {
    const home = tempDir();
    const cwd = tempDir();
    const transcript = join(claudeProjectDir(cwd, home), "fork-id.jsonl");
    await Bun.write(
      transcript,
      `${JSON.stringify({ sessionId: "fork-id", cwd, type: "user" })}\n`,
    );

    expect(findClaudeTranscript(cwd, new Date(Date.now() - 1_000), home)).toBe(
      transcript,
    );
  });

  test("never mistakes the recently modified source transcript for its fork", async () => {
    const home = tempDir();
    const cwd = tempDir();
    const directory = claudeProjectDir(cwd, home);
    const fork = join(directory, "fork-id.jsonl");
    const source = join(directory, "source-id.jsonl");
    await Bun.write(fork, "{}\n");
    await Bun.write(source, "{}\n");

    expect(
      findClaudeTranscript(
        cwd,
        new Date(Date.now() - 1_000),
        home,
        "source-id",
      ),
    ).toBe(fork);
  });
});

describe("codex adapter", () => {
  test("cannot know its transcript upfront, so it reports neither", () => {
    const launch = codexAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
    });
    expect(launch.nativeSessionId).toBeNull();
    expect(launch.transcriptPath).toBeNull();
    expect(launch.command).toEqual(["codex", "-C", "/tmp/x"]);
  });

  test("injects MCP servers as config overrides, leaving config.toml alone", () => {
    const args = mcpConfigArgs([MEMORY_SERVER]);
    expect(args).toEqual([
      "-c",
      'mcp_servers.oma.command="bun"',
      "-c",
      'mcp_servers.oma.args=["run","/opt/oma/mcp.ts"]',
      "-c",
      "mcp_servers.oma.startup_timeout_sec=30",
    ]);
  });

  test("forks a native conversation through the fork subcommand", () => {
    const launch = codexAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      forkNativeSessionId: "existing-id",
    });
    expect(launch.command.slice(0, 3)).toEqual([
      "codex",
      "fork",
      "existing-id",
    ]);
    expect(launch.nativeSessionId).toBeNull();
  });

  test("prepends the handoff brief to the prompt, since there is no system flag", () => {
    const launch = codexAdapter.buildLaunch({
      sessionId: "oma-1",
      cwd: "/tmp/x",
      systemPrompt: "BRIEF",
      prompt: "carry on",
    });
    expect(launch.command).not.toContain("--append-system-prompt");
    expect(launch.command.at(-1)).toBe("BRIEF\n\ncarry on");
  });

  test("resolveTranscript returns null when no rollout matches the cwd", async () => {
    expect(
      await codexAdapter.resolveTranscript({
        cwd: "/definitely/not/a/real/worktree",
        startedAt: new Date(),
      }),
    ).toBeNull();
  });

  test("headless invocation asks for JSONL events", () => {
    expect(
      codexAdapter.headlessCommand({ cwd: "/tmp/x", prompt: "hi", json: true }),
    ).toEqual(["codex", "exec", "-C", "/tmp/x", "--json", "hi"]);
  });
});
