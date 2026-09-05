import { afterEach, expect, test } from "bun:test";
import { parentAlive } from "./index.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tempDirs: string[] = [];

afterEach(() => {
  while (tempDirs.length) {
    rmSync(tempDirs.pop()!, { recursive: true, force: true });
  }
});

test("sidecar serves newline-delimited requests and shuts down cleanly", async () => {
  const omaHome = mkdtempSync(join(tmpdir(), "oma-desktop-home-"));
  tempDirs.push(omaHome);
  const process = Bun.spawn(["bun", "run", join(import.meta.dir, "index.ts")], {
    env: { ...Bun.env, OMA_HOME: omaHome },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  process.stdin.write(
    '{"jsonrpc":"2.0","id":1,"method":"system.hello","params":{}}\n',
  );
  process.stdin.write(
    '{"jsonrpc":"2.0","id":2,"method":"system.shutdown","params":{}}\n',
  );
  process.stdin.end();

  const [code, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
  ]);

  expect(code).toBe(0);
  expect(stderr).toBe("");
  expect(
    stdout
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line)),
  ).toEqual([
    {
      jsonrpc: "2.0",
      id: 1,
      result: {
        protocol_version: 1,
        app_version: "0.1.0",
        agents: ["claude", "codex", "gemini", "terminal"],
      },
    },
    {
      jsonrpc: "2.0",
      id: 2,
      result: { shutting_down: true },
    },
  ]);
});

test("sidecar answers each request while the client keeps stdin open", async () => {
  const omaHome = mkdtempSync(join(tmpdir(), "oma-desktop-home-"));
  tempDirs.push(omaHome);
  const process = Bun.spawn(["bun", "run", join(import.meta.dir, "index.ts")], {
    env: { ...Bun.env, OMA_HOME: omaHome },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  const reader = process.stdout.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  const nextLine = async (): Promise<string> => {
    while (!buffered.includes("\n")) {
      const { value, done } = await reader.read();
      if (done) throw new Error("sidecar closed stdout early");
      buffered += decoder.decode(value, { stream: true });
    }
    const index = buffered.indexOf("\n");
    const line = buffered.slice(0, index);
    buffered = buffered.slice(index + 1);
    return line;
  };
  const withTimeout = <T>(promise: Promise<T>, ms: number) =>
    Promise.race([
      promise,
      new Promise<T>((_, reject) =>
        setTimeout(() => reject(new Error(`no response within ${ms}ms`)), ms),
      ),
    ]);

  process.stdin.write(
    '{"jsonrpc":"2.0","id":1,"method":"system.hello","params":{}}\n',
  );
  expect(JSON.parse(await withTimeout(nextLine(), 5000))).toMatchObject({
    id: 1,
    result: { protocol_version: 1 },
  });

  process.stdin.write(
    '{"jsonrpc":"2.0","id":2,"method":"system.health","params":{}}\n',
  );
  expect(JSON.parse(await withTimeout(nextLine(), 5000))).toMatchObject({
    id: 2,
    result: { ok: true },
  });

  process.stdin.write(
    '{"jsonrpc":"2.0","id":3,"method":"system.shutdown","params":{}}\n',
  );
  expect(JSON.parse(await withTimeout(nextLine(), 5000))).toMatchObject({
    id: 3,
    result: { shutting_down: true },
  });
  reader.releaseLock();
  expect(await withTimeout(process.exited, 5000)).toBe(0);
});

test("parentAlive probes liveness instead of trusting a cached ppid", () => {
  expect(parentAlive(process.pid)).toBe(true);
  expect(parentAlive(1)).toBe(false);
  expect(parentAlive(2147483000)).toBe(false);
});

test("sidecar exits on its own when its parent process disappears", async () => {
  const omaHome = mkdtempSync(join(tmpdir(), "oma-desktop-home-"));
  tempDirs.push(omaHome);
  const entry = join(import.meta.dir, "index.ts");
  // `sleep` keeps the sidecar's stdin open, so only the parent watchdog can
  // end it once the intermediate shell (its parent) is killed.
  const shell = Bun.spawn(
    ["/bin/sh", "-c", `sleep 30 | bun run ${JSON.stringify(entry)}`],
    {
      env: { ...Bun.env, OMA_HOME: omaHome },
      stdout: "ignore",
      stderr: "ignore",
    },
  );
  await Bun.sleep(1500);
  const findSidecar = () =>
    Bun.spawnSync(["pgrep", "-f", `bun run ${entry}`])
      .stdout.toString()
      .trim()
      .split("\n")
      .filter(Boolean);
  expect(findSidecar().length).toBeGreaterThan(0);

  shell.kill(9);
  await shell.exited;
  const started = Date.now();
  let survivors = findSidecar();
  while (survivors.length > 0 && Date.now() - started < 8000) {
    await Bun.sleep(400);
    survivors = findSidecar();
  }
  for (const pid of survivors) Bun.spawnSync(["kill", "-9", pid]);
  Bun.spawnSync(["pkill", "-f", "sleep 30"]);
  expect(survivors).toEqual([]);
}, 15000);
