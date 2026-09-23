import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  addCustomAgent,
  listCustomAgents,
  removeCustomAgent,
  updateCustomAgent,
  validateCustomAgentDef,
} from "./custom-agents.ts";

function home(): string {
  return mkdtempSync(join(tmpdir(), "oma-custom-"));
}

describe("custom agents", () => {
  test("rejects built-in ids and bad slugs", () => {
    expect(() => validateCustomAgentDef({ id: "claude" })).toThrow(/built-in/);
    expect(() => validateCustomAgentDef({ id: "Bad Name!" })).toThrow(
      /slug|id must/,
    );
    expect(() =>
      validateCustomAgentDef({ id: "opencode", binary: "has space" }),
    ).toThrow(/binary/);
  });

  test("adds, updates, and removes providers in OMA_HOME", () => {
    const dir = home();
    const added = addCustomAgent(
      { name: "Opencode", binary: "opencode", launchArgs: ["run"] },
      dir,
    );
    expect(added.id).toBe("opencode");
    expect(listCustomAgents(dir)).toHaveLength(1);
    expect(() => addCustomAgent({ id: "opencode" }, dir)).toThrow(
      /already exists/,
    );

    const updated = updateCustomAgent(
      "opencode",
      { binary: "opencode", launchArgs: [] },
      dir,
    );
    expect(updated.launchArgs).toEqual([]);
    expect(removeCustomAgent("opencode", dir)).toBe("opencode");
    expect(listCustomAgents(dir)).toEqual([]);
  });

  test("persists an SF Symbol and defaults a missing one to terminal", () => {
    const dir = home();
    const added = addCustomAgent(
      { name: "Opencode", binary: "opencode", symbol: "terminal.fill" },
      dir,
    );
    expect(added.symbol).toBe("terminal.fill");
    expect(listCustomAgents(dir)[0]?.symbol).toBe("terminal.fill");

    const untitled = addCustomAgent(
      { name: "Cursor", binary: "cursor-agent" },
      dir,
    );
    expect(untitled.symbol).toBe("terminal");

    const updated = updateCustomAgent(
      "cursor",
      { symbol: "cursorarrow" },
      dir,
    );
    expect(updated.symbol).toBe("cursorarrow");
  });

  test("persists headless arguments separately from launch arguments", () => {
    const dir = home();
    const added = addCustomAgent(
      {
        name: "Cursor",
        binary: "cursor-agent",
        launchArgs: [],
        headlessArgs: ["-p", "--output-format", "json", "{{prompt}}"],
      },
      dir,
    );
    expect(added.headlessArgs).toEqual([
      "-p",
      "--output-format",
      "json",
      "{{prompt}}",
    ]);
    expect(listCustomAgents(dir)[0]?.headlessArgs).toEqual(added.headlessArgs);

    const updated = updateCustomAgent("cursor", { headlessArgs: [] }, dir);
    expect(updated.headlessArgs).toEqual([]);
  });

  test("a partial update leaves the fields it does not mention alone", () => {
    const dir = home();
    addCustomAgent(
      {
        name: "Cursor",
        binary: "cursor-agent",
        launchArgs: ["--force"],
        headlessArgs: ["-p", "{{prompt}}"],
        symbol: "cursorarrow",
      },
      dir,
    );
    // A client that predates a field sends it as undefined rather than omitting
    // it; that must not reset the field to its default.
    const updated = updateCustomAgent(
      "cursor",
      {
        name: undefined,
        binary: undefined,
        launchArgs: undefined,
        headlessArgs: undefined,
        symbol: "hammer",
      },
      dir,
    );
    expect(updated).toEqual({
      id: "cursor",
      name: "Cursor",
      binary: "cursor-agent",
      launchArgs: ["--force"],
      headlessArgs: ["-p", "{{prompt}}"],
      symbol: "hammer",
    });
  });

  test("defaults missing headless arguments to an empty list", () => {
    expect(
      validateCustomAgentDef({ id: "grok", binary: "grok" }).headlessArgs,
    ).toEqual([]);
  });

  test("rejects headless arguments that are not strings", () => {
    expect(() =>
      validateCustomAgentDef({
        id: "grok",
        binary: "grok",
        headlessArgs: [3] as unknown as string[],
      }),
    ).toThrow(/headlessArgs/);
  });

  test("rejects an invalid SF Symbol name", () => {
    expect(() =>
      validateCustomAgentDef({
        id: "x",
        binary: "x",
        symbol: "Not A Symbol!",
      }),
    ).toThrow(/symbol/);
  });

  test("loads a legacy file without a symbol as terminal", () => {
    const dir = home();
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "custom-agents.json"),
      JSON.stringify([
        {
          id: "opencode",
          name: "Opencode",
          binary: "opencode",
          launchArgs: ["run"],
        },
      ]),
    );
    expect(listCustomAgents(dir)[0]?.symbol).toBe("terminal");
  });
});
