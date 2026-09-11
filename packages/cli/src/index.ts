#!/usr/bin/env bun
import { parseArgs } from "node:util";
import { join } from "node:path";
import { adapterFor, availableAgents } from "@oma/adapters";
import {
  createMemory,
  isAgentName,
  isMemoryKind,
  listAgentRuns,
  MEMORY_KINDS,
  openDb,
  resolveSession,
  search,
  SessionManager,
  type AgentName,
  type Database,
  type McpScope,
  type McpServerSpec,
} from "@oma/core";
import { ingestAll, ingestRun } from "@oma/ingest";
import {
  extractSession,
  previewPromotion,
  promoteSession,
  shouldAutoExtract,
} from "@oma/docs";
import {
  formatSearchHits,
  formatSessions,
  formatStatus,
  shortId,
} from "./format.ts";

const USAGE = `oma — OpenMultiAgent

Usage:
  oma new <repo> [--agent claude|codex|gemini|terminal] [--worktree] [--title T] [--prompt P]
  oma ls
  oma watch [--interval SECONDS]
  oma status <id>
  oma attach <id>
  oma switch <id> --agent claude|codex|gemini|terminal [--prompt P]
  oma resume <id>
  oma fork <id> [--prompt P]
  oma extract <id> [--agent claude|codex|gemini]
  oma promote <id> [--apply]
  oma end <id> [--no-extract]
  oma rm <id> [--force] [--keep-worktree]
  oma sync [<id>] [--no-auto-extract]
  oma search <query> [--repo PATH] [--limit N] [--memory-only]
  oma remember <title> --kind <kind> --body <text> [--repo PATH] [--global]
  oma mcp

Memory kinds: ${MEMORY_KINDS.join(", ")}
Agents:       ${availableAgents().join(", ")}
`;

/** Path to the MCP entry point, so generated configs point at this checkout. */
const MCP_ENTRY = join(import.meta.dir, "..", "..", "mcp", "src", "stdio.ts");

function memoryServer(scope: McpScope): McpServerSpec[] {
  return [
    {
      name: "oma",
      command: process.execPath, // the bun that is running this CLI
      args: ["run", MCP_ENTRY],
      env: {
        OMA_REPO_PATH: scope.repoPath,
        OMA_SESSION_ID: scope.sessionId,
      },
    },
  ];
}

function fail(message: string): never {
  console.error(`oma: ${message}`);
  process.exit(1);
}

function requireAgent(value: string | undefined): AgentName {
  const agent = value ?? "claude";
  if (!isAgentName(agent)) fail(`unknown agent '${agent}'`);
  return agent;
}

async function cmdNew(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      agent: { type: "string" },
      worktree: { type: "boolean" },
      branch: { type: "string" },
      title: { type: "string" },
      prompt: { type: "string" },
    },
  });

  const repo = positionals[0] ?? process.cwd();
  const agent = requireAgent(values.agent);

  const manager = new SessionManager(db, {
    adapterFor,
    mcpServers: memoryServer,
  });

  const view = await manager.create({
    repoPath: repo,
    agent,
    worktree: values.worktree,
    branch: values.branch,
    title: values.title,
    prompt: values.prompt,
  });

  const { session } = view;
  console.log(`Started session ${shortId(session.id)} (${agent})`);
  console.log(`  worktree: ${session.worktree_path}`);
  console.log(`  attach:   oma attach ${shortId(session.id)}`);
}

async function cmdLs(db: Database): Promise<void> {
  const manager = new SessionManager(db, { adapterFor });
  console.log(formatSessions(await manager.list()));
}

async function cmdWatch(db: Database, argv: string[]): Promise<void> {
  const { values } = parseArgs({
    args: argv,
    options: { interval: { type: "string" } },
  });
  const interval = values.interval ? Number(values.interval) : 2;
  if (!Number.isFinite(interval) || interval < 0.2) {
    fail("watch --interval must be at least 0.2 seconds");
  }
  const manager = new SessionManager(db, { adapterFor });
  while (true) {
    process.stdout.write("\x1b[2J\x1b[H");
    console.log("OpenMultiAgent — live sessions\n");
    console.log(formatSessions(await manager.list()));
    console.log("\nRefreshes automatically; press Ctrl-C to exit.");
    await Bun.sleep(interval * 1_000);
  }
}

async function cmdAttach(db: Database, argv: string[]): Promise<void> {
  const id = argv[0];
  if (!id) fail("attach needs a session id");

  const manager = new SessionManager(db, { adapterFor });
  const command = manager.attachCommand(id);

  // Hand the terminal over to tmux; the CLI is not a terminal multiplexer.
  const proc = Bun.spawn(command, {
    stdio: ["inherit", "inherit", "inherit"],
  });
  process.exit(await proc.exited);
}

