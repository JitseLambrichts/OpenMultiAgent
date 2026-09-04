import { afterEach, describe, expect, test } from "bun:test";
import { exec } from "./exec.ts";
import * as tmux from "./tmux.ts";

const names: string[] = [];

afterEach(async () => {
  for (const name of names.splice(0)) await tmux.killSession(name);
});

describe("tmux.newSession", () => {
  test("sets custom variables in the session even when a tmux server already exists", async () => {
    const anchor = `oma-env-anchor-${Date.now()}`;
    const target = `oma-env-target-${Date.now()}`;
    names.push(anchor, target);
    await tmux.newSession({ name: anchor, cwd: process.cwd(), command: "sleep 30" });
    await tmux.newSession({
      name: target,
      cwd: process.cwd(),
      command: "sleep 30",
      env: { OMA_TEST_SESSION_ENV: "isolated-value" },
    });

    const shown = await exec([
      "tmux",
      "show-environment",
      "-t",
      `=${target}`,
      "OMA_TEST_SESSION_ENV",
    ]);
    expect(shown.code).toBe(0);
    expect(shown.stdout.trim()).toBe("OMA_TEST_SESSION_ENV=isolated-value");
  });
});

describe("listSessions against a real tmux server", () => {
  test("parses a live oma- session with a printable separator", async () => {
    const name = `oma-list-${Date.now()}`;
    await exec(["tmux", "new-session", "-d", "-s", name, "sleep 30"]);
    try {
      const found = (await tmux.listSessions()).find((s) => s.name === name);
      expect(found).toBeDefined();
      expect(found!.sessionId).toBe(name.slice("oma-".length));
      expect(found!.windows).toBe(1);
      expect(new Date(found!.created).getFullYear()).toBeGreaterThan(2000);
    } finally {
      await exec(["tmux", "kill-session", "-t", `=${name}`]);
    }
  });
});
