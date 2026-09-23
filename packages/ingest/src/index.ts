import type { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import type { AgentName } from "@oma/core";
import {
  insertEvents,
  isPaneLog,
  listCustomAgents,
  listRunsWithTranscripts,
  recordArtifact,
  setNativeSessionId,
} from "@oma/core";
import { claudeParser } from "./claude.ts";
import { codexParser } from "./codex.ts";
import { cursorParser } from "./cursor.ts";
import { geminiParser } from "./gemini.ts";
import { opencodeParser } from "./opencode.ts";
import { paneParser } from "./pane.ts";
import { emptyResult, type ParseResult, type TranscriptParser } from "./types.ts";

export * from "./types.ts";
export { parseClaudeTranscript, claudeParser } from "./claude.ts";
export { parseCodexTranscript, codexParser } from "./codex.ts";
export { parseGeminiTranscript, geminiParser } from "./gemini.ts";
export { parseOpenCodeSession, opencodeParser } from "./opencode.ts";
export { parseCursorChat, cursorParser } from "./cursor.ts";
export { parsePaneLog, paneParser } from "./pane.ts";

const PARSERS: Partial<Record<AgentName, TranscriptParser>> = {
  claude: claudeParser,
  codex: codexParser,
  gemini: geminiParser,
};

/**
 * A custom agent's id is whatever the user typed, so it says nothing about the
 * transcript format. The binary does: a storage layout is a property of the
 * program, not of what someone named it in OMA.
 */
const BINARY_PARSERS: Record<string, TranscriptParser> = {
  opencode: opencodeParser,
  "cursor-agent": cursorParser,
};

function binaryParser(agent: AgentName): TranscriptParser | undefined {
  const binary = listCustomAgents().find((def) => def.id === agent)?.binary;
  if (!binary) return undefined;
  return BINARY_PARSERS[binary.split("/").at(-1) ?? binary];
}

const genericParser: TranscriptParser = {
  agent: "custom",
  readEvents: () => emptyResult(),
};

export function parserFor(agent: AgentName): TranscriptParser {
  return PARSERS[agent] ?? binaryParser(agent) ?? genericParser;
}

export function parseTranscriptFile(
  agent: AgentName,
  locator: string,
): ParseResult {
  // The pane log is OMA's own fallback capture, not something an agent wrote,
  // so the locator decides here rather than the agent: the same agent can have
  // a real transcript on one run and only a captured pane on the next.
  if (isPaneLog(locator)) return paneParser.readEvents(locator);
  return parserFor(agent).readEvents(locator);
}

export interface IngestReport {
  agent_run_id: string;
  transcript_path: string;
  inserted: number;
  skippedLines: number;
}

/**
 * Re-reads a transcript from the start and inserts anything new. Safe to call
 * repeatedly on a live session: `event(agent_run_id, seq)` is unique.
 */
export function ingestRun(
  db: Database,
  run: {
    id: string;
    session_id: string;
    agent: AgentName;
    native_session_id?: string | null;
    transcript_path: string | null;
  },
): IngestReport | null {
  if (!run.transcript_path || !existsSync(run.transcript_path)) return null;

  const result = parseTranscriptFile(run.agent, run.transcript_path);
  if (!run.native_session_id && result.meta.nativeSessionId) {
    setNativeSessionId(db, run.id, result.meta.nativeSessionId);
  }
  const inserted = insertEvents(db, run.session_id, run.id, result.events);
  for (const path of result.touchedFiles) {
    recordArtifact(db, run.session_id, path, "modified");
  }

  return {
    agent_run_id: run.id,
    transcript_path: run.transcript_path,
    inserted,
    skippedLines: result.skippedLines,
  };
}

/** Sweeps every run that has a known transcript. This is what `oma sync` runs. */
export function ingestAll(db: Database): IngestReport[] {
  const reports: IngestReport[] = [];
  for (const run of listRunsWithTranscripts(db)) {
    const report = ingestRun(db, run);
    if (report) reports.push(report);
  }
  return reports;
}
