import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseClaudeTranscript } from "./claude.ts";
import { parseCodexTranscript } from "./codex.ts";
import { parseGeminiTranscript } from "./gemini.ts";

/**
 * Contract test against the real transcripts on this machine. The fixtures in
 * `testdata/` are hand-written and therefore only prove the parser matches what
 * we *believe* the format is; this proves it matches what the agents actually
 * write today, and fails loudly when an agent update changes the format.
 *
 * Nothing is copied out of the transcript store and no transcript content is
 * ever asserted on or printed — only counts and ratios, so a failure cannot
 * leak private session data into test output.
 *
 * Skips itself when the stores are absent (e.g. CI).
 */

const SAMPLE_SIZE = 25;

function newestFiles(dir: string, match: RegExp, limit: number): string[] {
  if (!existsSync(dir)) return [];
  const found: string[] = [];

  const walk = (current: string, depth: number): void => {
    if (depth > 5) return;
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name);
      if (entry.isDirectory()) walk(path, depth + 1);
      else if (match.test(entry.name)) found.push(path);
    }
  };

  walk(dir, 0);
  return found
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)
    .slice(0, limit);
}

const CLAUDE_PROJECTS = join(homedir(), ".claude", "projects");

/**
 * Main-session transcripts sit directly in the project directory. Subagent
 * transcripts sit under `<slug>/<parentSessionId>/subagents/` and are named
 * `agent-<hash>.jsonl`, so the filename and directory assertions below apply
 * only to the top-level ones.
 */
const isMainTranscript = (path: string): boolean =>
  path.startsWith(`${CLAUDE_PROJECTS}/`) &&
  path.slice(CLAUDE_PROJECTS.length + 1).split("/").length === 2;

const claudeFiles = newestFiles(CLAUDE_PROJECTS, /\.jsonl$/, SAMPLE_SIZE);
const claudeMainFiles = claudeFiles.filter(isMainTranscript);
const codexFiles = newestFiles(
  join(homedir(), ".codex", "sessions"),
  /^rollout-.*\.jsonl$/,
  SAMPLE_SIZE,
);
const geminiFiles = newestFiles(
  join(homedir(), ".gemini", "tmp"),
  /^session-.*\.jsonl?$/,
  SAMPLE_SIZE,
);

describe.if(claudeFiles.length > 0)("real Claude transcripts", () => {
  test(`parse without throwing (${claudeFiles.length} files)`, () => {
    for (const path of claudeFiles) {
      expect(() => parseClaudeTranscript(readFileSync(path, "utf8"))).not.toThrow();
    }
  });

  test("yield events and recover session metadata", () => {
    const parsed = claudeFiles.map((p) =>
      parseClaudeTranscript(readFileSync(p, "utf8")),
    );
    const nonEmpty = parsed.filter((r) => r.events.length > 0);
    expect(nonEmpty.length).toBeGreaterThan(0);
    for (const result of nonEmpty) {
      expect(result.meta.nativeSessionId).not.toBeNull();
      expect(result.meta.cwd).not.toBeNull();
    }
  });

  test("a main transcript is named after the session id it reports", () => {
    for (const path of claudeMainFiles) {
      const result = parseClaudeTranscript(readFileSync(path, "utf8"));
      if (!result.meta.nativeSessionId) continue;
      expect(path.endsWith(`${result.meta.nativeSessionId}.jsonl`)).toBe(true);
    }
  });

  test("a main transcript sits in the directory slug of its cwd", async () => {
    const { claudeProjectSlug } = await import("@oma/core");
    for (const path of claudeMainFiles) {
      const result = parseClaudeTranscript(readFileSync(path, "utf8"));
      if (!result.meta.cwd) continue;
      const dir = path.split("/").at(-2);
      expect(dir).toBe(claudeProjectSlug(result.meta.cwd));
    }
  });

  test("subagent transcripts live under <slug>/<parentSessionId>/subagents", async () => {
    const { claudeSubagentDir } = await import("@oma/core");
    const nested = claudeFiles.filter((p) => !isMainTranscript(p));
    for (const path of nested) {
      const result = parseClaudeTranscript(readFileSync(path, "utf8"));
      if (!result.meta.cwd) continue;
      const parts = path.slice(CLAUDE_PROJECTS.length + 1).split("/");
      expect(parts[2]).toBe("subagents");
      expect(path.startsWith(claudeSubagentDir(result.meta.cwd, parts[1]!))).toBe(
        true,
      );
    }
  });

  test("almost every line is understood", () => {
    for (const path of claudeFiles) {
      const content = readFileSync(path, "utf8");
      const lines = content.split("\n").filter((l) => l.trim() !== "").length;
      const { skippedLines } = parseClaudeTranscript(content);
      // A live transcript may have one half-written line at the tail.
      expect({ file: path, skippedLines }).toEqual({
        file: path,
        skippedLines: Math.min(skippedLines, lines > 0 ? 1 : 0),
      });
    }
  });
});

describe.if(codexFiles.length > 0)("real Codex transcripts", () => {
  test(`parse without throwing (${codexFiles.length} files)`, () => {
    for (const path of codexFiles) {
      expect(() => parseCodexTranscript(readFileSync(path, "utf8"))).not.toThrow();
    }
  });

  test("recover the rollout's own id, which is the one in the filename", () => {
    for (const path of codexFiles) {
      const result = parseCodexTranscript(readFileSync(path, "utf8"));
      if (!result.meta.nativeSessionId) continue;
      expect(path).toContain(result.meta.nativeSessionId);
      expect(result.meta.cwd).not.toBeNull();
    }
  });

  test("a subagent rollout reports a parent distinct from its own id", () => {
    const withParent = codexFiles
      .map((p) => parseCodexTranscript(readFileSync(p, "utf8")).meta)
      .filter((m) => m.parentSessionId !== null);
    for (const meta of withParent) {
      expect(meta.parentSessionId).not.toBe(meta.nativeSessionId);
    }
  });

  test("known payload types dominate, so the format has not drifted", () => {
    let known = 0;
    let unknown = 0;
    for (const path of codexFiles) {
      for (const e of parseCodexTranscript(readFileSync(path, "utf8")).events) {
        if (e.kind === "unknown") unknown++;
        else known++;
      }
    }
    expect(known).toBeGreaterThan(0);
    expect(unknown / (known + unknown)).toBeLessThan(0.05);
  });
});

describe.if(geminiFiles.length > 0)("real Gemini transcripts", () => {
  test(`parse without throwing (${geminiFiles.length} files)`, () => {
    for (const path of geminiFiles) {
      expect(() => parseGeminiTranscript(readFileSync(path, "utf8"))).not.toThrow();
    }
  });

  test("recover native ids and usable conversation events", () => {
    const parsed = geminiFiles.map((path) =>
      parseGeminiTranscript(readFileSync(path, "utf8")),
    );
    for (const result of parsed) {
      expect(result.meta.nativeSessionId).not.toBeNull();
    }
    expect(parsed.some((result) => result.events.length > 0)).toBe(true);
  });

  test("almost every line remains readable as the JSONL format evolves", () => {
    for (const path of geminiFiles.filter((file) => file.endsWith(".jsonl"))) {
      const content = readFileSync(path, "utf8");
      const lines = content.split("\n").filter((line) => line.trim() !== "").length;
      const { skippedLines } = parseGeminiTranscript(content);
      expect(skippedLines).toBeLessThanOrEqual(lines > 0 ? 1 : 0);
    }
  });
});
