import type { AgentAdapter, AgentName } from "@oma/core";
import { claudeAdapter } from "./claude.ts";
import { codexAdapter } from "./codex.ts";
import { geminiAdapter } from "./gemini.ts";

export { claudeAdapter, writeMcpConfig } from "./claude.ts";
export { codexAdapter, mcpConfigArgs } from "./codex.ts";
export { geminiAdapter, writeGeminiSettings } from "./gemini.ts";

/**
 * Claude and Gemini accept a caller-provided session id while Codex does not.
 * That difference is kept behind `resolveTranscript`.
 */
const ADAPTERS: Partial<Record<AgentName, AgentAdapter>> = {
  claude: claudeAdapter,
  codex: codexAdapter,
  gemini: geminiAdapter,
};

export function adapterFor(agent: AgentName): AgentAdapter {
  const adapter = ADAPTERS[agent];
  if (!adapter) {
    throw new Error(
      `agent '${agent}' is not supported yet (available: ${Object.keys(ADAPTERS).join(", ")})`,
    );
  }
  return adapter;
}

export function availableAgents(): AgentName[] {
  return Object.keys(ADAPTERS) as AgentName[];
}
