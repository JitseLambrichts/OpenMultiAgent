import { randomUUID } from "node:crypto";
import { join, isAbsolute, relative, resolve, dirname } from "node:path";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import type {
  AgentRun,
  AgentName,
  ChangedFile,
  CreateSessionOptions,
  Database,
  EventPage,
  Memory,
  MemoryKind,
  Project,
  SearchHit,
  Session,
  SessionStatusView,
  SessionStatus,
  SessionView,
} from "@oma/core";
import {
  createProject,
  exec,
  fileDiff,
  isGitRepo,
  listedFiles,
  listAgentRuns,
  listEventsPage,
  listMemory,
  listProjects,
  removeProject,
  repoRoot,
  resolveProject,
  resolveSession,
  search,
  repoDocsDir,
  tmuxSessionName,
  SessionManager,
  tmux,
} from "@oma/core";
import { adapterFor, availableAgents } from "@oma/adapters";
import {
  addCustomAgent,
  listCustomAgents,
  removeCustomAgent,
  updateCustomAgent,
  type CustomAgentDef,
} from "@oma/core";
import {
  getAgentSystemPrompt,
  listAgentSystemPrompts,
  normalizePromptAgent,
  setAgentSystemPrompt,
} from "@oma/core";
import {
  countPendingCandidates,
  extractSession,
  listCandidates,
  previewPromotion,
  promoteSession,
  shouldAutoExtract,
} from "@oma/docs";
import { ingestRun } from "@oma/ingest";

export class DesktopError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "DesktopError";
  }
}

const DIRTY_WORKTREE = /modified or untracked files|use --force/i;
const COMMIT_FIRST = /uncommitted changes, commit first/i;
const MERGE_CONFLICT = /merge conflict|Automatic merge failed/i;
const MISSING_BINARY = /is not on PATH/i;

/**
 * Core throws plain Errors with operator-facing text. The desktop contract
 * promises stable codes plus a recovery hint, so the mapping happens here and
 * Swift never has to parse message text.
 */
export function toDesktopError(
  error: unknown,
  context: Record<string, unknown> = {},
): DesktopError {
  if (error instanceof DesktopError) return error;
  const message = error instanceof Error ? error.message : String(error);
  if (COMMIT_FIRST.test(message)) {
    return new DesktopError(-32003, "Commit changes before merging", {
      ...context,
      recovery: "commit_first",
      detail: message,
    });
  }
  if (MERGE_CONFLICT.test(message)) {
    return new DesktopError(-32005, "The merge has conflicts", {
      ...context,
      recovery: "resolve_conflicts",
      detail: message,
    });
  }
  if (DIRTY_WORKTREE.test(message)) {
    return new DesktopError(-32003, "The worktree has uncommitted changes", {
      ...context,
      recovery: "keep_worktree_or_force",
      detail: message,
    });
  }
  if (MISSING_BINARY.test(message)) {
    return new DesktopError(-32002, "A required command is not installed", {
      ...context,
      recovery: "install_binary",
      detail: message,
    });
  }
  return new DesktopError(-32005, message || "Operation failed", {
    ...context,
    detail: message,
  });
}

async function guarded<T>(
  context: Record<string, unknown>,
  fn: () => Promise<T>,
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    throw toDesktopError(error, context);
  }
}

export interface ProjectDetail {
  project: Project;
  sessions: DesktopSessionView[];
}

export interface DesktopSessionView {
  session: Session;
  runs: AgentRun[];
  tmux_alive: boolean;
}

export interface DesktopSessionStatusView extends DesktopSessionView {
  changed_files: ChangedFile[];
  diff_stat: string;
  pane: string;
}

export interface LivingDocSummary {
  kind: MemoryKind;
  path: string;
  title: string;
  modified_at: string;
}

export interface TerminalAttachment {
  executable: string;
  arguments: string[];
  cwd: string;
}

/** Wire shape for custom providers. Snake_case like every other contract. */
export interface CustomAgentResult {
  id: string;
  name: string;
  binary: string;
  launch_args: string[];
  symbol: string;
}

