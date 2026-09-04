import type { Database } from "bun:sqlite";
import { resolveSession } from "./store.ts";

interface HandoffOptions {
  diffStat?: string;
  recentEvents?: number;
}

interface BriefMemory {
  kind: string;
  title: string;
  body: string;
}

interface BriefArtifact {
  path: string;
  change_kind: string;
}

interface BriefEvent {
  role: string;
  kind: string;
  tool_name: string | null;
  text: string;
}

const compact = (text: string, limit = 800): string =>
  text.length <= limit ? text : `${text.slice(0, limit)}…`;

function section(title: string, lines: string[]): string {
  return `## ${title}\n${lines.length ? lines.join("\n") : "- None recorded."}`;
}

export function buildHandoffBrief(
  db: Database,
  sessionId: string,
  options: HandoffOptions = {},
): string {
  const session = resolveSession(db, sessionId);
  const memories = db
    .query<BriefMemory, [string]>(
      `SELECT kind, title, body
         FROM memory
        WHERE superseded_by IS NULL
          AND (scope = 'global' OR repo_path = ?)
        ORDER BY created_at DESC
        LIMIT 20`,
    )
    .all(session.repo_path);
  const artifacts = db
    .query<BriefArtifact, [string]>(
      `SELECT path, change_kind
         FROM artifact
        WHERE session_id = ?
        ORDER BY path`,
    )
    .all(session.id);
  const events = db
    .query<BriefEvent, [string, number]>(
      `SELECT role, kind, tool_name, text
         FROM event
        WHERE session_id = ? AND text != ''
        ORDER BY ts DESC, seq DESC
        LIMIT ?`,
    )
    .all(session.id, options.recentEvents ?? 12)
    .reverse();

  return [
    "# OMA Handoff Brief",
    "This brief provides continuity of knowledge, not a transfer of the previous agent's private context window.",
    "",
    section("Task", [
      `- ${session.title ?? "Continue the active OMA session."}`,
      `- Repository: ${session.repo_path}`,
      `- Worktree: ${session.worktree_path}`,
      `- Branch: ${session.branch ?? "detached"}`,
    ]),
    "",
    section(
      "Decisions, invariants and risks",
      memories.map(
        (memory) =>
          `- [${memory.kind}] ${compact(memory.title, 160)} — ${compact(memory.body)}`,
      ),
    ),
    "",
    section(
      "Touched files",
      artifacts.map(
        (artifact) => `- [${artifact.change_kind}] ${artifact.path}`,
      ),
    ),
    "",
    section("Current diff summary", [
      options.diffStat?.trim() || "No tracked diff summary is available.",
    ]),
    "",
    section(
      "Recent transcript",
      events.map(
        (event) =>
          `- ${event.role}/${event.kind}${event.tool_name ? `:${event.tool_name}` : ""}: ${compact(event.text)}`,
      ),
    ),
    "",
    "Continue in the same worktree. Verify the current diff and tests before changing it.",
  ].join("\n");
}
