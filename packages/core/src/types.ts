/** Shared domain types. The DB is the only owner of state; these mirror its rows. */

/** Built-in agents with first-class adapters. Custom providers use any other slug. */

export type BuiltinAgentName = "claude" | "codex" | "gemini";

export type AgentName = string;

export const BUILTIN_AGENT_NAMES: readonly BuiltinAgentName[] = [
  "claude",
  "codex",
  "gemini",
];

/** @deprecated Use BUILTIN_AGENT_NAMES; kept for existing imports. */
export const AGENT_NAMES: readonly BuiltinAgentName[] = BUILTIN_AGENT_NAMES;

const AGENT_SLUG = /^[a-z0-9][a-z0-9_-]{0,31}$/;

export function isBuiltinAgentName(value: string): value is BuiltinAgentName {
  return (BUILTIN_AGENT_NAMES as readonly string[]).includes(value);
}

export function isAgentName(value: string): value is AgentName {
  return AGENT_SLUG.test(value);
}

export type SessionStatus = "active" | "ended";

export interface Project {
  id: string;
  repo_path: string;
  display_name: string;
  created_at: string;
  last_opened_at: string;
}

export interface Session {
  id: string;
  repo_path: string;
  worktree_path: string;
  branch: string | null;
  title: string | null;
  status: SessionStatus;
  started_at: string;
  ended_at: string | null;
}

export interface AgentRun {
  id: string;
  session_id: string;
  agent: AgentName;
  native_session_id: string | null;
  transcript_path: string | null;
  started_at: string;
  ended_at: string | null;
}

/**
 * Roles are normalised across agents. Claude's `assistant`/`user` and Codex's
 * `message.role` collapse into these; anything unrecognised becomes `system`.
 */
export type EventRole = "user" | "assistant" | "system";

/**
 * `kind` is the normalised event shape, deliberately small. Agent-specific
 * detail stays in `raw_json` so an unknown event type never loses information.
 */
export type EventKind =
  | "text"
  | "thinking"
  | "tool_use"
  | "tool_result"
  | "meta"
  | "unknown";

export interface NormalizedEvent {
  /**
   * Position within the transcript, stable across re-parses of a file that has
   * only been appended to. Combined with `agent_run_id` it makes ingest
   * idempotent, so a growing transcript can be re-read from the start safely.
   */
  seq: number;
  ts: string;
  role: EventRole;
  kind: EventKind;
  tool_name: string | null;
  text: string;
  raw: unknown;
}

export interface EventRow extends NormalizedEvent {
  id: string;
  session_id: string;
  agent_run_id: string;
}

export interface EventPage {
  items: EventRow[];
  next_cursor: string | null;
}

export type MemoryKind =
  | "decision"
  | "invariant"
  | "risk"
  | "ownership"
  | "howto";

export const MEMORY_KINDS: readonly MemoryKind[] = [
  "decision",
  "invariant",
  "risk",
  "ownership",
  "howto",
];

export function isMemoryKind(value: string): value is MemoryKind {
  return (MEMORY_KINDS as readonly string[]).includes(value);
}

/** `global` memory applies everywhere; `repo` memory is scoped to `repo_path`. */
export type MemoryScope = "repo" | "global";

export interface Memory {
  id: string;
  kind: MemoryKind;
  scope: MemoryScope;
  repo_path: string | null;
  title: string;
  body: string;
  confidence: number;
  source_session_id: string | null;
  created_at: string;
  superseded_by: string | null;
}

export type ChangeKind = "created" | "modified" | "deleted";

export interface Artifact {
  id: string;
  session_id: string;
  path: string;
  change_kind: ChangeKind;
}