/** Wire shape for per-agent system prompts. Snake_case like the rest. */
export interface AgentSystemPromptResult {
  agent: string;
  system_prompt: string;
}

function toAgentSystemPromptResult(input: {
  agent: string;
  systemPrompt: string;
}): AgentSystemPromptResult {
  return { agent: input.agent, system_prompt: input.systemPrompt };
}

function toCustomAgentResult(def: CustomAgentDef): CustomAgentResult {
  return {
    id: def.id,
    name: def.name,
    binary: def.binary,
    launch_args: def.launchArgs,
    symbol: def.symbol,
  };
}

export interface DesktopServices {
  hello(): Promise<{
    protocol_version: number;
    app_version: string;
    agents: AgentName[];
  }>;
  health(): Promise<{ ok: boolean; tmux_available: boolean }>;
  shutdown(): Promise<{ shutting_down: boolean }>;
  projectList(): Promise<Project[]>;
  projectAdd(input: {
    repo_path: string;
    display_name?: string;
  }): Promise<Project>;
  projectDetail(input: { project_id: string }): Promise<ProjectDetail>;
  projectRemove(input: {
    project_id: string;
  }): Promise<{ removed_project_id: string }>;
  sessionList(input: {
    repo_path?: string;
    status?: SessionStatus;
  }): Promise<DesktopSessionView[]>;
  sessionStatus(input: {
    session_id: string;
  }): Promise<DesktopSessionStatusView>;
  sessionCreate(input: {
    repo_path: string;
    agent: AgentName;
    worktree?: boolean;
    branch?: string;
    title?: string;
    prompt?: string;
  }): Promise<DesktopSessionView>;
  sessionResume(input: { session_id: string }): Promise<DesktopSessionView>;
  sessionSwitch(input: {
    session_id: string;
    agent: AgentName;
    prompt?: string;
  }): Promise<DesktopSessionView>;
  sessionEnd(input: {
    session_id: string;
    merge?: boolean;
  }): Promise<{ ended_session_id: string; merged: boolean }>;
  sessionRemove(input: {
    session_id: string;
    force?: boolean;
    keep_worktree?: boolean;
  }): Promise<{ removed_session_id: string }>;
  transcriptList(input: {
    session_id: string;
    before?: string;
    limit?: number;
  }): Promise<EventPage>;
  memoryList(input: { repo_path?: string; limit?: number }): Promise<Memory[]>;
  memorySearch(input: {
    query: string;
    repo_path?: string;
    limit?: number;
  }): Promise<SearchHit[]>;
  docsList(input: { repo_path: string }): Promise<LivingDocSummary[]>;
  promotionExtract(input: {
    session_id: string;
  }): Promise<{ candidate_count: number }>;
  promotionAutoCheck(input: {
    session_id: string;
  }): Promise<{ candidate_count: number }>;
  promotionPendingCount(): Promise<{ count: number }>;
  promotionPreview(input: {
    session_id: string;
  }): Promise<{ diff: string; candidate_count: number }>;
  promotionApply(input: {
    session_id: string;
  }): Promise<{ promoted: number; files: string[] }>;
  terminalAttachment(input: {
    session_id: string;
  }): Promise<TerminalAttachment>;
  customAgentList(): Promise<CustomAgentResult[]>;
  customAgentAdd(input: {
    id?: string;
    name?: string;
    binary?: string;
    launchArgs?: string[];
    symbol?: string;
  }): Promise<CustomAgentResult>;
  customAgentUpdate(input: {
    id: string;
    name?: string;
    binary?: string;
    launchArgs?: string[];
    symbol?: string;
  }): Promise<CustomAgentResult>;
  customAgentRemove(input: {
    id: string;
  }): Promise<{ removed_agent_id: string }>;
  agentSystemPromptList(): Promise<AgentSystemPromptResult[]>;
  agentSystemPromptGet(input: {
    agent: string;
  }): Promise<AgentSystemPromptResult | null>;
  agentSystemPromptSet(input: {
    agent: string;
    system_prompt?: string;
  }): Promise<AgentSystemPromptResult>;
  fsTree(input: {
    project_id: string;
    session_id?: string;
  }): Promise<{ paths: string[] }>;
  fsRead(input: {
    project_id: string;
    session_id?: string;
    path: string;
  }): Promise<{ path: string; content: string }>;
  fsWrite(input: {
    project_id: string;
    session_id?: string;
    path: string;
    content: string;
  }): Promise<{ path: string; bytes_written: number }>;
  gitFileDiff(input: {
    project_id: string;
    session_id?: string;
    path: string;
  }): Promise<{ path: string; diff: string }>;
}

