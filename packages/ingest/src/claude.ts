import type { EventRole, NormalizedEvent } from "@oma/core";
import {
  asRecord,
  asString,
  parseLines,
  fromTranscriptFile,
  seqFor,
  truncate,
  type ParseResult,
  type TranscriptParser,
} from "./types.ts";

/** Tools whose use means the run changed a file on disk. */
const WRITE_TOOLS = new Set(["Write", "Edit", "NotebookEdit", "MultiEdit"]);

function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((block) => asString(asRecord(block)?.text) ?? "")
      .filter((t) => t !== "")
      .join("\n");
  }
  return "";
}

/**
 * Claude Code writes one JSON object per line to
 * `~/.claude/projects/<slug>/<sessionId>.jsonl`.
 *
 * Only `user` and `assistant` lines carry conversation; every other type is
 * either metadata or an implementation detail (`attachment`, `queue-operation`,
 * `last-prompt`, …). Unknown types are ignored rather than treated as errors,
 * because Claude adds new ones between releases.
 */
export function parseClaudeTranscript(content: string): ParseResult {
  const { lines, skipped } = parseLines(content);
  const events: NormalizedEvent[] = [];
  const touchedFiles = new Set<string>();

  let nativeSessionId: string | null = null;
  let cwd: string | null = null;
  let gitBranch: string | null = null;
  // Subagent transcripts are `isSidechain` and live under
  // `<slug>/<parentSessionId>/subagents/`; the parent is in the path, not the
  // payload, so it is filled in by the caller that knows where it read from.
  const parentSessionId: string | null = null;

  for (const { index, value } of lines) {
    nativeSessionId ??= asString(value.sessionId);
    cwd ??= asString(value.cwd);
    gitBranch ??= asString(value.gitBranch);

    const type = asString(value.type);
    const ts = asString(value.timestamp) ?? new Date(0).toISOString();

    if (type === "file-history-snapshot") {
      const backups = asRecord(asRecord(value.snapshot)?.trackedFileBackups);
      for (const path of Object.keys(backups ?? {})) touchedFiles.add(path);
      continue;
    }

    if (type !== "user" && type !== "assistant") continue;

    const message = asRecord(value.message);
    if (!message) continue;

    const role: EventRole = type === "assistant" ? "assistant" : "user";
    const content = message.content;

    // A plain user turn is a bare string rather than a block array.
    if (typeof content === "string") {
      events.push({
        seq: seqFor(index, 0),
        ts,
        role,
        kind: "text",
        tool_name: null,
        text: truncate(content),
        raw: value,
      });
      continue;
    }

    if (!Array.isArray(content)) continue;

    content.forEach((rawBlock, blockIndex) => {
      const block = asRecord(rawBlock);
      if (!block) return;
      const seq = seqFor(index, blockIndex);

      switch (asString(block.type)) {
        case "text":
          events.push({
            seq,
            ts,
            role,
            kind: "text",
            tool_name: null,
            text: truncate(asString(block.text) ?? ""),
            raw: block,
          });
          break;

        case "thinking":
          events.push({
            seq,
            ts,
            role,
            kind: "thinking",
            tool_name: null,
            text: truncate(asString(block.thinking) ?? ""),
            raw: block,
          });
          break;

        case "tool_use": {
          const name = asString(block.name);
          const input = asRecord(block.input) ?? {};
          const filePath = asString(input.file_path);
          if (name && WRITE_TOOLS.has(name) && filePath) {
            touchedFiles.add(filePath);
          }
          events.push({
            seq,
            ts,
            role,
            kind: "tool_use",
            tool_name: name,
            // Indexing the input makes commands and edited paths searchable.
            text: truncate(JSON.stringify(input)),
            raw: block,
          });
          break;
        }

        case "tool_result":
          events.push({
            seq,
            ts,
            role,
            kind: "tool_result",
            tool_name: null,
            text: truncate(toolResultText(block.content)),
            raw: block,
          });
          break;

        default:
          events.push({
            seq,
            ts,
            role,
            kind: "unknown",
            tool_name: null,
            text: "",
            raw: block,
          });
      }
    });
  }

  return {
    events,
    meta: { nativeSessionId, cwd, gitBranch, parentSessionId },
    touchedFiles: [...touchedFiles],
    skippedLines: skipped,
  };
}

export const claudeParser: TranscriptParser = {
  agent: "claude",
  readEvents: fromTranscriptFile(parseClaudeTranscript),
};
