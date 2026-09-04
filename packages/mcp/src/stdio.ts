#!/usr/bin/env bun
/**
 * Entry point registered in the generated `.mcp.json` / Codex `-c` overrides.
 * Scope comes from the environment so the same binary serves every session.
 *
 * stdout belongs to the JSON-RPC transport; anything diagnostic goes to stderr.
 */
import { openDb } from "@oma/core";
import { serveStdio } from "./server.ts";

const db = openDb();

await serveStdio({
  db,
  repoPath: process.env.OMA_REPO_PATH,
  sessionId: process.env.OMA_SESSION_ID,
});