async function cmdStatus(db: Database, argv: string[]): Promise<void> {
  const id = argv[0];
  if (!id) fail("status needs a session id");
  const manager = new SessionManager(db, { adapterFor });
  console.log(formatStatus(await manager.status(id)));
}

async function cmdSwitch(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      agent: { type: "string" },
      prompt: { type: "string" },
    },
  });
  const id = positionals[0];
  if (!id) fail("switch needs a session id");
  if (!values.agent) fail("switch needs --agent");
  const agent = requireAgent(values.agent);

  // The handoff is built from normalized events, so capture the current run
  // immediately before replacing its terminal process.
  syncReports(db, id);
  const manager = new SessionManager(db, {
    adapterFor,
    mcpServers: memoryServer,
  });
  const view = await manager.switchAgent(id, agent, { prompt: values.prompt });
  console.log(
    `Switched session ${shortId(view.session.id)} to ${agent}. Attach with: oma attach ${shortId(view.session.id)}`,
  );
}

async function cmdResume(db: Database, argv: string[]): Promise<void> {
  const id = argv[0];
  if (!id) fail("resume needs a session id");
  const manager = new SessionManager(db, {
    adapterFor,
    mcpServers: memoryServer,
  });
  const view = await manager.resume(id);
  console.log(
    `Resumed session ${shortId(view.session.id)}. Attach with: oma attach ${shortId(view.session.id)}`,
  );
}

async function cmdFork(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: { prompt: { type: "string" } },
  });
  const id = positionals[0];
  if (!id) fail("fork needs a session id");
  syncReports(db, id);
  const manager = new SessionManager(db, {
    adapterFor,
    mcpServers: memoryServer,
  });
  const view = await manager.forkAgent(id, { prompt: values.prompt });
  console.log(
    `Forked the latest native run in session ${shortId(view.session.id)}. Attach with: oma attach ${shortId(view.session.id)}`,
  );
}

async function cmdExtract(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: { agent: { type: "string" } },
  });
  const id = positionals[0];
  if (!id) fail("extract needs a session id");
  const session = resolveSession(db, id);
  syncReports(db, session.id);
  const runs = listAgentRuns(db, session.id);
  const agent = values.agent ? requireAgent(values.agent) : runs.at(-1)?.agent;
  if (!agent) fail("extract needs an agent because the session has no runs");

  const candidates = await extractSession(db, session.id, adapterFor(agent));
  console.log(`Extracted ${candidates.length} review candidate(s).`);
  console.log(previewPromotion(db, session.id));
  console.log(
    `\nReview the diff, then apply it with: oma promote ${shortId(session.id)} --apply`,
  );
}

async function cmdPromote(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: { apply: { type: "boolean" } },
  });
  const id = positionals[0];
  if (!id) fail("promote needs a session id");
  const session = resolveSession(db, id);
  console.log(previewPromotion(db, session.id));
  if (!values.apply) {
    console.log(
      `\nPreview only. Apply with: oma promote ${shortId(session.id)} --apply`,
    );
    return;
  }
  const result = promoteSession(db, session.id);
  console.log(
    `\nPromoted ${result.promoted} candidate(s) and rendered ${result.files.length} living-doc file(s).`,
  );
}

