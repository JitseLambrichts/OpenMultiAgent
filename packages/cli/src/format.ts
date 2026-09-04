import type { SearchHit, SessionStatusView, SessionView } from "@oma/core";

const RESET = "[0m";
const DIM = "[2m";
const BOLD = "[1m";
const GREEN = "[32m";
const YELLOW = "[33m";

/** Honour NO_COLOR and non-tty output so `oma ls | grep` stays usable. */
const useColor = (): boolean =>
  process.stdout.isTTY === true && !process.env.NO_COLOR;

const paint = (code: string, text: string): string =>
  useColor() ? `${code}${text}${RESET}` : text;

export const dim = (t: string) => paint(DIM, t);
export const bold = (t: string) => paint(BOLD, t);

export function shortId(id: string): string {
  return id.slice(0, 8);
}

function relativeTime(iso: string): string {
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return `${Math.floor(seconds)}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

export function formatSessions(views: SessionView[]): string {
  if (views.length === 0) {
    return "No sessions yet. Start one with: oma new <repo> --agent claude";
  }

  const rows = views.map((view) => {
    const { session, runs, tmuxAlive } = view;
    const agents = [...new Set(runs.map((r) => r.agent))].join("→") || "-";
    const state =
      session.status === "active"
        ? tmuxAlive
          ? paint(GREEN, "running")
          : paint(YELLOW, "detached")
        : dim("ended");
    return [
      shortId(session.id),
      agents,
      state,
      session.branch ?? "-",
      relativeTime(session.started_at),
      session.title ?? session.repo_path,
    ];
  });

  const headers = ["ID", "AGENT", "STATE", "BRANCH", "STARTED", "TITLE"];
  return table([headers, ...rows]);
}

export function formatStatus(view: SessionStatusView): string {
  const agents = view.runs.map((run) => run.agent).join(" → ") || "none";
  const state = view.tmuxAlive ? "running" : view.session.status;
  const files = view.changedFiles.length
    ? view.changedFiles.map((file) => `  ${file.status.padEnd(2)} ${file.path}`)
    : ["  clean"];
  return [
    `${bold(view.session.title ?? shortId(view.session.id))} ${dim(`[${state}]`)}`,
    `Session:  ${view.session.id}`,
    `Agents:   ${agents}`,
    `Branch:   ${view.session.branch ?? "detached"}`,
    `Worktree: ${view.session.worktree_path}`,
    "",
    "Changes:",
    ...files,
    "",
    "Diff:",
    view.diffStat || "  no tracked changes",
    "",
    "Terminal:",
    view.pane.trim() || "  no live pane output",
  ].join("\n");
}

/** Column widths are computed on the visible text, ignoring colour codes. */
function table(rows: string[][]): string {
  const visible = (s: string) =>
    [RESET, DIM, BOLD, GREEN, YELLOW].reduce(
      (text, code) => text.replaceAll(code, ""),
      s,
    ).length;
  const widths = rows[0]!.map((_, i) =>
    Math.max(...rows.map((r) => visible(r[i] ?? ""))),
  );
  return rows
    .map((row, rowIndex) =>
      row
        .map((cell, i) =>
          i === row.length - 1
            ? cell
            : cell + " ".repeat(widths[i]! - visible(cell)),
        )
        .join("  ")
        .trimEnd(),
    )
    .map((line, i) => (i === 0 ? dim(line) : line))
    .join("\n");
}

export function formatSearchHits(query: string, hits: SearchHit[]): string {
  if (hits.length === 0) return `Nothing found for "${query}".`;

  return hits
    .map((hit) => {
      if (hit.type === "memory") {
        const scope = hit.scope === "global" ? "global" : hit.repo_path ?? "";
        return [
          `${bold(hit.title)} ${dim(`[${hit.kind}]`)}`,
          hit.body,
          dim(
            `${scope} · confidence ${hit.confidence.toFixed(2)} · ${relativeTime(hit.created_at)}`,
          ),
        ].join("\n");
      }
      return [
        dim(
          `${hit.agent} · ${hit.kind}${hit.tool_name ? `:${hit.tool_name}` : ""} · session ${shortId(hit.session_id)} · ${relativeTime(hit.ts)}`,
        ),
        truncateLines(hit.text, 6),
      ].join("\n");
    })
    .join("\n\n");
}

function truncateLines(text: string, max: number): string {
  const lines = text.split("\n");
  return lines.length <= max
    ? text
    : `${lines.slice(0, max).join("\n")}\n${dim(`… ${lines.length - max} more lines`)}`;
}
