import { existsSync, readFileSync } from "node:fs";
import type { AgentName, NormalizedEvent } from "@oma/core";

export interface TranscriptMeta {
  nativeSessionId: string | null;
  cwd: string | null;
  gitBranch: string | null;
  /**
   * Set when the transcript belongs to a subagent spawned by another run, so
   * ingest can attribute it to the parent session instead of orphaning it.
   */
  parentSessionId: string | null;
}

export interface ParseResult {
  events: NormalizedEvent[];
  meta: TranscriptMeta;
  /** Absolute paths the run wrote to, used to fill the `artifact` table. */
  touchedFiles: string[];
  /**
   * Lines that could not be parsed. Never fatal: the tail of a live transcript
   * is routinely a half-written line, and agent updates add event types this
   * parser has not seen. Callers can surface the count.
   */
  skippedLines: number;
}

export interface TranscriptParser {
  agent: AgentName;
  /**
   * Reads a run's conversation from its locator. A locator is whatever the
   * adapter's `resolveTranscript` handed back and the DB stored: a JSONL file
   * for Claude, Codex and Gemini, a session record for OpenCode, a chat
   * directory for Cursor. Parsers that are handed content instead cannot serve
   * an agent that does not write one file per session, which is most of them.
   */
  readEvents(locator: string): ParseResult;
}

export function emptyResult(): ParseResult {
  return {
    events: [],
    meta: {
      nativeSessionId: null,
      cwd: null,
      gitBranch: null,
      parentSessionId: null,
    },
    touchedFiles: [],
    skippedLines: 0,
  };
}

/**
 * Adapts a content parser to the locator contract, for the agents whose
 * transcript really is one file. A locator that is not there yet is normal —
 * discovery races the agent's first write — so it reads as empty rather than
 * throwing; malformed content still surfaces as the parser's own error.
 */
export function fromTranscriptFile(
  parse: (content: string) => ParseResult,
): (locator: string) => ParseResult {
  return (locator) =>
    existsSync(locator) ? parse(readFileSync(locator, "utf8")) : emptyResult();
}

/**
 * Individual events are capped so one enormous tool result cannot bloat the DB
 * or dominate the FTS index. The full payload stays in `raw_json`.
 */
export const MAX_TEXT_LENGTH = 8000;

export function truncate(text: string, max = MAX_TEXT_LENGTH): string {
  return text.length <= max ? text : `${text.slice(0, max)}…[truncated]`;
}

/** Blocks within a line get their own seq slot so ordering survives re-parses. */
export const BLOCKS_PER_LINE = 1000;

export function seqFor(lineIndex: number, blockIndex: number): number {
  return lineIndex * BLOCKS_PER_LINE + blockIndex;
}

export interface ParsedLine {
  index: number;
  value: Record<string, unknown>;
}

export interface ParsedLines {
  lines: ParsedLine[];
  skipped: number;
}

/** Blank lines are not counted as skipped; only lines that fail to parse are. */
export function parseLines(content: string): ParsedLines {
  const lines: ParsedLine[] = [];
  let skipped = 0;

  content.split("\n").forEach((line, index) => {
    const trimmed = line.trim();
    if (trimmed === "") return;
    try {
      const value = asRecord(JSON.parse(trimmed));
      if (value) lines.push({ index, value });
      else skipped++;
    } catch {
      skipped++;
    }
  });

  return { lines, skipped };
}

export function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

export function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}
