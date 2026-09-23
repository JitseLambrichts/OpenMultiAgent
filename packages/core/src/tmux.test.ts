import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

describe("tmux.pipePane against a real tmux server", () => {
  test("captures what the pane prints, into a directory it creates itself", async () => {
    const name = `oma-pipe-${Date.now()}`;
    names.push(name);
    const dir = mkdtempSync(join(tmpdir(), "oma-pane-"));
    // A path with a space proves the command is quoted, not concatenated.
    const log = join(dir, "with space", "run-1.pane.log");
    try {
      await tmux.newSession({
        name,
        cwd: process.cwd(),
        command: "sh -c 'sleep 0.3; echo oma-capture-marker; sleep 30'",
      });
      await tmux.pipePane(name, log);

      let captured = "";
      for (let i = 0; i < 40 && !captured.includes("oma-capture-marker"); i++) {
        await Bun.sleep(100);
        captured = existsSync(log) ? readFileSync(log, "utf8") : "";
      }
      expect(captured).toContain("oma-capture-marker");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("piping a session that is gone fails quietly, since cleanup races it", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oma-pane-"));
    try {
      await tmux.pipePane(`oma-absent-${Date.now()}`, join(dir, "x.pane.log"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
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
