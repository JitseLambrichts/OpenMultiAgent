import type { Database } from "bun:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import type { AgentAdapter, McpServerSpec } from "./agent.ts";
import {
  changedFiles,
  createWorktree,
  currentBranch,
  diffStat,
  isGitRepo,
  removeWorktree,
  repoRoot,
} from "./git.ts";
import { tmuxSessionName } from "./paths.ts";
import {
  activateSession,
  createAgentRun,
  createSession,
  deleteSession,
  endActiveAgentRuns,
  endSession,
  listAgentRuns,
  listSessions,
  recordArtifact,
  reopenAgentRun,
  resolveSession,
  setTranscriptPath,
} from "./store.ts";
import * as tmux from "./tmux.ts";
import type { AgentName, AgentRun, Session } from "./types.ts";
import { buildHandoffBrief } from "./handoff.ts";
import { withFileLock } from "./lock.ts";
import type { ChangedFile } from "./git.ts";

export interface McpScope {
  sessionId: string;
  repoPath: string;
  worktreePath: string;
}

export interface SessionManagerOptions {
  /** Injected so core never imports the adapter implementations. */
  adapterFor: (agent: AgentName) => AgentAdapter;
  /**
   * MCP servers offered to the agent. A function rather than a list because the
   * memory server is scoped to the session it is started for, and the session
   * id only exists once the session row has been created.
   */
  mcpServers?: (scope: McpScope) => McpServerSpec[];
  /** Overridable for tests. */
  now?: () => Date;
  /** Cross-process start lock; replace with an in-process passthrough in tests. */
  startLock?: <T>(fn: () => Promise<T>) => Promise<T>;
  /** Poll tuning for contract tests; production defaults are intentionally patient. */
  transcriptDiscovery?: { attempts?: number; intervalMs?: number };
}

export interface CreateSessionOptions {
  repoPath: string;
  agent: AgentName;
  /** Isolate the session in its own git worktree. */
  worktree?: boolean;
  branch?: string;
  title?: string;
  prompt?: string;
  systemPrompt?: string;
}

export interface SessionView {
  session: Session;
  runs: AgentRun[];
  tmuxAlive: boolean;
}

export interface SessionStatusView extends SessionView {
  changedFiles: ChangedFile[];
  diffStat: string;
  pane: string;
}

/**
 * Owns the lifecycle of a session: worktree, tmux window, agent run and the
 * correlation back to the agent's own transcript.
 */
export class SessionManager {
  constructor(
    private readonly db: Database,
    private readonly options: SessionManagerOptions,
  ) {}

  private get now(): Date {
    return this.options.now?.() ?? new Date();
  }

  /**
   * Codex identifies its transcript by "newest rollout in this cwd", which is a
   * race if two Codex sessions start at once. Serialising starts removes it;
   * Claude does not need this but the queue is cheap.
   */
  private startQueue: Promise<unknown> = Promise.resolve();

