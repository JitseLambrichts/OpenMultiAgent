import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Database } from "bun:sqlite";
import type { AgentAdapter, Launch, LaunchContext } from "./agent.ts";
import type { AgentName } from "./types.ts";
import { openDb } from "./db.ts";
import { exec } from "./exec.ts";
import { tmuxSessionName } from "./paths.ts";
import { listSessions } from "./store.ts";
import { SessionManager, shellQuote } from "./session-manager.ts";
import * as tmux from "./tmux.ts";

/**
 * A stand-in for a real agent: it holds the tmux pane open the way an
 * interactive agent would, without invoking a model or costing anything.
 */
function fakeAdapter(overrides: Partial<AgentAdapter> = {}): AgentAdapter {
  return {
    name: "claude",
    binary: "sleep",
    isAvailable: async () => true,
    buildLaunch: (ctx: LaunchContext): Launch => ({
      command: ["sleep", "30"],
      nativeSessionId: `native-${ctx.sessionId}`,
      transcriptPath: join(ctx.cwd, "transcript.jsonl"),
      writtenFiles: [],
    }),
    resolveTranscript: async () => null,
    headlessCommand: () => ["true"],
    ...overrides,
  };
}

let db: Database;
let repo: string;
const created: string[] = [];

async function makeRepo(): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), "oma-repo-"));
  created.push(dir);
  await exec(["git", "init", "-b", "main"], { cwd: dir });
  await exec(["git", "config", "user.email", "test@example.com"], { cwd: dir });
  await exec(["git", "config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# test\n");
  await exec(["git", "add", "."], { cwd: dir });
  await exec(["git", "commit", "-m", "init"], { cwd: dir });
  return dir;
}

beforeEach(async () => {
  db = openDb({ path: ":memory:" });
  repo = await makeRepo();
});

afterEach(async () => {
  // Kill only the tmux sessions this test's in-memory database knows about.
  // Killing every `oma-*` session would also end the developer's real sessions.
  for (const session of listSessions(db)) {
    await tmux.killSession(tmuxSessionName(session.id));
  }
  db.close();
  while (created.length)
    rmSync(created.pop()!, { recursive: true, force: true });
});

const manager = (adapter = fakeAdapter()) =>
  new SessionManager(db, {
    adapterFor: () => adapter,
    startLock: (fn) => fn(),
  });

function managerFor(adapters: Partial<Record<AgentName, AgentAdapter>>) {
  return new SessionManager(db, {
    startLock: (fn) => fn(),
    adapterFor: (agent) => {
      const adapter = adapters[agent];
      if (!adapter) throw new Error(`missing test adapter ${agent}`);
      return adapter;
    },
  });
}

describe("shellQuote", () => {
  test("leaves plain arguments alone", () => {
    expect(shellQuote(["claude", "--session-id", "abc-123"])).toBe(
      "claude --session-id abc-123",
    );
  });

  test("quotes a multi-line handoff brief so tmux gets one argument", () => {
    expect(shellQuote(["claude", "line one\nline two"])).toBe(
      "claude 'line one\nline two'",
    );
  });

  test("escapes embedded single quotes", () => {
    expect(shellQuote(["echo", "it's"])).toBe(`echo 'it'\\''s'`);
  });
});

