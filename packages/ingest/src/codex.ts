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

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => asString(asRecord(block)?.text) ?? "")
    .filter((t) => t !== "")
    .join("\n");
}

function toRole(role: string | null): EventRole {
  if (role === "assistant") return "assistant";
  if (role === "user") return "user";
  // `developer` and `system` carry the preamble, not the conversation.
  return "system";
}

/**
 * Codex writes rollouts to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
 * Each line is `{timestamp, type, payload}`.
 *
 * `event_msg` largely duplicates `response_item` (an `agent_message` repeats the
 * assistant message), so only `response_item` is turned into conversation events;
 * indexing both would double every assistant answer in search results.
 */
export function parseCodexTranscript(content: string): ParseResult {
  const { lines, skipped } = parseLines(content);
  const events: NormalizedEvent[] = [];
  const touchedFiles = new Set<string>();

  let nativeSessionId: string | null = null;
  let cwd: string | null = null;
  let parentSessionId: string | null = null;

  for (const { index, value } of lines) {
    const type = asString(value.type);
    const payload = asRecord(value.payload);
    const ts = asString(value.timestamp) ?? new Date(0).toISOString();
    if (!payload) continue;

    if (type === "session_meta") {
      // `id` identifies this rollout and always matches the filename. For a
      // subagent thread `session_id` is the *parent* thread's id, so reading
      // `session_id` first would silently correlate the run to the wrong
      // session — verified against every rollout on disk.
      nativeSessionId ??= asString(payload.id) ?? asString(payload.session_id);
      cwd ??= asString(payload.cwd);
      parentSessionId ??=
        asString(payload.parent_thread_id) ??
        (asString(payload.thread_source) === "subagent"
          ? asString(payload.session_id)
          : null);
      continue;
    }

    if (type === "turn_context") {
      cwd ??= asString(payload.cwd);
      continue;
    }

    if (type !== "response_item") continue;

    const seq = seqFor(index, 0);

    switch (asString(payload.type)) {
      case "message": {
        const role = toRole(asString(payload.role));
        events.push({
          seq,
          ts,
          role,
          kind: "text",
          tool_name: null,
          text: truncate(contentText(payload.content)),
          raw: payload,
        });
        break;
      }

      case "reasoning": {
        const summary = Array.isArray(payload.summary)
          ? payload.summary
              .map((s) => asString(asRecord(s)?.text) ?? "")
              .filter((t) => t !== "")
              .join("\n")
          : "";
        events.push({
          seq,
          ts,
          role: "assistant",
          kind: "thinking",
          tool_name: null,
          // `encrypted_content` is opaque; only the summary is ever readable.
          text: truncate(summary),
          raw: payload,
        });
        break;
      }

      // `function_call` and `custom_tool_call` differ only in where the
      // arguments live: a JSON string under `arguments` versus `input`.
      case "function_call":
      case "custom_tool_call": {
        const args =
          asString(payload.arguments) ?? asString(payload.input) ?? "";
        events.push({
          seq,
          ts,
          role: "assistant",
          kind: "tool_use",
          tool_name: asString(payload.name),
          text: truncate(args),
          raw: payload,
        });
        break;
      }

      case "function_call_output":
      case "custom_tool_call_output": {
        const output = payload.output;
        events.push({
          seq,
          ts,
          role: "user",
          kind: "tool_result",
          tool_name: null,
          text: truncate(
            typeof output === "string" ? output : JSON.stringify(output ?? ""),
          ),
          raw: payload,
        });
        break;
      }

      default:
        events.push({
          seq,
          ts,
          role: "system",
          kind: "unknown",
          tool_name: null,
          text: "",
          raw: payload,
        });
    }
  }

  return {
    events,
    meta: { nativeSessionId, cwd, gitBranch: null, parentSessionId },
    // Codex edits files through shell commands, so there is no reliable
    // structured signal here the way Claude's file-history snapshots give one.
    // Touched files for Codex sessions come from `git status` instead.
    touchedFiles: [...touchedFiles],
    skippedLines: skipped,
  };
}

export const codexParser: TranscriptParser = {
  agent: "codex",
  readEvents: fromTranscriptFile(parseCodexTranscript),
};