  private serialise<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.startQueue.then(fn, fn);
    this.startQueue = next.catch(() => undefined);
    return next;
  }

  private withStartLock<T>(fn: () => Promise<T>): Promise<T> {
    return this.options.startLock?.(fn) ?? withFileLock("agent-start", fn);
  }

  private get discoveryAttempts(): number {
    return this.options.transcriptDiscovery?.attempts ?? 20;
  }

  private get discoveryIntervalMs(): number {
    return this.options.transcriptDiscovery?.intervalMs ?? 500;
  }

  /** Prepare and verify the real replacement before stopping the current run. */
  private async replaceTmuxSession(
    session: Session,
    launch: { command: string[]; env?: Record<string, string> },
    beforeReplace?: () => Promise<void>,
  ): Promise<void> {
    const target = tmuxSessionName(session.id);
    const staging = `_oma-staging-${session.id.slice(0, 8)}-${randomUUID().slice(0, 8)}`;
    const backup = `_oma-backup-${session.id.slice(0, 8)}-${randomUUID().slice(0, 8)}`;
    let oldRenamed = false;
    let stagingRenamed = false;
    try {
      await tmux.newSession({
        name: staging,
        cwd: session.worktree_path,
        command: shellQuote(launch.command),
        env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...launch.env },
      });
      await Bun.sleep(200);
      if (!(await tmux.hasSession(staging))) {
        throw new Error("replacement agent exited during startup");
      }
      await beforeReplace?.();
      if (await tmux.hasSession(target)) {
        await tmux.renameSession(target, backup);
        oldRenamed = true;
      }
      await tmux.renameSession(staging, target);
      stagingRenamed = true;
      await Bun.sleep(200);
      if (!(await tmux.hasSession(target))) {
        throw new Error("replacement agent exited during activation");
      }
      if (oldRenamed) await tmux.killSession(backup);
    } catch (error) {
      await tmux.killSession(staging);
      if (stagingRenamed) await tmux.killSession(target);
      if (oldRenamed && (await tmux.hasSession(backup))) {
        await tmux.renameSession(backup, target);
      }
      throw error;
    }
  }

  async create(opts: CreateSessionOptions): Promise<SessionView> {
    return this.serialise(() =>
      this.withStartLock(() => this.createUnsafe(opts)),
    );
  }

  private async createUnsafe(opts: CreateSessionOptions): Promise<SessionView> {
    const adapter = this.options.adapterFor(opts.agent);
    if (!(await adapter.isAvailable())) {
      throw new Error(`'${adapter.binary}' is not on PATH`);
    }
    if (!(await tmux.tmuxAvailable())) {
      throw new Error("tmux is not on PATH");
    }

    const repoPath = resolve(opts.repoPath);
    if (!(await isGitRepo(repoPath))) {
      throw new Error(`${repoPath} is not a git repository`);
    }
    const root = await repoRoot(repoPath);

    const session = createSession(this.db, {
      repo_path: root,
      worktree_path: root, // replaced below when a worktree is created
      branch: await currentBranch(root),
      title: opts.title ?? null,
    });

    let worktreePath = root;
    try {
      if (opts.worktree) {
        const branch = opts.branch ?? `oma/${session.id.slice(0, 8)}`;
        const created = await createWorktree(root, branch);
        worktreePath = created.path;
        this.db.run(
          "UPDATE session SET worktree_path = ?, branch = ? WHERE id = ?",
          [created.path, created.branch, session.id],
        );
      }

      const startedAt = this.now;
      const launch = adapter.buildLaunch({
        sessionId: session.id,
        cwd: worktreePath,
        prompt: opts.prompt,
        systemPrompt: opts.systemPrompt,
        mcpServers: this.options.mcpServers?.({
          sessionId: session.id,
          repoPath: root,
          worktreePath,
        }),
      });

      const run = createAgentRun(this.db, {
        session_id: session.id,
        agent: opts.agent,
        native_session_id: launch.nativeSessionId,
        transcript_path: launch.transcriptPath,
      });

      await this.startTmuxSession(session.id, worktreePath, launch);

      // Codex only reveals its transcript once it has written `session_meta`,
      // so the path is filled in on a short poll rather than at launch.
      // A plain terminal never publishes a transcript, so skip discovery.
      if (!launch.transcriptPath && adapter.name !== "terminal") {
        const discovery = this.discoverTranscript(
          adapter,
          run.id,
          worktreePath,
          startedAt,
          launch.nativeSessionId,
          undefined,
          this.discoveryAttempts,
          this.discoveryIntervalMs,
        );
        if (adapter.name === "codex") {
          if (!(await discovery)) {
            throw new Error("codex did not publish a correlatable transcript");
          }
        } else void discovery;
      }

      return this.liveView(session.id);
    } catch (error) {
      // Never leave a half-created session behind in the DB.
      await this.cleanup(session.id, { force: true });
      throw error;
    }
  }

  /** Polls until the agent has written enough for its transcript to be found. */
  private async discoverTranscript(
    adapter: AgentAdapter,
    runId: string,
    cwd: string,
    startedAt: Date,
    nativeSessionId?: string | null,
    excludeNativeSessionId?: string | null,
    attempts = 20,
    intervalMs = 500,
  ): Promise<string | null> {
    const path = await this.resolveTranscriptWithRetry(
      adapter,
      cwd,
      startedAt,
      nativeSessionId,
      excludeNativeSessionId,
      attempts,
      intervalMs,
    );
    if (path) setTranscriptPath(this.db, runId, path);
    return path;
  }

  private async resolveTranscriptWithRetry(
    adapter: AgentAdapter,
    cwd: string,
    startedAt: Date,
    nativeSessionId?: string | null,
    excludeNativeSessionId?: string | null,
    attempts = 20,
    intervalMs = 500,
  ): Promise<string | null> {
    for (let i = 0; i < attempts; i++) {
      const path = await adapter.resolveTranscript({
        cwd,
        startedAt,
        nativeSessionId,
        excludeNativeSessionId,
      });
      if (path) return path;
      await Bun.sleep(intervalMs);
    }
    return null;
  }

  view(sessionId: string): SessionView {
    const session = resolveSession(this.db, sessionId);
    return {
      session,
      runs: listAgentRuns(this.db, session.id),
      tmuxAlive: false,
    };
  }

  private async liveView(sessionId: string): Promise<SessionView> {
    const session = resolveSession(this.db, sessionId);
    return {
      session,
      runs: listAgentRuns(this.db, session.id),
      tmuxAlive: await tmux.hasSession(tmuxSessionName(session.id)),
    };
  }

  private async startTmuxSession(
    sessionId: string,
    cwd: string,
    launch: { command: string[]; env?: Record<string, string> },
  ): Promise<void> {
    const name = tmuxSessionName(sessionId);
    await tmux.newSession({
      name,
      cwd,
      command: shellQuote(launch.command),
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...launch.env },
    });
    await Bun.sleep(200);
    if (!(await tmux.hasSession(name))) {
      throw new Error(
        `'${launch.command[0] ?? "agent"}' exited during startup`,
      );
    }
  }

  async list(): Promise<SessionView[]> {
    const alive = new Set((await tmux.listSessions()).map((s) => s.sessionId));
    return listSessions(this.db).map((session) => ({
      session,
      runs: listAgentRuns(this.db, session.id),
      tmuxAlive: alive.has(session.id),
    }));
  }

  async status(sessionId: string): Promise<SessionStatusView> {
    const view = this.view(sessionId);
    const name = tmuxSessionName(view.session.id);
    return {
      ...view,
      tmuxAlive: await tmux.hasSession(name),
      changedFiles: await changedFiles(view.session.worktree_path),
      diffStat: await diffStat(view.session.worktree_path),
      pane: await tmux.capturePane(name, 80),
    };
  }

  async switchAgent(
    sessionId: string,
    agent: AgentName,
    opts: { prompt?: string } = {},
  ): Promise<SessionView> {
    return this.serialise(() =>
      this.withStartLock(async () => {
        const session = resolveSession(this.db, sessionId);
        if (!existsSync(session.worktree_path)) {
          throw new Error(
            `session worktree no longer exists: ${session.worktree_path}`,
          );
        }
        const adapter = this.options.adapterFor(agent);
        if (!(await adapter.isAvailable())) {
          throw new Error(`'${adapter.binary}' is not on PATH`);
        }
        if (!(await tmux.tmuxAvailable()))
          throw new Error("tmux is not on PATH");

        await this.snapshotArtifacts(session);
        const handoff = buildHandoffBrief(this.db, session.id, {
          diffStat: await diffStat(session.worktree_path),
        });
        const startedAt = this.now;
        const launch = adapter.buildLaunch({
          sessionId: session.id,
          cwd: session.worktree_path,
          prompt: opts.prompt ?? "Continue the task from the Handoff Brief.",
          systemPrompt: handoff,
          mcpServers: this.options.mcpServers?.({
            sessionId: session.id,
            repoPath: session.repo_path,
            worktreePath: session.worktree_path,
          }),
        });

        let transcriptPath = launch.transcriptPath;
        await this.replaceTmuxSession(
          session,
          launch,
          adapter.name === "codex" && !transcriptPath
            ? async () => {
                transcriptPath = await this.resolveTranscriptWithRetry(
                  adapter,
                  session.worktree_path,
                  startedAt,
                  launch.nativeSessionId,
                  undefined,
                  this.discoveryAttempts,
                  this.discoveryIntervalMs,
                );
                if (!transcriptPath) {
                  throw new Error(
                    "codex did not publish a correlatable transcript",
                  );
                }
              }
            : undefined,
        );
        endActiveAgentRuns(this.db, session.id);
        const run = createAgentRun(this.db, {
          session_id: session.id,
          agent,
          native_session_id: launch.nativeSessionId,
          transcript_path: transcriptPath,
        });
        activateSession(this.db, session.id);
        if (!transcriptPath && adapter.name !== "terminal") {
          const discovery = this.discoverTranscript(
            adapter,
            run.id,
            session.worktree_path,
            startedAt,
            launch.nativeSessionId,
          );
          void discovery;
        }
        return this.liveView(session.id);
      }),
    );
  }

  async resume(sessionId: string): Promise<SessionView> {
    return this.serialise(() =>
      this.withStartLock(async () => {
        const session = resolveSession(this.db, sessionId);
        if (!existsSync(session.worktree_path)) {
          throw new Error(
            `session worktree no longer exists: ${session.worktree_path}`,
          );
        }
        const runs = listAgentRuns(this.db, session.id);
        const run = runs.at(-1);
        if (!run) throw new Error("session has no agent run to resume");
        const isTerminal = run.agent === "terminal";
        if (!isTerminal && !run.native_session_id) {
          throw new Error(
            `cannot resume ${run.agent}: its native session id has not been discovered yet`,
          );
        }
        if (await tmux.hasSession(tmuxSessionName(session.id))) {
          throw new Error("session is already running");
        }
        const adapter = this.options.adapterFor(run.agent);
        if (!(await adapter.isAvailable())) {
          throw new Error(`'${adapter.binary}' is not on PATH`);
        }
        const launch = adapter.buildLaunch({
          sessionId: session.id,
          cwd: session.worktree_path,
          resumeNativeSessionId: run.native_session_id ?? undefined,
          mcpServers: isTerminal
            ? undefined
            : this.options.mcpServers?.({
                sessionId: session.id,
                repoPath: session.repo_path,
                worktreePath: session.worktree_path,
              }),
        });
        await this.startTmuxSession(session.id, session.worktree_path, launch);
        reopenAgentRun(this.db, run.id);
        activateSession(this.db, session.id);
        return this.liveView(session.id);
      }),
    );
  }

  async forkAgent(
    sessionId: string,
    opts: { prompt?: string } = {},
  ): Promise<SessionView> {
    return this.serialise(() =>
      this.withStartLock(async () => {
        const session = resolveSession(this.db, sessionId);
        if (!existsSync(session.worktree_path)) {
          throw new Error(
            `session worktree no longer exists: ${session.worktree_path}`,
          );
        }
        const previous = listAgentRuns(this.db, session.id).at(-1);
        if (!previous) throw new Error("session has no agent run to fork");
        if (!previous.native_session_id) {
          throw new Error(
            `cannot fork ${previous.agent}: its native session id has not been discovered yet`,
          );
        }
        const adapter = this.options.adapterFor(previous.agent);
        if (adapter.supportsNativeFork === false) {
          throw new Error(
            `${previous.agent} does not support native session forks`,
          );
        }
        if (!(await adapter.isAvailable())) {
          throw new Error(`'${adapter.binary}' is not on PATH`);
        }
        await this.snapshotArtifacts(session);
        const handoff = buildHandoffBrief(this.db, session.id, {
          diffStat: await diffStat(session.worktree_path),
        });
        const startedAt = this.now;
        const launch = adapter.buildLaunch({
          sessionId: session.id,
          cwd: session.worktree_path,
          forkNativeSessionId: previous.native_session_id,
          systemPrompt: handoff,
          prompt: opts.prompt,
          mcpServers: this.options.mcpServers?.({
            sessionId: session.id,
            repoPath: session.repo_path,
            worktreePath: session.worktree_path,
          }),
        });
        let transcriptPath = launch.transcriptPath;
        await this.replaceTmuxSession(
          session,
          launch,
          adapter.name === "codex" && !transcriptPath
            ? async () => {
                transcriptPath = await this.resolveTranscriptWithRetry(
                  adapter,
                  session.worktree_path,
                  startedAt,
                  launch.nativeSessionId,
                  previous.native_session_id,
                  this.discoveryAttempts,
                  this.discoveryIntervalMs,
                );
                if (!transcriptPath) {
                  throw new Error(
                    "codex did not publish a correlatable transcript",
                  );
                }
              }
            : undefined,
        );
        endActiveAgentRuns(this.db, session.id);
        const run = createAgentRun(this.db, {
          session_id: session.id,
          agent: previous.agent,
          native_session_id: launch.nativeSessionId,
          transcript_path: transcriptPath,
        });
        activateSession(this.db, session.id);
        if (!transcriptPath) {
          const discovery = this.discoverTranscript(
            adapter,
            run.id,
            session.worktree_path,
            startedAt,
            launch.nativeSessionId,
            previous.native_session_id,
          );
          void discovery;
        }
        return this.liveView(session.id);
      }),
    );
  }

  attachCommand(sessionId: string): string[] {
    const session = resolveSession(this.db, sessionId);
    return tmux.attachCommand(session.id);
  }

  /** Records which files the session changed, before the worktree disappears. */
  private async snapshotArtifacts(session: Session): Promise<void> {
    if (!existsSync(session.worktree_path)) return;
    for (const file of await changedFiles(session.worktree_path)) {
      recordArtifact(
        this.db,
        session.id,
        file.path,
        file.status === "D"
          ? "deleted"
          : file.status === "??"
            ? "created"
            : "modified",
      );
    }
  }

  /** Ends the session but keeps its history: the memory outlives the session. */
  async end(sessionId: string): Promise<void> {
    const session = resolveSession(this.db, sessionId);
    await this.snapshotArtifacts(session);
    await tmux.killSession(tmuxSessionName(session.id));
    endSession(this.db, session.id);
  }

  async remove(
    sessionId: string,
    opts: { force?: boolean; keepWorktree?: boolean } = {},
  ): Promise<void> {
    const session = resolveSession(this.db, sessionId);
    await this.snapshotArtifacts(session);
    await this.cleanup(session.id, opts);
  }

  private async cleanup(
    sessionId: string,
    opts: { force?: boolean; keepWorktree?: boolean } = {},
  ): Promise<void> {
    const session = resolveSession(this.db, sessionId);
    await tmux.killSession(tmuxSessionName(session.id));

    if (!opts.keepWorktree && session.worktree_path !== session.repo_path) {
      await removeWorktree(session.repo_path, session.worktree_path, {
        force: opts.force,
      });
      // `git worktree remove` refuses when the tree is dirty and --force is off;
      // if it survived that, drop the directory too so nothing is left dangling.
      if (opts.force && existsSync(session.worktree_path)) {
        rmSync(session.worktree_path, { recursive: true, force: true });
      }
    }

    endSession(this.db, session.id);
    deleteSession(this.db, session.id);
  }
}

/**
 * tmux takes the command as a single shell string, so arguments containing
 * spaces or newlines (a Handoff Brief does) must be quoted.
 */
export function shellQuote(argv: string[]): string {
  return argv
    .map((arg) =>
      /^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replaceAll("'", `'\\''`)}'`,
    )
    .join(" ");
}