export interface SessionOperations {
  list(): Promise<SessionView[]>;
  status(sessionId: string): Promise<SessionStatusView>;
  create(input: CreateSessionOptions): Promise<SessionView>;
  resume(sessionId: string): Promise<SessionView>;
  switchAgent(
    sessionId: string,
    agent: AgentName,
    opts?: { prompt?: string },
  ): Promise<SessionView>;
  end(sessionId: string, opts?: { merge?: boolean }): Promise<void>;
  remove(
    sessionId: string,
    opts?: { force?: boolean; keepWorktree?: boolean },
  ): Promise<void>;
}

export interface DesktopServiceDependencies {
  db: Database;
  manager: SessionOperations;
  checkGitRepo?: typeof isGitRepo;
  findRepoRoot?: typeof repoRoot;
  checkTmux?: typeof tmux.tmuxAvailable;
  findTmuxExecutable?: () => Promise<string>;
  extractKnowledge?: (sessionId: string) => Promise<number>;
  ingestSessionEvents?: (sessionId: string) => number;
  onShutdown?: () => void | Promise<void>;
}

function sessionView(view: SessionView): DesktopSessionView {
  return {
    session: view.session,
    runs: view.runs,
    tmux_alive: view.tmuxAlive,
  };
}

function statusView(view: SessionStatusView): DesktopSessionStatusView {
  return {
    ...sessionView(view),
    changed_files: view.changedFiles,
    diff_stat: view.diffStat,
    pane: view.pane,
  };
}

const MAX_EDITOR_FILE_BYTES = 1_048_576;

function resolveInsideRoot(root: string, relativePath: string): string {
  if (relativePath.trim() === "" || relativePath !== relativePath.trim()) {
    throw new DesktopError(-32001, "path must be a relative file path", {
      path: relativePath,
    });
  }
  if (isAbsolute(relativePath)) {
    throw new DesktopError(-32001, "Path is outside the project root", {
      path: relativePath,
    });
  }
  const normalizedRoot = resolve(root);
  const resolved = resolve(normalizedRoot, relativePath);
  const rel = relative(normalizedRoot, resolved);
  if (rel === "" || rel.startsWith(`..`) || isAbsolute(rel)) {
    throw new DesktopError(-32001, "Path is outside the project root", {
      path: relativePath,
    });
  }
  if (rel === ".git" || rel.startsWith(`.git/`)) {
    throw new DesktopError(-32001, "Path is outside the project root", {
      path: relativePath,
    });
  }
  return resolved;
}

function decodeUtf8Text(bytes: Buffer, path: string): string {
  if (bytes.includes(0)) {
    throw new DesktopError(-32001, "File is not UTF-8 text", { path });
  }
  if (bytes.byteLength > MAX_EDITOR_FILE_BYTES) {
    throw new DesktopError(-32001, "File is too large to open in the editor", {
      path,
    });
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new DesktopError(-32001, "File is not UTF-8 text", { path });
  }
}

