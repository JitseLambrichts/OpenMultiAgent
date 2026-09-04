import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { withFileLock } from "./lock.ts";

const previousHome = process.env.OMA_HOME;
const homes: string[] = [];

afterEach(() => {
  if (previousHome === undefined) delete process.env.OMA_HOME;
  else process.env.OMA_HOME = previousHome;
  while (homes.length) rmSync(homes.pop()!, { recursive: true, force: true });
});

describe("withFileLock", () => {
  test("serializes independent callers and releases after completion", async () => {
    const home = mkdtempSync(join(tmpdir(), "oma-lock-"));
    homes.push(home);
    process.env.OMA_HOME = home;
    const events: string[] = [];

    await Promise.all([
      withFileLock("agent-start", async () => {
        events.push("first:start");
        await Bun.sleep(30);
        events.push("first:end");
      }),
      withFileLock("agent-start", async () => {
        events.push("second:start");
        events.push("second:end");
      }),
    ]);

    expect(events).toEqual([
      "first:start",
      "first:end",
      "second:start",
      "second:end",
    ]);
  });
});
