import type { Database } from "bun:sqlite";
import { existsSync, readFileSync } from "node:fs";
import type { AgentName } from "@oma/core";
import {
  insertEvents,
  listRunsWithTranscripts,
  recordArtifact,
  setNativeSessionId,
} from "@oma/core";
import { claudeParser } from "./claude.ts";
import { codexParser } from "./codex.ts";
import { geminiParser } from "./gemini.ts";
import type { ParseResult, TranscriptParser } from "./types.ts";

export * from "./types.ts";
export { parseClaudeTranscript, claudeParser } from "./claude.ts";
export { parseCodexTranscript, codexParser } from "./codex.ts";
export { parseGeminiTranscript, geminiParser } from "./gemini.ts";

const PARSERS: Partial<Record<AgentName, TranscriptParser>> = {
  claude: claudeParser,
  codex: codexParser,
  gemini: geminiParser,
};

export function parserFor(agent: AgentName): TranscriptParser {
  const parser = PARSERS[agent];
  if (!parser) throw new Error(`no transcript parser for agent '${agent}'`);
  return parser;
}

export function parseTranscriptFile(
  agent: AgentName,
  path: string,
): ParseResult {
  return parserFor(agent).parse(readFileSync(path, "utf8"));
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