async function attemptExtraction(
  db: Database,
  sessionId: string,
): Promise<void> {
  const runs = listAgentRuns(db, sessionId);
  const agent = runs.at(-1)?.agent;
  if (!agent) return;
  try {
    const candidates = await extractSession(db, sessionId, adapterFor(agent));
    console.log(`Extracted ${candidates.length} review candidate(s).`);
    console.log(previewPromotion(db, sessionId));
    console.log(
      `\nReview the diff, then apply it with: oma promote ${shortId(sessionId)} --apply`,
    );
  } catch (error) {
    console.warn(
      `Knowledge extraction failed; retry with 'oma extract ${shortId(sessionId)}': ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

async function cmdEnd(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      extract: { type: "boolean" },
      "no-extract": { type: "boolean" },
    },
  });
  const id = positionals[0];
  if (!id) fail("end needs a session id");
  const session = resolveSession(db, id);
  const manager = new SessionManager(db, { adapterFor });
  // Capture whatever the agent wrote before the session goes away.
  syncReports(db, session.id);
  await manager.end(session.id);
  console.log(`Ended session ${shortId(session.id)}`);

  // Auto-extract by default so useful knowledge lands in pending review.
  // Opt out with --no-extract. Never auto-applies: promotion stays explicit.
  if (values["no-extract"]) return;
  await attemptExtraction(db, session.id);
}

async function cmdRm(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      force: { type: "boolean" },
      "keep-worktree": { type: "boolean" },
    },
  });
  const id = positionals[0];
  if (!id) fail("rm needs a session id");

  const manager = new SessionManager(db, { adapterFor });
  // Ingest first: removing a session must not throw away what it learned.
  await cmdSync(db, [id, "--no-auto-extract"]);
  const full = resolveSession(db, id).id;
  await manager.remove(id, {
    force: values.force,
    keepWorktree: values["keep-worktree"],
  });
  console.log(
    `Removed session ${shortId(full)} (promoted memory and living docs are kept)`,
  );
}

async function cmdSync(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: { "no-auto-extract": { type: "boolean" } },
  });
  const id = positionals[0];

  const reports = syncReports(db, id);

  const inserted = reports.reduce((sum, r) => sum + r.inserted, 0);
  const skipped = reports.reduce((sum, r) => sum + r.skippedLines, 0);
  console.log(
    `Ingested ${inserted} new events from ${reports.length} run(s)` +
      (skipped > 0 ? ` (${skipped} unreadable line(s) skipped)` : ""),
  );

  // Background auto-extract: only for a single session, never auto-applies.
  if (values["no-auto-extract"] || !id) return;
  try {
    const sessionId = resolveSession(db, id).id;
    if (shouldAutoExtract(db, sessionId, inserted)) {
      await attemptExtraction(db, sessionId);
    }
  } catch (error) {
    console.warn(
      `Auto-extraction skipped; retry with 'oma extract ${id}': ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

function syncReports(db: Database, id?: string) {
  return id
    ? listAgentRuns(db, resolveSession(db, id).id)
        .map((run) => ingestRun(db, run))
        .filter((r) => r !== null)
    : ingestAll(db);
}

async function cmdSearch(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      repo: { type: "string" },
      limit: { type: "string" },
      "memory-only": { type: "boolean" },
    },
  });

  const query = positionals.join(" ");
  if (!query) fail("search needs a query");
  const limit = values.limit ? Number.parseInt(values.limit, 10) : 10;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    fail("search --limit must be an integer between 1 and 100");
  }

  const hits = search(db, query, {
    repo_path: values.repo,
    limit,
    includeEvents: !values["memory-only"],
  });
  console.log(formatSearchHits(query, hits));
}

async function cmdRemember(db: Database, argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      kind: { type: "string" },
      body: { type: "string" },
      repo: { type: "string" },
      global: { type: "boolean" },
      confidence: { type: "string" },
    },
  });

  const title = positionals.join(" ");
  const kind = values.kind ?? "decision";
  if (!title) fail("remember needs a title");
  if (!isMemoryKind(kind))
    fail(`kind must be one of: ${MEMORY_KINDS.join(", ")}`);
  if (!values.body) fail("remember needs --body (record why, not only what)");
  const confidence = values.confidence
    ? Number.parseFloat(values.confidence)
    : undefined;
  if (
    confidence !== undefined &&
    (!Number.isFinite(confidence) || confidence < 0 || confidence > 1)
  ) {
    fail("remember --confidence must be between 0 and 1");
  }

  const memory = createMemory(db, {
    kind,
    title,
    body: values.body,
    scope: values.global ? "global" : "repo",
    repo_path: values.global ? null : (values.repo ?? process.cwd()),
    confidence,
  });
  console.log(`Recorded ${memory.kind}: ${memory.title}`);
}

async function cmdMcp(db: Database): Promise<void> {
  const { serveStdio } = await import("@oma/mcp");
  await serveStdio({
    db,
    repoPath: process.env.OMA_REPO_PATH ?? process.cwd(),
    sessionId: process.env.OMA_SESSION_ID,
  });
}

async function main(): Promise<void> {
  const [command, ...rest] = process.argv.slice(2);

  if (!command || command === "help" || command === "--help") {
    console.log(USAGE);
    return;
  }

  const db = openDb();

  switch (command) {
    case "new":
      return cmdNew(db, rest);
    case "ls":
      return cmdLs(db);
    case "watch":
      return cmdWatch(db, rest);
    case "status":
      return cmdStatus(db, rest);
    case "attach":
      return cmdAttach(db, rest);
    case "switch":
      return cmdSwitch(db, rest);
    case "resume":
      return cmdResume(db, rest);
    case "fork":
      return cmdFork(db, rest);
    case "extract":
      return cmdExtract(db, rest);
    case "promote":
      return cmdPromote(db, rest);
    case "end":
      return cmdEnd(db, rest);
    case "rm":
      return cmdRm(db, rest);
    case "sync":
      return cmdSync(db, rest);
    case "search":
      return cmdSearch(db, rest);
    case "remember":
      return cmdRemember(db, rest);
    case "mcp":
      return cmdMcp(db);
    default:
      fail(`unknown command '${command}'\n\n${USAGE}`);
  }
}

main().catch((error: unknown) => {
  fail(error instanceof Error ? error.message : String(error));
});
