import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Database } from "bun:sqlite";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAgentRun,
  createSession,
  exec,
  openDb,
  resolveSession,
} from "@oma/core";
import {
  createDesktopServices,
  DesktopError,
  type SessionOperations,
} from "./services.ts";
import { AUTO_EXTRACT_MIN_EVENTS, saveCandidates } from "@oma/docs";

let db: Database;
const tempDirs: string[] = [];

beforeEach(() => {
  db = openDb({ path: ":memory:" });
});

afterEach(() => {
  db.close();
  while (tempDirs.length) {
    rmSync(tempDirs.pop()!, { recursive: true, force: true });
  }
});

async function makeRepo(): Promise<string> {
  const directory = mkdtempSync(join(tmpdir(), "oma-desktop-repo-"));
  tempDirs.push(directory);
  await exec(["git", "init", "-b", "main"], { cwd: directory });
  return realpathSync(directory);
}

function sessionOperations(): SessionOperations {
  return {
    list: async () => [],
    status: async (id) => {
      const stored = resolveSession(db, id);
      return {
        session: stored,
        runs: [],
        tmuxAlive: true,
        changedFiles: [{ path: "README.md", status: "M" }],
        diffStat: " README.md | 1 +",
        pane: "agent output",
      };
    },
    create: async () => {
      throw new Error("not used");
    },
    resume: async () => {
      throw new Error("not used");
    },
    switchAgent: async () => {
      throw new Error("not used");
    },
    end: async () => undefined,
    remove: async () => undefined,
  };
}

describe("desktop services", () => {
  test("registers only Git repositories and keeps explicit display names", async () => {
    const repo = await makeRepo();
    const service = createDesktopServices({ db, manager: sessionOperations() });

    const added = await service.projectAdd({
      repo_path: repo,
      display_name: "OMA Desktop",
    });

    expect(added).toMatchObject({
      repo_path: repo,
      display_name: "OMA Desktop",
    });
    expect(await service.projectList()).toEqual([added]);
  });

  test("rejects a directory that is not a Git repository", async () => {
    const directory = mkdtempSync(join(tmpdir(), "oma-desktop-plain-"));
    tempDirs.push(directory);
    const service = createDesktopServices({ db, manager: sessionOperations() });

    try {
      await service.projectAdd({ repo_path: directory });
      throw new Error("projectAdd unexpectedly succeeded");
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopError);
      expect(error).toMatchObject({
        code: -32001,
        message: "Not a Git repository",
      });
    }
  });

  test("removes only project registration and retains sessions", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const service = createDesktopServices({ db, manager: sessionOperations() });
    const [project] = await service.projectList();

    expect(await service.projectRemove({ project_id: project!.id })).toEqual({
      removed_project_id: project!.id,
    });
    expect(resolveSession(db, storedSession.id).id).toBe(storedSession.id);
  });

  test("maps core status fields to the desktop wire contract", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    createAgentRun(db, {
      session_id: storedSession.id,
      agent: "claude",
    });
    const service = createDesktopServices({ db, manager: sessionOperations() });

    expect(
      await service.sessionStatus({ session_id: storedSession.id }),
    ).toEqual({
      session: storedSession,
      runs: [],
      tmux_alive: true,
      changed_files: [{ path: "README.md", status: "M" }],
      diff_stat: " README.md | 1 +",
      pane: "agent output",
    });
  });
});

describe("desktop lifecycle error mapping", () => {
  test("maps a dirty worktree removal to a conflict with a keep-worktree recovery", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: join(repo, ".worktrees", "m4"),
    });
    const operations = sessionOperations();
    operations.remove = async () => {
      throw new Error(
        "fatal: '/repo/.worktrees/m4' contains modified or untracked files, use --force to delete it",
      );
    };
    const service = createDesktopServices({ db, manager: operations });

    try {
      await service.sessionRemove({ session_id: storedSession.id });
      throw new Error("expected a DesktopError");
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopError);
      expect(error).toMatchObject({
        code: -32003,
        data: {
          recovery: "keep_worktree_or_force",
          session_id: storedSession.id,
        },
      });
    }
  });

  test("maps a merge with uncommitted changes to a commit-first conflict", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: join(repo, ".worktrees", "m4"),
    });
    const operations = sessionOperations();
    let mergeFlag: boolean | undefined;
    operations.end = async (_id, opts) => {
      mergeFlag = opts?.merge;
      throw new Error(
        "worktree has uncommitted changes, commit first before merging",
      );
    };
    const service = createDesktopServices({ db, manager: operations });

    try {
      await service.sessionEnd({ session_id: storedSession.id, merge: true });
      throw new Error("expected a DesktopError");
    } catch (error) {
      expect(error).toMatchObject({
        code: -32003,
        data: {
          recovery: "commit_first",
          session_id: storedSession.id,
        },
      });
    }
    expect(mergeFlag).toBe(true);
  });

  test("maps a conflicting merge to a resolve-conflicts error", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: join(repo, ".worktrees", "m4"),
      branch: "oma/m4",
    });
    const operations = sessionOperations();
    operations.end = async () => {
      throw new Error(
        "merge conflict merging 'oma/m4' into 'main', merge aborted: CONFLICT",
      );
    };
    const service = createDesktopServices({ db, manager: operations });

    try {
      await service.sessionEnd({ session_id: storedSession.id, merge: true });
      throw new Error("expected a DesktopError");
    } catch (error) {
      expect(error).toMatchObject({
        code: -32005,
        data: {
          recovery: "resolve_conflicts",
          session_id: storedSession.id,
        },
      });
    }
  });

  test("reports whether the session was merged on end", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const service = createDesktopServices({ db, manager: sessionOperations() });

    expect(await service.sessionEnd({ session_id: storedSession.id })).toEqual({
      ended_session_id: storedSession.id,
      merged: false,
    });
  });

  test("maps a missing agent binary to an unavailable error", async () => {
    const operations = sessionOperations();
    operations.create = async () => {
      throw new Error("'codex' is not on PATH");
    };
    const service = createDesktopServices({ db, manager: operations });

    try {
      await service.sessionCreate({ repo_path: "/repo", agent: "codex" });
      throw new Error("expected a DesktopError");
    } catch (error) {
      expect(error).toMatchObject({
        code: -32002,
        data: { recovery: "install_binary", agent: "codex" },
      });
    }
  });
});

