import { describe, expect, test } from "bun:test";
import type { Project, Session } from "@oma/core";
import { DesktopError, type DesktopServices } from "./services.ts";
import { createRouter } from "./router.ts";

const project: Project = {
  id: "project-1",
  repo_path: "/repo",
  display_name: "Repo",
  created_at: "2026-08-11T10:00:00.000Z",
  last_opened_at: "2026-08-11T10:00:00.000Z",
};

const session: Session = {
  id: "session-1",
  repo_path: "/repo",
  worktree_path: "/repo",
  branch: "main",
  title: "Build M4",
  status: "active",
  started_at: "2026-08-11T10:00:00.000Z",
  ended_at: null,
};

function services(overrides: Partial<DesktopServices> = {}): DesktopServices {
  return {
    hello: async () => ({
      protocol_version: 1,
      app_version: "0.1.0",
      agents: ["claude", "codex", "gemini"],
    }),
    health: async () => ({ ok: true, tmux_available: true }),
    shutdown: async () => ({ shutting_down: true }),
    projectList: async () => [project],
    projectAdd: async () => project,
    projectDetail: async () => ({ project, sessions: [] }),
    projectRemove: async () => ({ removed_project_id: project.id }),
    sessionList: async () => [],
    sessionStatus: async () => ({
      session,
      runs: [],
      tmux_alive: true,
      changed_files: [],
      diff_stat: "",
      pane: "",
    }),
    sessionCreate: async () => ({ session, runs: [], tmux_alive: true }),
    sessionResume: async () => ({ session, runs: [], tmux_alive: true }),
    sessionSwitch: async () => ({ session, runs: [], tmux_alive: true }),
    sessionEnd: async () => ({ ended_session_id: session.id }),
    sessionRemove: async () => ({ removed_session_id: session.id }),
    transcriptList: async () => ({ items: [], next_cursor: null }),
    memoryList: async () => [],
    memorySearch: async () => [],
    docsList: async () => [],
    promotionExtract: async () => ({ candidate_count: 0 }),
    promotionPreview: async () => ({ diff: "", candidate_count: 0 }),
    promotionApply: async () => ({ promoted: 0, files: [] }),
    terminalAttachment: async () => ({
      executable: "/opt/homebrew/bin/tmux",
      arguments: ["attach", "-t", "oma-session-1"],
      cwd: "/repo",
    }),
    customAgentList: async () => [],
    customAgentAdd: async (input) => ({
      id: input.id ?? "opencode",
      name: input.name ?? "opencode",
      binary: input.binary ?? "opencode",
      launch_args: input.launchArgs ?? [],
      symbol: input.symbol ?? "terminal",
    }),
    customAgentUpdate: async (input) => ({
      id: input.id,
      name: input.name ?? input.id,
      binary: input.binary ?? input.id,
      launch_args: input.launchArgs ?? [],
      symbol: input.symbol ?? "terminal",
    }),
    customAgentRemove: async (input) => ({ removed_agent_id: input.id }),
    ...overrides,
  };
}

describe("desktop router", () => {
  test("returns the protocol handshake", async () => {
    const response = await createRouter(services()).dispatch({
      jsonrpc: "2.0",
      id: 1,
      method: "system.hello",
      params: {},
    });

    expect(response).toEqual({
      jsonrpc: "2.0",
      id: 1,
      result: {
        protocol_version: 1,
        app_version: "0.1.0",
        agents: ["claude", "codex", "gemini"],
      },
    });
  });

  test("creates a custom agent with snake_case wire keys", async () => {
    const response = await createRouter(services()).dispatch({
      jsonrpc: "2.0",
      id: "add-agent",
      method: "agent.add",
      params: {
        name: "Opencode",
        binary: "opencode",
        launch_args: ["run"],
        symbol: "terminal.fill",
      },
    });

    expect(response).toMatchObject({
      id: "add-agent",
      result: {
        id: "opencode",
        name: "Opencode",
        binary: "opencode",
        launch_args: ["run"],
        symbol: "terminal.fill",
      },
    });
  });

  test("rejects project.add without a repository path", async () => {
    const response = await createRouter(services()).dispatch({
      jsonrpc: "2.0",
      id: 2,
      method: "project.add",
      params: {},
    });

    expect(response).toMatchObject({
      error: { code: -32001, message: "repo_path must be a non-empty string" },
    });
  });

  test("dispatches a valid session creation request", async () => {
    const response = await createRouter(services()).dispatch({
      jsonrpc: "2.0",
      id: "create",
      method: "session.create",
      params: {
        repo_path: "/repo",
        agent: "claude",
        worktree: true,
        title: "Build M4",
      },
    });

    expect(response).toMatchObject({
      id: "create",
      result: {
        session: { id: "session-1", repo_path: "/repo" },
        tmux_alive: true,
      },
    });
  });

  test("maps domain failures to stable application errors", async () => {
    const response = await createRouter(
      services({
        projectAdd: async () => {
          throw new DesktopError(-32001, "Not a Git repository", {
            repo_path: "/plain",
          });
        },
      }),
    ).dispatch({
      jsonrpc: "2.0",
      id: 3,
      method: "project.add",
      params: { repo_path: "/plain" },
    });

    expect(response).toEqual({
      jsonrpc: "2.0",
      id: 3,
      error: {
        code: -32001,
        message: "Not a Git repository",
        data: { repo_path: "/plain" },
      },
    });
  });

  test("returns the standard method-not-found error", async () => {
    const response = await createRouter(services()).dispatch({
      jsonrpc: "2.0",
      id: 4,
      method: "project.rename",
      params: {},
    });

    expect(response).toMatchObject({
      error: { code: -32601, message: "Method not found: project.rename" },
    });
  });

  test("executes a notification without emitting a response", async () => {
    const response = await createRouter(services()).dispatch({
      jsonrpc: "2.0",
      method: "system.shutdown",
      params: {},
    });

    expect(response).toBeNull();
  });
});

describe("desktop router diagnostics", () => {
  test("keeps the underlying message as debug detail for unexpected failures", async () => {
    const response = await createRouter(
      services({
        sessionResume: async () => {
          throw new Error("worktree vanished");
        },
      }),
    ).dispatch({
      jsonrpc: "2.0",
      id: 9,
      method: "session.resume",
      params: { session_id: "session-1" },
    });

    expect(response).toEqual({
      jsonrpc: "2.0",
      id: 9,
      error: {
        code: -32005,
        message: "Operation failed",
        data: { detail: "worktree vanished" },
      },
    });
  });
});
