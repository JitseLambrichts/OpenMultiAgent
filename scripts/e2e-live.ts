#!/usr/bin/env bun
/**
 * The M1 acceptance scenario against the *real* agent CLIs.
 *
 *   Session A runs Claude, which makes a decision in its transcript.
 *   Session A's transcript is ingested from disk.
 *   Session B runs Codex — a different agent — and asks why.
 *   Codex must find the answer through the OMA memory MCP server.
 *
 * This costs tokens and needs both CLIs authenticated, so it is a script rather
 * than part of `bun test`. Everything it touches lives in a temp directory:
 * OMA_HOME is redirected, so the real ~/.oma/oma.db is untouched.
 *
 *   bun run scripts/e2e-live.ts
 */
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeAdapter, codexAdapter } from "@oma/adapters";
import {
  createAgentRun,
  createSession,
  exec,
  openDb,
  search,
  type McpServerSpec,
} from "@oma/core";
import { ingestRun } from "@oma/ingest";

const SECRET = `Redis Streams (chosen ${Date.now()})`;
const MCP_ENTRY = join(import.meta.dir, "..", "packages", "mcp", "src", "stdio.ts");

const workdir = mkdtempSync(join(tmpdir(), "oma-live-"));
const repo = join(workdir, "repo");
const omaHome = join(workdir, "oma");
process.env.OMA_HOME = omaHome;

let failed = false;
const step = (msg: string) => console.log(`\n▸ ${msg}`);
const ok = (msg: string) => console.log(`  ✓ ${msg}`);
const bad = (msg: string) => {
  failed = true;
  console.error(`  ✗ ${msg}`);
};

try {
  step("Creating a throwaway git repository");
  await exec(["mkdir", "-p", repo]);
  await exec(["git", "init", "-b", "main"], { cwd: repo });
  await exec(["git", "config", "user.email", "e2e@example.com"], { cwd: repo });
  await exec(["git", "config", "user.name", "OMA E2E"], { cwd: repo });
  writeFileSync(join(repo, "README.md"), "# queue service\n");
  await exec(["git", "add", "."], { cwd: repo });
  await exec(["git", "commit", "-m", "init"], { cwd: repo });
  ok(repo);

  const db = openDb();

  const mcpServer = (sessionId: string): McpServerSpec => ({
    name: "oma",
    command: process.execPath,
    args: ["run", MCP_ENTRY],
    env: {
      OMA_HOME: omaHome,
      OMA_REPO_PATH: repo,
      OMA_SESSION_ID: sessionId,
    },
  });

  // --- Session A: Claude decides something ---------------------------------
  step("Session A — Claude makes a decision");
  const sessionA = createSession(db, {
    repo_path: repo,
    worktree_path: repo,
    title: "choose a queue",
  });

  const launchA = claudeAdapter.buildLaunch({
    sessionId: sessionA.id,
    cwd: repo,
    mcpServers: [mcpServer(sessionA.id)],
  });
  const runA = createAgentRun(db, {
    session_id: sessionA.id,
    agent: "claude",
    native_session_id: launchA.nativeSessionId,
    transcript_path: launchA.transcriptPath,
  });

  const promptA =
    `We have decided to use ${SECRET} for the event queue, because we need replay ` +
    `of the last hour and ops already run Redis. State that decision and its rationale ` +
    `clearly in one sentence.`;

  // Same flags the adapter builds for an interactive launch, plus `-p`.
  const resultA = await exec(
    [...launchA.command.slice(0, 1), "-p", ...launchA.command.slice(1), promptA],
    { cwd: repo },
  );

  if (resultA.code !== 0) {
    bad(`claude exited ${resultA.code}: ${resultA.stderr.trim().slice(0, 400)}`);
  } else {
    ok(`claude replied: ${resultA.stdout.trim().slice(0, 120)}`);
  }

  step("Ingesting session A's transcript from disk");
  const report = ingestRun(db, runA);
  if (!report) bad(`no transcript at ${launchA.transcriptPath}`);
  else ok(`${report.inserted} events from ${report.transcript_path}`);

  const stored = db
    .query<{ repo_path: string | null; scope: string; title: string }, []>(
      "SELECT repo_path, scope, title FROM memory",
    )
    .all();
  console.log(`  · curated memory records (expected 0 before review): ${stored.length}`);
  for (const row of stored) {
    console.log(`    [${row.scope}] ${row.title}  (repo_path=${row.repo_path})`);
  }

  // Sanity check the retrieval path before blaming the agent for not finding it.
  const local = search(db, "which queue do we use and why?", { repo_path: repo });
  console.log(`  · direct search from OMA itself: ${local.length} hit(s)`);
  for (const hit of local.slice(0, 3)) {
    console.log(
      `    ${hit.type}: ${hit.type === "memory" ? hit.title : hit.text.slice(0, 80)}`,
    );
  }

  // --- Session B: Codex asks why ------------------------------------------
  step("Session B — Codex, a different agent, asks why");
  const sessionB = createSession(db, {
    repo_path: repo,
    worktree_path: repo,
    title: "implement the consumer",
  });

  const promptB =
    "Call the MCP tool `memory_search` provided by the MCP server named `oma` " +
    "(do not use any other tool, and do not call it from a REPL) with the query " +
    "'which queue do we use for the event queue and why'. Then answer in one " +
    "sentence, naming the technology, quoting what the tool returned. If the " +
    "tool returns nothing, say exactly that.";

  const resultB = await exec(
    [
      codexAdapter.binary,
      "exec",
      "-C",
      repo,
      "--skip-git-repo-check",
      // Non-interactive: nobody is there to approve the memory lookup.
      "-c",
      'approval_policy="never"',
      ...(await import("@oma/adapters")).mcpConfigArgs([mcpServer(sessionB.id)]),
      promptB,
    ],
    { cwd: repo },
  );

  const answer = resultB.stdout;
  if (resultB.code !== 0) {
    bad(`codex exited ${resultB.code}: ${resultB.stderr.trim().slice(0, 400)}`);
  }

  step("Verdict");
  console.log(`  codex said: ${answer.trim().slice(-500)}`);

  if (answer.includes("Redis Streams")) {
    ok("Codex recovered a decision it never saw, made by Claude in another session.");
  } else {
    bad("Codex did not recover the decision.");
  }
} finally {
  rmSync(workdir, { recursive: true, force: true });
  console.log(`\nCleaned up ${workdir}`);
}

process.exit(failed ? 1 : 0);