describe("promotion extraction", () => {
  test("extracts knowledge and reports the pending candidate count", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      extractKnowledge: async (sessionId) => {
        saveCandidates(db, sessionId, [
          {
            kind: "decision",
            title: "Use Redis Streams",
            body: "Replay is required.",
            confidence: 0.9,
            supersedes_memory_id: null,
          },
        ]);
        return 1;
      },
    });

    expect(
      await service.promotionExtract({ session_id: storedSession.id }),
    ).toEqual({ candidate_count: 1 });
  });

  test("ends a session before auto-extracting, and still ends it when extraction fails", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const calls: string[] = [];
    const operations = sessionOperations();
    operations.end = async () => {
      calls.push("end");
    };
    const service = createDesktopServices({
      db,
      manager: operations,
      extractKnowledge: async () => {
        calls.push("extract");
        throw new Error("'claude' is not on PATH");
      },
    });

    const result = await service.sessionEnd({ session_id: storedSession.id });

    expect(result).toEqual({
      ended_session_id: storedSession.id,
      merged: false,
    });
    expect(calls).toEqual(["end", "extract"]);
  });

  test("guards a session against overlapping extraction calls", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    let extractCalls = 0;
    let releaseFirstCall: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      releaseFirstCall = resolve;
    });
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      extractKnowledge: async (sessionId) => {
        extractCalls += 1;
        await gate;
        saveCandidates(db, sessionId, [
          {
            kind: "decision",
            title: "Use Redis Streams",
            body: "Replay is required.",
            confidence: 0.9,
            supersedes_memory_id: null,
          },
        ]);
        return 1;
      },
    });

    const first = service.promotionExtract({ session_id: storedSession.id });
    await Bun.sleep(0);
    const second = service.promotionExtract({ session_id: storedSession.id });
    releaseFirstCall?.();

    const [firstResult, secondResult] = await Promise.all([first, second]);

    expect(extractCalls).toBe(1);
    expect(firstResult).toEqual({ candidate_count: 1 });
    expect(secondResult).toEqual({ candidate_count: 1 });
  });

  test("does not extract when the session is below the auto-extract threshold", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    let extractCalls = 0;
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      ingestSessionEvents: () => AUTO_EXTRACT_MIN_EVENTS - 1,
      extractKnowledge: async () => {
        extractCalls += 1;
        return 0;
      },
    });

    expect(
      await service.promotionAutoCheck({ session_id: storedSession.id }),
    ).toEqual({ candidate_count: 0 });
    expect(extractCalls).toBe(0);
  });

  test("extracts once the session reaches the auto-extract threshold", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    let extractCalls = 0;
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      ingestSessionEvents: () => AUTO_EXTRACT_MIN_EVENTS,
      extractKnowledge: async (sessionId) => {
        extractCalls += 1;
        saveCandidates(db, sessionId, [
          {
            kind: "decision",
            title: "Use Redis Streams",
            body: "Replay is required.",
            confidence: 0.9,
            supersedes_memory_id: null,
          },
        ]);
        return 1;
      },
    });

    expect(
      await service.promotionAutoCheck({ session_id: storedSession.id }),
    ).toEqual({ candidate_count: 1 });
    expect(extractCalls).toBe(1);
  });

  test("never throws when the threshold is reached but extraction fails", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      ingestSessionEvents: () => AUTO_EXTRACT_MIN_EVENTS,
      extractKnowledge: async () => {
        throw new Error("'claude' is not on PATH");
      },
    });

    expect(
      await service.promotionAutoCheck({ session_id: storedSession.id }),
    ).toEqual({ candidate_count: 0 });
  });

  test("shares the extraction guard with the manual Extract Knowledge button", async () => {
    const repo = await makeRepo();
    const storedSession = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    let extractCalls = 0;
    let releaseFirstCall: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      releaseFirstCall = resolve;
    });
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      ingestSessionEvents: () => AUTO_EXTRACT_MIN_EVENTS,
      extractKnowledge: async (sessionId) => {
        extractCalls += 1;
        await gate;
        saveCandidates(db, sessionId, [
          {
            kind: "decision",
            title: "Use Redis Streams",
            body: "Replay is required.",
            confidence: 0.9,
            supersedes_memory_id: null,
          },
        ]);
        return 1;
      },
    });

    const auto = service.promotionAutoCheck({ session_id: storedSession.id });
    await Bun.sleep(0);
    const manual = service.promotionExtract({ session_id: storedSession.id });
    releaseFirstCall?.();

    const [autoResult, manualResult] = await Promise.all([auto, manual]);

    expect(extractCalls).toBe(1);
    expect(autoResult).toEqual({ candidate_count: 1 });
    expect(manualResult).toEqual({ candidate_count: 1 });
  });

  test("sums pending candidates across every session for the sidebar badge", async () => {
    const repo = await makeRepo();
    const sessionA = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const sessionB = createSession(db, {
      repo_path: repo,
      worktree_path: repo,
    });
    const service = createDesktopServices({ db, manager: sessionOperations() });

    expect(await service.promotionPendingCount()).toEqual({ count: 0 });

    saveCandidates(db, sessionA.id, [
      {
        kind: "decision",
        title: "A",
        body: "a",
        confidence: 0.9,
        supersedes_memory_id: null,
      },
    ]);
    saveCandidates(db, sessionB.id, [
      {
        kind: "risk",
        title: "B",
        body: "b",
        confidence: 0.8,
        supersedes_memory_id: null,
      },
    ]);

    expect(await service.promotionPendingCount()).toEqual({ count: 2 });
  });
});