describe("SessionManager.create", () => {
  test("starts a tmux session named after the OMA session", async () => {
    const view = await manager().create({ repoPath: repo, agent: "claude" });

    expect(view.session.status).toBe("active");
    expect(view.tmuxAlive).toBe(true);
    expect(await tmux.hasSession(tmuxSessionName(view.session.id))).toBe(true);
    expect(view.runs).toHaveLength(1);
    expect(view.runs[0]!.native_session_id).toBe(`native-${view.session.id}`);
  });

  test("runs in the repo itself when no worktree is asked for", async () => {
    const view = await manager().create({ repoPath: repo, agent: "claude" });
    expect(view.session.worktree_path).toBe(view.session.repo_path);
    expect(view.session.branch).toBe("main");
  });

  test("isolates the session in its own worktree and branch", async () => {
    const view = await manager().create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });

    expect(view.session.worktree_path).not.toBe(view.session.repo_path);
    expect(existsSync(view.session.worktree_path)).toBe(true);
    expect(view.session.branch).toStartWith("oma/");
  });

  test("two parallel sessions on one repo do not collide", async () => {
    const mgr = manager();
    const [a, b] = await Promise.all([
      mgr.create({ repoPath: repo, agent: "claude", worktree: true }),
      mgr.create({ repoPath: repo, agent: "claude", worktree: true }),
    ]);

    expect(a.session.id).not.toBe(b.session.id);
    expect(a.session.worktree_path).not.toBe(b.session.worktree_path);
    expect(await tmux.hasSession(tmuxSessionName(a.session.id))).toBe(true);
    expect(await tmux.hasSession(tmuxSessionName(b.session.id))).toBe(true);
  });

  test("fails create when the agent exits during startup", async () => {
    const adapter = fakeAdapter({
      buildLaunch: (ctx) => ({
        command: ["true"],
        nativeSessionId: `native-${ctx.sessionId}`,
        transcriptPath: join(ctx.cwd, "transcript.jsonl"),
        writtenFiles: [],
      }),
    });

    await expect(
      manager(adapter).create({ repoPath: repo, agent: "claude" }),
    ).rejects.toThrow(/exited during startup/);
    expect(
      db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM session").get()?.n,
    ).toBe(0);
  });

  test("refuses a directory that is not a git repository", async () => {
    const plain = mkdtempSync(join(tmpdir(), "oma-plain-"));
    created.push(plain);
    await expect(
      manager().create({ repoPath: plain, agent: "claude" }),
    ).rejects.toThrow(/not a git repository/);
  });

  test("refuses to start an agent that is not installed", async () => {
    const missing = fakeAdapter({ isAvailable: async () => false });
    await expect(
      manager(missing).create({ repoPath: repo, agent: "claude" }),
    ).rejects.toThrow(/not on PATH/);
  });

  test("leaves no half-created session behind when launch fails", async () => {
    const broken = fakeAdapter({
      buildLaunch: () => {
        throw new Error("boom");
      },
    });
    await expect(
      manager(broken).create({ repoPath: repo, agent: "claude" }),
    ).rejects.toThrow("boom");

    expect(
      db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM session").get()?.n,
    ).toBe(0);
  });

  test("cleans up the worktree when launch fails after it was created", async () => {
    const broken = fakeAdapter({
      buildLaunch: () => {
        throw new Error("boom");
      },
    });
    await expect(
      manager(broken).create({
        repoPath: repo,
        agent: "claude",
        worktree: true,
      }),
    ).rejects.toThrow("boom");

    // `git worktree remove` leaves the empty `.worktrees` parent behind, which
    // is harmless; what matters is that git no longer tracks a second tree.
    const listed = (
      await exec(["git", "worktree", "list"], { cwd: repo })
    ).stdout
      .split("\n")
      .filter((l) => l.trim() !== "");
    expect(listed).toHaveLength(1);
  });

  test("passes the scoped MCP server through to the adapter", async () => {
    const seen: LaunchContext[] = [];
    const spy = fakeAdapter({
      buildLaunch: (ctx) => {
        seen.push(ctx);
        return {
          command: ["sleep", "30"],
          nativeSessionId: null,
          transcriptPath: null,
          writtenFiles: [],
        };
      },
    });

    const mgr = new SessionManager(db, {
      adapterFor: () => spy,
      startLock: (fn) => fn(),
      mcpServers: (scope) => [
        {
          name: "oma",
          command: "bun",
          args: ["run", "mcp"],
          env: {
            OMA_SESSION_ID: scope.sessionId,
            OMA_REPO_PATH: scope.repoPath,
          },
        },
      ],
    });

    const view = await mgr.create({ repoPath: repo, agent: "claude" });
    expect(seen.at(-1)?.mcpServers?.[0]?.env).toEqual({
      OMA_SESSION_ID: view.session.id,
      OMA_REPO_PATH: view.session.repo_path,
    });
  });

  test("fails cleanly when Codex never publishes a correlatable transcript", async () => {
    const codex = fakeAdapter({
      name: "codex",
      buildLaunch: () => ({
        command: ["sleep", "30"],
        nativeSessionId: null,
        transcriptPath: null,
        writtenFiles: [],
      }),
      resolveTranscript: async () => null,
    });
    const mgr = new SessionManager(db, {
      adapterFor: () => codex,
      startLock: (fn) => fn(),
      transcriptDiscovery: { attempts: 1, intervalMs: 1 },
    });

    await expect(
      mgr.create({ repoPath: repo, agent: "codex" }),
    ).rejects.toThrow(/correlatable transcript/);
    expect(
      db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM session").get()?.n,
    ).toBe(0);
  });
});

