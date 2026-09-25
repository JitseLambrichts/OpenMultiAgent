import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { isAgentName } from "./types.ts";
import { omaHome } from "./paths.ts";

export const MAX_SYSTEM_PROMPT_LENGTH = 20_000;

export interface AgentSystemPrompt {
  agent: string;
  systemPrompt: string;
}

export function agentSystemPromptsPath(home = omaHome()): string {
  return join(home, "agent-system-prompts.json");
}

export function normalizePromptAgent(value: string): string {
  return value.trim().toLowerCase();
}

export function validateSystemPromptAgent(agent: string): string {
  const normalized = normalizePromptAgent(agent);
  if (!isAgentName(normalized)) {
    throw new Error("agent must be a valid slug (a-z, 0-9, -, _)");
  }
  return normalized;
}

export function validateSystemPromptText(value: unknown): string {
  if (typeof value !== "string") {
    throw new Error("system_prompt must be a string");
  }
  const trimmed = value.trim();
  if (trimmed.length > MAX_SYSTEM_PROMPT_LENGTH) {
    throw new Error(
      `system prompt is too long (max ${MAX_SYSTEM_PROMPT_LENGTH} characters)`,
    );
  }
  return trimmed;
}

function parseFile(path: string): Record<string, string> {
  try {
    const raw = readFileSync(path, "utf8");
    if (!raw.trim()) return {};
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: Record<string, string> = {};
    for (const [key, value] of Object.entries(
      parsed as Record<string, unknown>,
    )) {
      try {
        const agent = validateSystemPromptAgent(key);
        const text = validateSystemPromptText(value);
        if (text) out[agent] = text;
      } catch {
        continue;
      }
    }
    return out;
  } catch {
    return {};
  }
}

export function listAgentSystemPrompts(
  home = omaHome(),
): AgentSystemPrompt[] {
  const data = parseFile(agentSystemPromptsPath(home));
  return Object.entries(data)
    .map(([agent, systemPrompt]) => ({ agent, systemPrompt }))
    .sort((a, b) => a.agent.localeCompare(b.agent));
}

export function getAgentSystemPrompt(
  agent: string,
  home = omaHome(),
): string | undefined {
  const normalized = normalizePromptAgent(agent);
  const data = parseFile(agentSystemPromptsPath(home));
  return data[normalized];
}

function writeAll(data: Record<string, string>, home = omaHome()): void {
  const path = agentSystemPromptsPath(home);
  mkdirSync(dirname(path), { recursive: true });
  // Keys are unique, so the comparator never has to return 0.
  const sorted = Object.fromEntries(
    Object.entries(data).sort(([a], [b]) => (a < b ? -1 : 1)),
  );
  writeFileSync(path, `${JSON.stringify(sorted, null, 2)}\n`);
}

export function setAgentSystemPrompt(
  agent: string,
  systemPrompt: string,
  home = omaHome(),
): AgentSystemPrompt | null {
  const normalized = validateSystemPromptAgent(agent);
  const text = validateSystemPromptText(systemPrompt);
  const data = parseFile(agentSystemPromptsPath(home));
  if (!text) {
    delete data[normalized];
    writeAll(data, home);
    return null;
  }
  data[normalized] = text;
  writeAll(data, home);
  return { agent: normalized, systemPrompt: text };
}

/**
 * Combine a configured per-agent prompt with a runtime prompt (e.g. the
 * Handoff Brief). Empty parts are dropped; configured personality first so
 * the handoff reads as the most recent context.
 */
export function combineSystemPrompts(
  ...parts: Array<string | null | undefined>
): string | undefined {
  const cleaned = parts
    .map((p) => p?.trim() ?? "")
    .filter((p) => p.length > 0);
  if (cleaned.length === 0) return undefined;
  return cleaned.join("\n\n");
}