describe("desktop health", () => {
  test("reports a missing tmux instead of failing the request", async () => {
    const service = createDesktopServices({
      db,
      manager: sessionOperations(),
      checkTmux: async () => {
        throw new Error('Executable not found in $PATH: "tmux"');
      },
    });

    expect(await service.health()).toEqual({
      ok: false,
      tmux_available: false,
    });
  });
});

describe("custom agents", () => {
  test("round-trips providers with snake_case wire keys", async () => {
    const home = mkdtempSync(join(tmpdir(), "oma-agents-home-"));
    tempDirs.push(home);
    const previous = process.env.OMA_HOME;
    process.env.OMA_HOME = home;
    try {
      const service = createDesktopServices({
        db,
        manager: sessionOperations(),
      });

      const added = await service.customAgentAdd({
        name: "Opencode",
        binary: "opencode",
        launchArgs: ["run"],
      });
      expect(added).toEqual({
        id: "opencode",
        name: "Opencode",
        binary: "opencode",
        launch_args: ["run"],
        symbol: "terminal",
      });
      expect(JSON.stringify(added)).not.toContain("launchArgs");

      expect(await service.customAgentList()).toEqual([added]);

      const updated = await service.customAgentUpdate({
        id: "opencode",
        launchArgs: [],
        symbol: "cursorarrow",
      });
      expect(updated).toMatchObject({
        id: "opencode",
        launch_args: [],
        symbol: "cursorarrow",
      });

      expect(await service.customAgentRemove({ id: "opencode" })).toEqual({
        removed_agent_id: "opencode",
      });
      expect(await service.customAgentList()).toEqual([]);
    } finally {
      if (previous === undefined) delete process.env.OMA_HOME;
      else process.env.OMA_HOME = previous;
    }
  });

  test("round-trips per-agent system prompts", async () => {
    const home = mkdtempSync(join(tmpdir(), "oma-prompts-home-"));
    tempDirs.push(home);
    const previous = process.env.OMA_HOME;
    process.env.OMA_HOME = home;
    try {
      const service = createDesktopServices({
        db,
        manager: sessionOperations(),
      });

      expect(await service.agentSystemPromptList()).toEqual([]);
      const saved = await service.agentSystemPromptSet({
        agent: "Claude",
        system_prompt: "  You are concise.  ",
      });
      expect(saved).toEqual({
        agent: "claude",
        system_prompt: "You are concise.",
      });
      expect(await service.agentSystemPromptGet({ agent: "claude" })).toEqual(
        saved,
      );
      expect(await service.agentSystemPromptList()).toEqual([saved]);

      const cleared = await service.agentSystemPromptSet({
        agent: "claude",
        system_prompt: "   ",
      });
      expect(cleared).toEqual({ agent: "claude", system_prompt: "" });
      expect(await service.agentSystemPromptList()).toEqual([]);
    } finally {
      if (previous === undefined) delete process.env.OMA_HOME;
      else process.env.OMA_HOME = previous;
    }
  });
});
