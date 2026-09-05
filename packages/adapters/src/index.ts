import type { AgentAdapter, AgentName } from "@oma/core";
import { isBuiltinAgentName, listCustomAgents } from "@oma/core";
import { claudeAdapter } from "./claude.ts";
import { codexAdapter } from "./codex.ts";
import { geminiAdapter } from "./gemini.ts";
import { terminalAdapter } from "./terminal.ts";
import { createGenericAdapter } from "./generic.ts";

export { claudeAdapter, writeMcpConfig } from "./claude.ts";
export { codexAdapter, mcpConfigArgs } from "./codex.ts";
export { geminiAdapter, writeGeminiSettings } from "./gemini.ts";
export { terminalAdapter } from "./terminal.ts";
export { createGenericAdapter, renderCustomArgs } from "./generic.ts";

/**
 * Claude and Gemini accept a caller-provided session id while Codex does not.
 * That difference is kept behind `resolveTranscript`.
 */

export function adapterFor(agent: AgentName): AgentAdapter {
  switch (agent) {
    case "claude":
      return claudeAdapter;
    case "codex":
      return codexAdapter;
    case "gemini":
      return geminiAdapter;
    case "terminal":
      return terminalAdapter;
  }
  if (isBuiltinAgentName(agent)) {
    throw new Error(`agent '${agent}' is not supported yet`);
  }
  const custom = listCustomAgents().find((d) => d.id === agent);
  if (custom) return createGenericAdapter(custom);
  throw new Error(
    `unknown agent '${agent}' (available: ${availableAgents().join(", ")})`,
  );
}

export function availableAgents(): AgentName[] {
  return [
    "claude",
    "codex",
    "gemini",
    "terminal",
    ...listCustomAgents().map((d) => d.id),
  ];
}
