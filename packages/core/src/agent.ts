import type { AgentName } from "./types.ts";

export interface McpServerSpec {
  name: string;
  command: string;
  args: string[];
  env?: Record<string, string>;
}

export interface LaunchContext {
  /** The OMA session id — not the agent's own session id. */
  sessionId: string;
  /** Working directory for the agent: the worktree when there is one. */
  cwd: string;
  /** Initial prompt, or the Handoff Brief when switching agents mid-session. */
  prompt?: string;
  /** Injected as a system-prompt suffix where the agent supports it. */
  systemPrompt?: string;
  mcpServers?: McpServerSpec[];
  /** Resume the agent's own previous session rather than starting fresh. */
  resumeNativeSessionId?: string;
  /** Fork the agent's previous context into a new native run. */
  forkNativeSessionId?: string;
}

export interface Launch {
  /** argv, run inside the tmux session. */
  command: string[];
  /** Per-process environment, used for session-scoped agent configuration. */
  env?: Record<string, string>;
  /**
   * Known before launch only for agents that let the caller choose the id
   * (Claude). Null means it has to be discovered afterwards.
   */
  nativeSessionId: string | null;
  /** Known upfront when the transcript path is a function of the id. */
  transcriptPath: string | null;
  /** Files the adapter had to write (e.g. `.mcp.json`), for cleanup. */
  writtenFiles: string[];
}

export interface ResolveContext {
  cwd: string;
  /** Only transcripts created at or after this instant are candidates. */
  startedAt: Date;
  nativeSessionId?: string | null;
  /** A fork must never rediscover the source transcript as its own. */
  excludeNativeSessionId?: string | null;
}

export interface HeadlessOptions {
  cwd: string;
  prompt: string;
  /** Ask for JSON output; used by the M3 extraction pipeline. */
  json?: boolean;
  timeoutMs?: number;
}

export interface AgentAdapter {
  name: AgentName;
  /** Executable name, looked up on PATH. */
  binary: string;
  /** Whether the CLI can fork an existing native conversation. */
  supportsNativeFork?: boolean;

  isAvailable(): Promise<boolean>;

  buildLaunch(ctx: LaunchContext): Launch;

  /**
   * Locate the transcript this run writes to. Deliberately per-adapter: Claude
   * can be told its session id, Codex cannot, so one shared assumption would be
   * wrong for one of them.
   */
  resolveTranscript(ctx: ResolveContext): Promise<string | null>;

  /** One-shot, non-interactive invocation. */
  headlessCommand(opts: HeadlessOptions): string[];
}