describe("SessionManager.list", () => {
  test("reports whether the tmux session is still alive", async () => {
    const mgr = manager();
    const view = await mgr.create({ repoPath: repo, agent: "claude" });

    expect((await mgr.list())[0]!.tmuxAlive).toBe(true);

    await tmux.killSession(tmuxSessionName(view.session.id));
    expect((await mgr.list())[0]!.tmuxAlive).toBe(false);
  });

  test("only lists OMA sessions, never foreign tmux sessions", async () => {
    // Sessions from other tools (this machine runs `xirp-*`) must be ignored.
    await exec(["tmux", "new-session", "-d", "-s", "xirp-decoy"]);
    try {
      const names = (await tmux.listSessions()).map((s) => s.name);
      expect(names).not.toContain("xirp-decoy");
    } finally {
      await tmux.killSession("xirp-decoy");
    }
  });

  test("status includes the worktree changes and current pane output", async () => {
    const mgr = manager();
    const view = await mgr.create({ repoPath: repo, agent: "claude" });
    writeFileSync(
      join(view.session.worktree_path, "pending file.ts"),
      "export {};\n",
    );

    const status = await mgr.status(view.session.id);

    expect(status.changedFiles).toContainEqual({
      status: "??",
      path: "pending file.ts",
    });
    expect(status.pane).toBeString();
  });
});

