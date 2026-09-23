import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { isBuiltinAgentName } from "./types.ts";
import { omaHome } from "./paths.ts";

export interface CustomAgentDef {
  id: string;
  name: string;
  binary: string;
  launchArgs: string[];
  /**
   * argv for the one-shot, non-interactive run the extraction pipeline makes.
   * Empty means "fall back to the adapter's built-in guess", which is only
   * right for CLIs whose interactive form also accepts a bare prompt.
   */
  headlessArgs: string[];
  symbol: string;
}

export const DEFAULT_AGENT_SYMBOL = "terminal";

export interface CustomAgentInput {
  id?: string;
  name?: string;
  binary?: string;
  launchArgs?: string[];
  headlessArgs?: string[];
  symbol?: string;
}

export function customAgentsPath(home = omaHome()): string {
  return join(home, "custom-agents.json");
}

export function normalizeAgentId(value: string): string {
  return value.trim().toLowerCase().replaceAll(/\s+/g, "-");
}

function normalizeSymbol(value: unknown): string {
  if (value == null || value === "") return DEFAULT_AGENT_SYMBOL;
  if (
    typeof value !== "string" ||
    value.length > 64 ||
    !/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(value)
  ) {
    throw new Error("symbol must be a lowercase SF Symbol name");
  }
  return value;
}

function normalizeArgs(value: unknown, field: string): string[] {
  const args = value ?? [];
  if (!Array.isArray(args) || args.some((a) => typeof a !== "string")) {
    throw new Error(`${field} must be a string array`);
  }
  if (args.some((a: string) => a.length > 500)) {
    throw new Error(`${field} entries are too long`);
  }
  return args as string[];
}

export function validateCustomAgentDef(input: CustomAgentInput): CustomAgentDef {
  const id = normalizeAgentId(input.id ?? input.name ?? "");
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(id)) {
    throw new Error(
      "agent id must start with a letter or digit and contain only a-z, 0-9, - or _",
    );
  }
  if (isBuiltinAgentName(id)) {
    throw new Error(`'${id}' is a built-in agent and cannot be customized`);
  }
  const name = input.name?.trim() || id;
  const binary = input.binary?.trim() || id;
  if (!/^[^\s\/][^\s]*$/.test(binary)) {
    throw new Error("binary must be a single executable name or absolute path");
  }
  return {
    id,
    name,
    binary,
    launchArgs: normalizeArgs(input.launchArgs, "launchArgs"),
    headlessArgs: normalizeArgs(input.headlessArgs, "headlessArgs"),
    symbol: normalizeSymbol(input.symbol),
  };
}

function parseFile(path: string): CustomAgentDef[] {
  try {
    const raw = readFileSync(path, "utf8");
    if (!raw.trim()) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const out: CustomAgentDef[] = [];
    for (const entry of parsed) {
      if (!entry || typeof entry !== "object") continue;
      try {
        out.push(validateCustomAgentDef(entry as Record<string, unknown>));
      } catch {
        continue;
      }
    }
    return out;
  } catch {
    return [];
  }
}

export function listCustomAgents(home = omaHome()): CustomAgentDef[] {
  const path = customAgentsPath(home);
  if (!existsSync(path)) return [];
  return parseFile(path);
}

function writeAll(defs: CustomAgentDef[], home = omaHome()): CustomAgentDef[] {
  const path = customAgentsPath(home);
  mkdirSync(dirname(path), { recursive: true });
  const sorted = [...defs].sort((a, b) => a.id.localeCompare(b.id));
  writeFileSync(path, `${JSON.stringify(sorted, null, 2)}\n`);
  return sorted;
}

export function addCustomAgent(
  input: CustomAgentInput,
  home = omaHome(),
): CustomAgentDef {
  const def = validateCustomAgentDef(input);
  const existing = listCustomAgents(home);
  if (existing.some((d) => d.id === def.id)) {
    throw new Error(`agent '${def.id}' already exists`);
  }
  writeAll([...existing, def], home);
  return def;
}

export function updateCustomAgent(
  id: string,
  input: Omit<CustomAgentInput, "id">,
  home = omaHome(),
): CustomAgentDef {
  const current = listCustomAgents(home);
  const found = current.find((d) => d.id === normalizeAgentId(id));
  if (!found) throw new Error(`unknown agent '${id}'`);
  // Spreading `input` wholesale would let an explicit `undefined` - which is
  // what a client that predates a field sends - reset that field to its
  // default. Only the keys that carry a value take part in the merge.
  const patch = Object.fromEntries(
    Object.entries(input).filter(([, value]) => value !== undefined),
  );
  const updated = validateCustomAgentDef({ ...found, ...patch, id: found.id });
  writeAll(
    current.map((d) => (d.id === found.id ? updated : d)),
    home,
  );
  return updated;
}

export function removeCustomAgent(id: string, home = omaHome()): string {
  const current = listCustomAgents(home);
  const target = normalizeAgentId(id);
  if (!current.some((d) => d.id === target))
    throw new Error(`unknown agent '${id}'`);
  writeAll(
    current.filter((d) => d.id !== target),
    home,
  );
  return target;
}
