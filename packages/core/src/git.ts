import { existsSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { exec, execOrThrow } from "./exec.ts";

export async function isGitRepo(path: string): Promise<boolean> {
  const result = await exec(["git", "rev-parse", "--git-dir"], { cwd: path });
  return result.code === 0;
}

export async function repoRoot(path: string): Promise<string> {
  const out = await execOrThrow(["git", "rev-parse", "--show-toplevel"], {
    cwd: path,
  });
  return out.trim();
}

export async function currentBranch(path: string): Promise<string | null> {
  const result = await exec(["git", "rev-parse", "--abbrev-ref", "HEAD"], {
    cwd: path,
  });
  if (result.code !== 0) return null;
  const branch = result.stdout.trim();
  return branch === "HEAD" ? null : branch;
}

export interface WorktreeResult {
  path: string;
  branch: string;
}

/**
 * Worktrees live in `<repo>/.worktrees/<branch>` so parallel sessions can touch
 * the same repo without fighting over the index.
 */
export async function createWorktree(
  repoPath: string,
  branch: string,
): Promise<WorktreeResult> {
  const root = await repoRoot(repoPath);
  const path = join(root, ".worktrees", branch);

  if (existsSync(path)) {
    throw new Error(`worktree path already exists: ${path}`);
  }

  const branchExists =
    (await exec(["git", "rev-parse", "--verify", `refs/heads/${branch}`], {
      cwd: root,
    })).code === 0;

  await execOrThrow(
    branchExists
      ? ["git", "worktree", "add", path, branch]
      : ["git", "worktree", "add", "-b", branch, path],
    { cwd: root },
  );

  return { path, branch };
}

export async function removeWorktree(
  repoPath: string,
  worktreePath: string,
  opts: { force?: boolean } = {},
): Promise<void> {
  const root = await repoRoot(repoPath);
  if (resolve(worktreePath) === resolve(root)) return; // never remove the main tree
  await execOrThrow(
    ["git", "worktree", "remove", ...(opts.force ? ["--force"] : []), worktreePath],
    { cwd: root },
  );
}

export interface ChangedFile {
  path: string;
  status: string;
}

/** Porcelain v1 status, used to record which files a session touched. */
export async function changedFiles(path: string): Promise<ChangedFile[]> {
  const result = await exec(["git", "status", "--porcelain=v1", "-z"], {
    cwd: path,
  });
  if (result.code !== 0) return [];
  const records = result.stdout.split("\0");
  const files: ChangedFile[] = [];
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    if (!record) continue;
    const rawStatus = record.slice(0, 2);
    files.push({ status: rawStatus.trim(), path: record.slice(3) });
    // Rename/copy records carry the original path as the next NUL field.
    if (rawStatus.includes("R") || rawStatus.includes("C")) i++;
  }
  return files;
}

export async function diffStat(path: string): Promise<string> {
  const result = await exec(["git", "diff", "--stat", "HEAD"], { cwd: path });
  return result.code === 0 ? result.stdout.trim() : "";
}

/** True when the tree has staged, unstaged or untracked changes. */
export async function hasUncommittedChanges(path: string): Promise<boolean> {
  return (await changedFiles(path)).length > 0;
}

/**
 * OMA's own runtime directories inside the repo. These show up as untracked
 * in the main checkout but must never block a merge.
 */
const MERGE_IGNORED_PREFIXES = [".worktrees/"];

/**
 * True when the tree has changes that must be committed before a merge.
 * Unlike {@link hasUncommittedChanges} this ignores OMA runtime state such
 * as the `.worktrees` directory itself, which is always untracked in the
 * main checkout while sessions are active.
 */
export async function hasMergeBlockingChanges(path: string): Promise<boolean> {
  const files = await changedFiles(path);
  return files.some(
    (file) =>
      !MERGE_IGNORED_PREFIXES.some((prefix) => file.path.startsWith(prefix)),
  );
}

export interface MergeResult {
  target: string;
}

const MERGE_CONFLICT = /CONFLICT|Automatic merge failed|merge conflict/i;

/**
 * Merges a session branch into the main checkout's current branch.
 * Never auto-commits: callers must ensure both trees are clean first.
 * On conflict the merge is aborted and an error is thrown, so the session
 * stays alive for manual resolution.
 */
export async function mergeWorktree(
  repoPath: string,
  branch: string,
): Promise<MergeResult> {
  const root = await repoRoot(repoPath);
  const target = await currentBranch(root);
  if (!target) {
    throw new Error("cannot merge while the main checkout is detached (HEAD)");
  }
  const branchExists =
    (await exec(["git", "rev-parse", "--verify", `refs/heads/${branch}`], {
      cwd: root,
    })).code === 0;
  if (!branchExists) {
    throw new Error(`no session branch matches '${branch}'`);
  }

  const result = await exec(["git", "merge", "--no-ff", branch], {
    cwd: root,
  });
  if (result.code !== 0) {
    const output = `${result.stdout}\n${result.stderr}`;
    if (MERGE_CONFLICT.test(output)) {
      await exec(["git", "merge", "--abort"], { cwd: root }).catch(() => {});
      throw new Error(
        `merge conflict merging '${branch}' into '${target}', merge aborted: ${result.stderr.trim() || result.stdout.trim()}`,
      );
    }
    throw new Error(
      `git merge --no-ff ${branch} exited ${result.code}: ${result.stderr.trim() || result.stdout.trim()}`,
    );
  }
  return { target };
}

/** A stable, human-friendly name for a repo, used in session titles. */
export function repoName(repoPath: string): string {
  return basename(resolve(repoPath));
}
