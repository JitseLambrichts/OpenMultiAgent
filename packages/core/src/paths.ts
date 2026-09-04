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

export function omaHome(env: NodeJS.ProcessEnv = process.env): string {
  return env.OMA_HOME ?? join(homedir(), ".oma");
}

export function dbPath(env: NodeJS.ProcessEnv = process.env): string {
  return join(omaHome(env), "oma.db");
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
