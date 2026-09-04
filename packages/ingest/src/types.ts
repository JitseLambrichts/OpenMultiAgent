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
  parse(content: string): ParseResult;
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
