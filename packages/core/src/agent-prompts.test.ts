import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  combineSystemPrompts,
  getAgentSystemPrompt,
  listAgentSystemPrompts,
  setAgentSystemPrompt,
} from "./agent-prompts.ts";

function home(): string {
  return mkdtempSync(join(tmpdir(), "oma-prompts-"));
}

describe("agent system prompts", () => {
  test("sets, gets, lists, and clears prompts", () => {
    const dir = home();
    expect(listAgentSystemPrompts(dir)).toEqual([]);
    expect(getAgentSystemPrompt("claude", dir)).toBeUndefined();

    setAgentSystemPrompt("claude", "  You are careful.  ", dir);
    expect(getAgentSystemPrompt("Claude", dir)).toBe("You are careful.");
    expect(listAgentSystemPrompts(dir)).toEqual([
      { agent: "claude", systemPrompt: "You are careful." },
    ]);

    setAgentSystemPrompt("codex", "Second", dir);
    expect(listAgentSystemPrompts(dir).map((p) => p.agent)).toEqual([
      "claude",
      "codex",
    ]);

    const cleared = setAgentSystemPrompt("claude", "   ", dir);
    expect(cleared).toBeNull();
    expect(getAgentSystemPrompt("claude", dir)).toBeUndefined();
  });

  test("rejects bad slugs and oversized prompts", () => {
    const dir = home();
    expect(() => setAgentSystemPrompt("Bad Name!", "x", dir)).toThrow(/slug/);
    expect(() => setAgentSystemPrompt("claude", "x".repeat(20_001), dir)).toThrow(
      /too long/,
    );
  });

  test("combines configured prompt before handoff", () => {
    expect(combineSystemPrompts(undefined, undefined)).toBeUndefined();
    expect(combineSystemPrompts("  ", "")).toBeUndefined();
    expect(combineSystemPrompts("persona", "handoff")).toBe("persona\nhandoff".replace("\n", "\n\n"));
    expect(combineSystemPrompts("persona", undefined)).toBe("persona");
    expect(combineSystemPrompts(undefined, "handoff")).toBe("handoff");
  });
});