export function createDesktopServices(
  dependencies: DesktopServiceDependencies,
): DesktopServices {
  const {
    db,
    manager,
    checkGitRepo = isGitRepo,
    findRepoRoot = repoRoot,
    checkTmux = tmux.tmuxAvailable,
    findTmuxExecutable = async () => {
      const result = await exec(["/usr/bin/which", "tmux"]);
      if (result.code !== 0 || !result.stdout.trim()) {
        throw new DesktopError(-32002, "tmux is unavailable", {
          recovery: "install_tmux",
        });
      }
      return result.stdout.trim();
    },
    onShutdown = () => undefined,
  } = dependencies;
  const extractKnowledge =
    dependencies.extractKnowledge ??
    (async (sessionId: string) => {
      const session = resolveSession(db, sessionId);
      const runs = listAgentRuns(db, session.id);
      for (const run of runs) ingestRun(db, run);
      const agent = runs.at(-1)?.agent;
      if (!agent) {
        throw new DesktopError(-32004, "Session has no agent runs", {
          session_id: session.id,
        });
      }
      return (await extractSession(db, session.id, adapterFor(agent))).length;
    });

  const ingestSessionEvents =
    dependencies.ingestSessionEvents ??
    ((sessionId: string) =>
      listAgentRuns(db, sessionId)
        .map((run) => ingestRun(db, run))
        .filter((report) => report !== null)
        .reduce((sum, report) => sum + report.inserted, 0));

  const activeExtractions = new Map<string, Promise<void>>();

  /**
   * `extractKnowledge` shells out to an LLM and is not safe to run twice
   * concurrently for the same session: a second run finishing after the
   * first can silently discard or duplicate the first run's candidates via
   * `saveCandidates`'s delete-then-reinsert. The manual button, session-end
   * auto-extract, and the periodic auto-check all funnel through this guard
   * so only one of them ever wins per session; the rest await the winner's
   * in-flight extraction (rather than no-op immediately) so that whatever
   * they read afterward - e.g. the pending candidate count - reflects the
   * completed extraction rather than racing ahead of it.
   */
  async function runExtractionOnce(sessionId: string): Promise<void> {
    const inFlight = activeExtractions.get(sessionId);
    if (inFlight) {
      await inFlight;
      return;
    }
    const extraction = (async () => {
      await extractKnowledge(sessionId);
    })().finally(() => {
      activeExtractions.delete(sessionId);
    });
    activeExtractions.set(sessionId, extraction);
    await extraction;
  }

  function editorRoot(projectId: string, sessionId?: string): string {
    const project = resolveProject(db, projectId);
    if (!sessionId) return project.repo_path;
    const session = resolveSession(db, sessionId);
    if (session.repo_path !== project.repo_path) {
      throw new DesktopError(-32001, "Session does not belong to this project", {
        project_id: projectId,
        session_id: sessionId,
      });
    }
    return session.worktree_path;
  }

  return {
    hello: async () => ({
      protocol_version: 1,
      app_version: "0.1.0",
      agents: [...availableAgents()],
    }),
    health: async () => {
      // A missing tmux binary is a reportable state, not a failed request.
      const tmuxAvailable = await checkTmux().catch(() => false);
      return { ok: tmuxAvailable, tmux_available: tmuxAvailable };
    },
    shutdown: async () => {
      await onShutdown();
      return { shutting_down: true };
    },
    projectList: async () => listProjects(db),
    projectAdd: async (input) => {
      if (!(await checkGitRepo(input.repo_path))) {
        throw new DesktopError(-32001, "Not a Git repository", {
          repo_path: input.repo_path,
        });
      }
      const root = await findRepoRoot(input.repo_path);
      return createProject(db, {
        repo_path: root,
        display_name: input.display_name,
      });
    },
    projectDetail: async ({ project_id }) => {
      const project = resolveProject(db, project_id);
      const sessions = (await manager.list())
        .filter((view) => view.session.repo_path === project.repo_path)
        .map(sessionView);
      return { project, sessions };
    },
    projectRemove: async ({ project_id }) => {
      const project = resolveProject(db, project_id);
      removeProject(db, project.id);
      return { removed_project_id: project.id };
    },
    sessionList: async ({ repo_path, status }) => {
      const views = await manager.list();
      return views
        .filter((view) => !repo_path || view.session.repo_path === repo_path)
        .filter((view) => !status || view.session.status === status)
        .map(sessionView);
    },
    sessionStatus: async ({ session_id }) =>
      statusView(await manager.status(session_id)),
    sessionCreate: async (input) =>
      guarded({ repo_path: input.repo_path, agent: input.agent }, async () =>
        sessionView(
          await manager.create({
            repoPath: input.repo_path,
            agent: input.agent,
            worktree: input.worktree,
            branch: input.branch,
            title: input.title,
            prompt: input.prompt,
          }),
        ),
      ),
    sessionResume: async ({ session_id }) =>
      guarded({ session_id }, async () =>
        sessionView(await manager.resume(session_id)),
      ),
    sessionSwitch: async ({ session_id, agent, prompt }) =>
      guarded({ session_id, agent }, async () =>
        sessionView(await manager.switchAgent(session_id, agent, { prompt })),
      ),
    sessionEnd: async ({ session_id, merge }) => {
      const session = resolveSession(db, session_id);
      ingestSessionEvents(session.id);
      await guarded({ session_id: session.id }, () =>
        manager.end(session.id, { merge }),
      );
      try {
        await runExtractionOnce(session.id);
      } catch {
        // Best-effort, mirroring the CLI's `oma end`: a session must always
        // be able to end even if no agent is on PATH or extraction fails.
        // The manual Extract Knowledge button remains the retry path.
      }
      return { ended_session_id: session.id, merged: merge === true };
    },
    sessionRemove: async ({ session_id, force, keep_worktree }) => {
      const session = resolveSession(db, session_id);
      await guarded({ session_id: session.id }, () =>
        manager.remove(session.id, {
          force,
          keepWorktree: keep_worktree,
        }),
      );
      return { removed_session_id: session.id };
    },
    transcriptList: async ({ session_id, before, limit }) =>
      listEventsPage(db, { session_id, before, limit }),
    memoryList: async ({ repo_path, limit }) =>
      listMemory(db, { repo_path, limit }),
    memorySearch: async ({ query, repo_path, limit }) =>
      search(db, query, { repo_path, limit }),
    docsList: async ({ repo_path }) => {
      const directory = repoDocsDir(repo_path);
      const files: Array<[MemoryKind, string, string]> = [
        ["decision", "decisions.md", "Decisions"],
        ["invariant", "invariants.md", "Invariants"],
        ["risk", "risks.md", "Risks"],
        ["ownership", "ownership.md", "Ownership"],
        ["howto", "howtos.md", "How-tos"],
      ];
      return files.flatMap(([kind, filename, title]) => {
        const absolutePath = join(directory, filename);
        try {
          if (!lstatSync(absolutePath).isFile()) return [];
          return [
            {
              kind,
              path: `.oma/docs/${filename}`,
              title,
              modified_at: statSync(absolutePath).mtime.toISOString(),
            },
          ];
        } catch {
          return [];
        }
      });
    },
    promotionExtract: async ({ session_id }) =>
      guarded({ session_id }, async () => {
        const session = resolveSession(db, session_id);
        await runExtractionOnce(session.id);
        return {
          candidate_count: listCandidates(db, session.id, "pending").length,
        };
      }),
    promotionAutoCheck: async ({ session_id }) =>
      guarded({ session_id }, async () => {
        const session = resolveSession(db, session_id);
        const inserted = ingestSessionEvents(session.id);
        if (shouldAutoExtract(db, session.id, inserted)) {
          try {
            await runExtractionOnce(session.id);
          } catch {
            // Best-effort, same rationale as sessionEnd: the manual Extract
            // Knowledge button remains the retry path if this fails.
          }
        }
        return {
          candidate_count: listCandidates(db, session.id, "pending").length,
        };
      }),
    promotionPendingCount: async () => ({
      count: countPendingCandidates(db),
    }),
    promotionPreview: async ({ session_id }) =>
      guarded({ session_id }, async () => {
        const session = resolveSession(db, session_id);
        return {
          diff: previewPromotion(db, session.id),
          candidate_count: listCandidates(db, session.id, "pending").length,
        };
      }),
    promotionApply: async ({ session_id }) =>
      guarded({ session_id }, async () => {
        const session = resolveSession(db, session_id);
        return promoteSession(db, session.id);
      }),
    terminalAttachment: async ({ session_id }) => {
      const session = resolveSession(db, session_id);
      await tmux
        .ensureMouseEnabled(tmuxSessionName(session.id))
        .catch(() => {});
      return {
        executable: await findTmuxExecutable(),
        arguments: ["attach", "-t", tmuxSessionName(session.id)],
        cwd: session.worktree_path,
      };
    },
    customAgentList: async () => listCustomAgents().map(toCustomAgentResult),
    customAgentAdd: async (input) => {
      try {
        return toCustomAgentResult(
          addCustomAgent({
            id: input.id,
            name: input.name,
            binary: input.binary,
            launchArgs: input.launchArgs,
            symbol: input.symbol,
          }),
        );
      } catch (error) {
        throw toDesktopError(error, { agent: input.id ?? input.name });
      }
    },
    customAgentUpdate: async ({ id, ...input }) => {
      try {
        return toCustomAgentResult(updateCustomAgent(id, input));
      } catch (error) {
        throw toDesktopError(error, { agent: id });
      }
    },
    customAgentRemove: async ({ id }) => {
      try {
        return { removed_agent_id: removeCustomAgent(id) };
      } catch (error) {
        throw toDesktopError(error, { agent: id });
      }
    },
    agentSystemPromptList: async () =>
      listAgentSystemPrompts().map(toAgentSystemPromptResult),
    agentSystemPromptGet: async ({ agent }) => {
      try {
        const prompt = getAgentSystemPrompt(agent);
        if (!prompt) return null;
        return { agent: agent.trim().toLowerCase(), system_prompt: prompt };
      } catch (error) {
        throw toDesktopError(error, { agent });
      }
    },
    agentSystemPromptSet: async ({ agent, system_prompt }) => {
      try {
        const updated = setAgentSystemPrompt(agent, system_prompt ?? "");
        if (!updated) {
          return {
            agent: normalizePromptAgent(agent),
            system_prompt: "",
          };
        }
        return toAgentSystemPromptResult(updated);
      } catch (error) {
        throw toDesktopError(error, { agent });
      }
    },
    fsTree: async ({ project_id, session_id }) => {
      const root = editorRoot(project_id, session_id);
      return { paths: await listedFiles(root) };
    },
    fsRead: async ({ project_id, session_id, path }) => {
      const root = editorRoot(project_id, session_id);
      const absolute = resolveInsideRoot(root, path);
      if (!existsSync(absolute) || !lstatSync(absolute).isFile()) {
        throw new DesktopError(-32004, "File not found", { path });
      }
      const bytes = readFileSync(absolute);
      return { path, content: decodeUtf8Text(bytes, path) };
    },
    fsWrite: async ({ project_id, session_id, path, content }) => {
      const root = editorRoot(project_id, session_id);
      const absolute = resolveInsideRoot(root, path);
      const payload = Buffer.from(content, "utf8");
      decodeUtf8Text(payload, path);
      mkdirSync(dirname(absolute), { recursive: true });
      const temp = `${absolute}.oma-tmp-${randomUUID()}`;
      writeFileSync(temp, payload);
      renameSync(temp, absolute);
      return { path, bytes_written: payload.byteLength };
    },
    gitFileDiff: async ({ project_id, session_id, path }) => {
      const root = editorRoot(project_id, session_id);
      resolveInsideRoot(root, path);
      return { path, diff: await fileDiff(root, path) };
    },
  };
}

const MCP_ENTRY = join(import.meta.dir, "..", "..", "mcp", "src", "stdio.ts");

export function createProductionServices(
  db: Database,
  onShutdown: () => void | Promise<void>,
): DesktopServices {
  const manager = new SessionManager(db, {
    adapterFor,
    systemPromptFor: (agent) => getAgentSystemPrompt(agent),
    mcpServers: (scope) => [
      {
        name: "oma",
        command: process.execPath,
        args: ["run", MCP_ENTRY],
        env: {
          OMA_REPO_PATH: scope.repoPath,
          OMA_SESSION_ID: scope.sessionId,
        },
      },
    ],
  });
  return createDesktopServices({ db, manager, onShutdown });
}

export type { Project, Session };
