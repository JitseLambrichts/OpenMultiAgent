import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Claude Code stores transcripts under a directory whose name is the cwd with
 * every `/`, `_` and `.` replaced by `-`.
 *
 * This mapping is undocumented and is the most fragile assumption in M1, hence
 * the fixture-backed test in `paths.test.ts` built from real directories on
 * disk. If Claude changes it, that test fails loudly instead of the ingest
 * silently reading nothing.
 */
export function claudeProjectSlug(cwd: string): string {
  return cwd.replace(/[/_.]/g, "-");
}

/**
 * Claude slugs the *resolved* path, not the path it was handed. On macOS
 * `/var/...` is a symlink to `/private/var/...`, so a session started in a temp
 * directory writes its transcript under `-private-var-...`. Resolving first is
 * what makes the derived path actually match the file on disk.
 *
 * Falls back to the literal path when it does not exist yet — the caller may be
 * deriving a path for a directory that is about to be created.
 */
export function resolveRealPath(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

export function claudeProjectDir(cwd: string, home = homedir()): string {
  return join(
    home,
    ".claude",
    "projects",
    claudeProjectSlug(resolveRealPath(cwd)),
  );
}

/**
 * Deterministic only because OMA generates the session UUID itself and passes
 * it to `claude --session-id`.
 */
export function claudeTranscriptPath(
  cwd: string,
  sessionId: string,
  home = homedir(),
): string {
  return join(claudeProjectDir(cwd, home), `${sessionId}.jsonl`);
}

/**
 * Subagent (Task tool) transcripts are not siblings of the main transcript —
 * they sit one level deeper, under `<slug>/<parentSessionId>/subagents/`, and
 * are named `agent-<hash>.jsonl` rather than `<uuid>.jsonl`. Discovery that
 * globs `<slug>/*.jsonl` therefore sees main sessions only, which is the
 * intended default; subagent work is reachable through this helper.
 */
export function claudeSubagentDir(
  cwd: string,
  sessionId: string,
  home = homedir(),
): string {
  return join(claudeProjectDir(cwd, home), sessionId, "subagents");
}

/** Codex has no `--session-id`; transcripts are found by scanning this tree. */
export function codexSessionsDir(home = homedir()): string {
  return join(home, ".codex", "sessions");
}

/**
 * OpenCode keeps sessions, messages and parts as separate JSON files under this
 * tree rather than one transcript per session, so discovery scans it instead of
 * deriving a filename.
 */
export function opencodeStorageDir(
  env: NodeJS.ProcessEnv = process.env,
  home = homedir(),
): string {
  const data = env.XDG_DATA_HOME ?? join(home, ".local", "share");
  return join(data, "opencode", "storage");
}

/**
 * `homedir()` in Bun reads the passwd entry and ignores `$HOME`, where Node
 * prefers the variable. POSIX tools - Cursor among them - follow `$HOME`, so
 * that is what discovery has to follow too.
 */
export function homeDirectory(
  env: NodeJS.ProcessEnv = process.env,
  fallback = homedir(),
): string {
  return env.HOME?.trim() || fallback;
}

/**
 * Cursor keeps one directory per chat, named after the chat id, under a hash of
 * the workspace. Its conversation is a SQLite store inside, not a transcript.
 */
export function cursorChatsDir(home = homeDirectory()): string {
  return join(home, ".cursor", "chats");
}

export function omaHome(env: NodeJS.ProcessEnv = process.env): string {
  return env.OMA_HOME ?? join(homedir(), ".oma");
}

export function dbPath(env: NodeJS.ProcessEnv = process.env): string {
  return join(omaHome(env), "oma.db");
}

/**
 * The universal fallback: everything a run's tmux pane printed, captured with
 * `pipe-pane`. Used for agents whose own store OMA cannot read, and for a plain
 * terminal, which has no store at all.
 *
 * The suffix is load-bearing. `transcript_path` holds one locator column for
 * every agent, so the name is what tells ingest that this file is OMA's own
 * capture rather than something an agent wrote in its own format.
 */
export const PANE_LOG_SUFFIX = ".pane.log";

export function paneLogPath(runId: string, home = omaHome()): string {
  return join(home, "panes", `${runId}${PANE_LOG_SUFFIX}`);
}

export function isPaneLog(locator: string): boolean {
  return locator.endsWith(PANE_LOG_SUFFIX);
}

/** Per-repo docs live in the repo itself, git-versioned — not in a doc store. */
export function repoDocsDir(repoPath: string): string {
  return join(repoPath, ".oma", "docs");
}

/** tmux sessions are prefixed so discovery never picks up unrelated sessions. */
export const TMUX_PREFIX = "oma-";

export function tmuxSessionName(sessionId: string): string {
  return `${TMUX_PREFIX}${sessionId}`;
}