describe("SessionManager.end and remove", () => {
  test("end kills the tmux session but keeps the record", async () => {
    const mgr = manager();
    const view = await mgr.create({ repoPath: repo, agent: "claude" });

    await mgr.end(view.session.id);

    expect(await tmux.hasSession(tmuxSessionName(view.session.id))).toBe(false);
    expect(mgr.view(view.session.id).session.status).toBe("ended");
  });

  test("end records which files the session changed", async () => {
    const mgr = manager();
    const view = await mgr.create({ repoPath: repo, agent: "claude" });
    writeFileSync(
      join(view.session.worktree_path, "new-file.ts"),
      "export {};\n",
    );

    await mgr.end(view.session.id);

    const artifacts = db
      .query<{ path: string; change_kind: string }, [string]>(
        "SELECT path, change_kind FROM artifact WHERE session_id = ?",
      )
      .all(view.session.id);
    expect(artifacts).toEqual([
      { path: "new-file.ts", change_kind: "created" },
    ]);
  });

  test("end with merge merges the branch and cleans up the worktree", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });
    const worktree = view.session.worktree_path;
    writeFileSync(join(worktree, "feature.txt"), "shipped\n");
    await exec(["git", "add", "."], { cwd: worktree });
    await exec(["git", "commit", "-m", "add feature"], { cwd: worktree });

    await mgr.end(view.session.id, { merge: true });

    expect(await tmux.hasSession(tmuxSessionName(view.session.id))).toBe(false);
    expect(mgr.view(view.session.id).session.status).toBe("ended");
    expect(existsSync(worktree)).toBe(false);
    expect(existsSync(join(repo, "feature.txt"))).toBe(true);
  });

  test("end with merge refuses a dirty worktree and keeps the session alive", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });
    writeFileSync(join(view.session.worktree_path, "dirty.txt"), "uncommitted\n");

    await expect(mgr.end(view.session.id, { merge: true })).rejects.toThrow(
      /uncommitted changes, commit first/,
    );
    expect(mgr.view(view.session.id).session.status).toBe("active");
    expect(await tmux.hasSession(tmuxSessionName(view.session.id))).toBe(true);
  });

  test("end with merge aborts on conflict and keeps the session alive", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });
    const worktree = view.session.worktree_path;
    writeFileSync(join(worktree, "README.md"), "# worktree\n");
    await exec(["git", "add", "."], { cwd: worktree });
    await exec(["git", "commit", "-m", "worktree change"], { cwd: worktree });
    writeFileSync(join(repo, "README.md"), "# main\n");
    await exec(["git", "add", "."], { cwd: repo });
    await exec(["git", "commit", "-m", "main change"], { cwd: repo });

    await expect(mgr.end(view.session.id, { merge: true })).rejects.toThrow(
      /merge conflict/,
    );
    expect(mgr.view(view.session.id).session.status).toBe("active");
    expect(await tmux.hasSession(tmuxSessionName(view.session.id))).toBe(true);
  });

  test("end without merge leaves a worktree session untouched", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });

    await mgr.end(view.session.id);

    expect(mgr.view(view.session.id).session.status).toBe("ended");
    expect(existsSync(view.session.worktree_path)).toBe(true);
  });

  test("rm removes the worktree and the session record", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });
    const worktree = view.session.worktree_path;

    await mgr.remove(view.session.id);

    expect(existsSync(worktree)).toBe(false);
    expect(
      db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM session").get()?.n,
    ).toBe(0);
  });

  test("rm --force removes a dirty worktree", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });
    writeFileSync(
      join(view.session.worktree_path, "dirty.txt"),
      "uncommitted\n",
    );

    await mgr.remove(view.session.id, { force: true });
    expect(existsSync(view.session.worktree_path)).toBe(false);
  });

  test("rm keeps a dirty worktree and session record unless forced", async () => {
    const mgr = manager();
    const view = await mgr.create({
      repoPath: repo,
      agent: "claude",
      worktree: true,
    });
    writeFileSync(
      join(view.session.worktree_path, "dirty.txt"),
      "uncommitted\n",
    );

    await expect(mgr.remove(view.session.id)).rejects.toThrow(
      /worktree remove/,
    );
    expect(existsSync(view.session.worktree_path)).toBe(true);
    expect(mgr.view(view.session.id).session.id).toBe(view.session.id);
  });

  test("rm never touches the main checkout", async () => {
    const mgr = manager();
    const view = await mgr.create({ repoPath: repo, agent: "claude" });

    await mgr.remove(view.session.id);

    expect(existsSync(join(repo, "README.md"))).toBe(true);
  });
});

describe("SessionManager.switchAgent and resume", () => {
  test("switches agents in the same session and injects a handoff brief", async () => {
    const switchContexts: LaunchContext[] = [];
    const claude = fakeAdapter();
    const codex = fakeAdapter({
      name: "codex",
      buildLaunch: (ctx) => {
        switchContexts.push(ctx);
        return {
          command: ["sleep", "30"],
          nativeSessionId: "codex-native",
          transcriptPath: join(ctx.cwd, "codex.jsonl"),
          writtenFiles: [],
        };
      },
    });
    const mgr = managerFor({ claude, codex });
    const original = await mgr.create({
      repoPath: repo,
      agent: "claude",
      title: "Finish retry handling",
    });

    const switched = await mgr.switchAgent(original.session.id, "codex");

    expect(switched.session.id).toBe(original.session.id);
    expect(switched.session.worktree_path).toBe(original.session.worktree_path);
    expect(switched.runs.map((run) => run.agent)).toEqual(["claude", "codex"]);
    expect(switched.runs[0]?.ended_at).not.toBeNull();
    expect(switchContexts.at(-1)?.systemPrompt).toContain(
      "Finish retry handling",
    );
    expect(switchContexts.at(-1)?.systemPrompt).toContain(
      "continuity of knowledge",
    );
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
  });

  test("keeps the current agent alive when the replacement cannot be staged", async () => {
    let launches = 0;
    const adapter = fakeAdapter({
      buildLaunch: (ctx) => {
        launches++;
        return {
          command: ["sleep", "30"],
          env: launches === 1 ? undefined : { "invalid-name": "value" },
          nativeSessionId: `native-${ctx.sessionId}`,
          transcriptPath: join(ctx.cwd, "transcript.jsonl"),
          writtenFiles: [],
        };
      },
    });
    const mgr = managerFor({ claude: adapter, codex: adapter });
    const original = await mgr.create({ repoPath: repo, agent: "claude" });

    await expect(mgr.switchAgent(original.session.id, "codex")).rejects.toThrow(
      /invalid tmux environment variable/,
    );
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
    expect(mgr.view(original.session.id).runs).toHaveLength(1);
  });

  test("keeps the current agent alive when the real replacement exits immediately", async () => {
    let launches = 0;
    const adapter = fakeAdapter({
      buildLaunch: (ctx) => ({
        command: launches++ === 0 ? ["sleep", "30"] : ["oma-does-not-exist"],
        nativeSessionId: `native-${ctx.sessionId}`,
        transcriptPath: join(ctx.cwd, "transcript.jsonl"),
        writtenFiles: [],
      }),
    });
    const mgr = managerFor({ claude: adapter, codex: adapter });
    const original = await mgr.create({ repoPath: repo, agent: "claude" });

    await expect(mgr.switchAgent(original.session.id, "codex")).rejects.toThrow(
      /replacement agent exited/,
    );
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
    expect(mgr.view(original.session.id).runs).toHaveLength(1);
  });

  test("restores the current agent when replacement dies during activation", async () => {
    let launches = 0;
    const adapter = fakeAdapter({
      buildLaunch: (ctx) => ({
        command: launches++ === 0 ? ["sleep", "30"] : ["sleep", "0.25"],
        nativeSessionId: `native-${ctx.sessionId}`,
        transcriptPath: join(ctx.cwd, "transcript.jsonl"),
        writtenFiles: [],
      }),
    });
    const mgr = managerFor({ claude: adapter, codex: adapter });
    const original = await mgr.create({ repoPath: repo, agent: "claude" });

    await expect(mgr.switchAgent(original.session.id, "codex")).rejects.toThrow(
      /replacement agent exited during activation/,
    );
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
    expect(mgr.view(original.session.id).runs).toHaveLength(1);
  });

  test("keeps the current agent when staged Codex cannot be correlated", async () => {
    const claude = fakeAdapter();
    const codex = fakeAdapter({
      name: "codex",
      buildLaunch: () => ({
        command: ["sleep", "30"],
        nativeSessionId: null,
        transcriptPath: null,
        writtenFiles: [],
      }),
      resolveTranscript: async () => null,
    });
    const mgr = new SessionManager(db, {
      adapterFor: (agent) => (agent === "codex" ? codex : claude),
      startLock: (fn) => fn(),
      transcriptDiscovery: { attempts: 1, intervalMs: 1 },
    });
    const original = await mgr.create({ repoPath: repo, agent: "claude" });

    await expect(mgr.switchAgent(original.session.id, "codex")).rejects.toThrow(
      /correlatable transcript/,
    );
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
    expect(mgr.view(original.session.id).runs).toHaveLength(1);
  });

  test("resumes the latest native run and reactivates an ended session", async () => {
    const resumeContexts: LaunchContext[] = [];
    const claude = fakeAdapter({
      buildLaunch: (ctx) => {
        resumeContexts.push(ctx);
        return {
          command: ["sleep", "30"],
          nativeSessionId:
            ctx.resumeNativeSessionId ?? `native-${ctx.sessionId}`,
          transcriptPath: join(ctx.cwd, "transcript.jsonl"),
          writtenFiles: [],
        };
      },
    });
    const mgr = managerFor({ claude });
    const original = await mgr.create({ repoPath: repo, agent: "claude" });
    await mgr.end(original.session.id);

    const resumed = await mgr.resume(original.session.id);

    const originalNativeId = original.runs[0]?.native_session_id;
    if (!originalNativeId)
      throw new Error("test adapter did not assign a native id");
    expect(resumeContexts.at(-1)?.resumeNativeSessionId).toBe(originalNativeId);
    expect(resumed.session.status).toBe("active");
    // A native resume continues the same agent_run; replaying it as a second
    // run would duplicate the transcript in the event index.
    expect(resumed.runs).toHaveLength(1);
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
  });

  test("forks the latest native run into a new run in the same worktree", async () => {
    const contexts: LaunchContext[] = [];
    const claude = fakeAdapter({
      buildLaunch: (ctx) => {
        contexts.push(ctx);
        return {
          command: ["sleep", "30"],
          nativeSessionId: ctx.forkNativeSessionId
            ? "forked-id"
            : "original-id",
          transcriptPath: join(
            ctx.cwd,
            `${ctx.forkNativeSessionId ? "fork" : "original"}.jsonl`,
          ),
          writtenFiles: [],
        };
      },
    });
    const mgr = managerFor({ claude });
    const original = await mgr.create({ repoPath: repo, agent: "claude" });

    const forked = await mgr.forkAgent(original.session.id);

    expect(contexts.at(-1)?.forkNativeSessionId).toBe("original-id");
    expect(forked.session.id).toBe(original.session.id);
    expect(forked.session.worktree_path).toBe(original.session.worktree_path);
    expect(forked.runs).toHaveLength(2);
    expect(forked.runs[0]?.ended_at).not.toBeNull();
    expect(forked.runs[1]?.native_session_id).toBe("forked-id");
  });

  test("refuses to label an unsupported fresh launch as a native fork", async () => {
    const gemini = fakeAdapter({ name: "gemini", supportsNativeFork: false });
    const mgr = managerFor({ gemini });
    const original = await mgr.create({ repoPath: repo, agent: "gemini" });

    await expect(mgr.forkAgent(original.session.id)).rejects.toThrow(
      /gemini does not support native session forks/,
    );
    expect(mgr.view(original.session.id).runs).toHaveLength(1);
    expect(await tmux.hasSession(tmuxSessionName(original.session.id))).toBe(
      true,
    );
  });

  test("passes the configured system prompt on create and before the handoff on switch", async () => {
    const contexts: LaunchContext[] = [];
    const launchFor = (file: string) => (ctx: LaunchContext) => {
      contexts.push(ctx);
      return {
        command: ["sleep", "30"],
        nativeSessionId: `native-${ctx.sessionId}-${file}`,
        transcriptPath: join(ctx.cwd, file),
        writtenFiles: [],
      };
    };
    const claude = fakeAdapter({ buildLaunch: launchFor("claude.jsonl") });
    const codex = fakeAdapter({
      name: "codex",
      buildLaunch: launchFor("codex.jsonl"),
    });
    const mgr = new SessionManager(db, {
      adapterFor: (agent) => (agent === "codex" ? codex : claude),
      startLock: (fn) => fn(),
      systemPromptFor: () => "You are a careful reviewer.",
    });
    const original = await mgr.create({
      repoPath: repo,
      agent: "claude",
      title: "Prompt wiring",
    });
    expect(contexts.at(-1)?.systemPrompt).toBe("You are a careful reviewer.");

    await mgr.switchAgent(original.session.id, "codex");
    const systemPrompt = contexts.at(-1)?.systemPrompt ?? "";
    expect(systemPrompt).toContain("You are a careful reviewer.");
    expect(systemPrompt).toContain("Prompt wiring");
  });
});
