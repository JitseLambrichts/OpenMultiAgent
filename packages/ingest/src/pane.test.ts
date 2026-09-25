import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parsePaneLog } from "./pane.ts";

const dirs: string[] = [];
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

function paneLog(content: string): string {
  const dir = mkdtempSync(join(tmpdir(), "oma-pane-log-"));
  dirs.push(dir);
  const path = join(dir, "run-1.pane.log");
  writeFileSync(path, content);
  return path;
}

const ESC = "\x1B";

describe("parsePaneLog", () => {
  test("strips the colour and cursor codes a terminal never shows as text", () => {
    const path = paneLog(
      `${ESC}[1;32mBuild succeeded${ESC}[0m\n${ESC}[2J${ESC}[HDone\n`,
    );
    expect(parsePaneLog(path).events.map((event) => event.text)).toEqual([
      "Build succeeded\nDone",
    ]);
  });

  test("keeps only what a redrawn line finally said", () => {
    const path = paneLog("Progress: 10%\rProgress: 50%\rProgress: 100%\n");
    expect(parsePaneLog(path).events[0]?.text).toBe("Progress: 100%");
  });

  test("reads CRLF, which is what a pty actually emits", () => {
    // Regression: a pane log is full of \r\n, and treating the trailing \r as
    // a redraw made every single line render as empty.
    const path = paneLog("first line\r\nsecond line\r\n");
    expect(parsePaneLog(path).events[0]?.text).toBe("first line\nsecond line");
  });

  test("still trims a redraw that ends in CRLF", () => {
    const path = paneLog("Progress: 10%\rProgress: 100%\r\ndone\r\n");
    expect(parsePaneLog(path).events[0]?.text).toBe("Progress: 100%\ndone");
  });

  test("drops the repeated frames a full-screen TUI paints", () => {
    const path = paneLog("Thinking…\nThinking…\nThinking…\nAnswer: 42\n");
    expect(parsePaneLog(path).events[0]?.text).toBe("Thinking…\nAnswer: 42");
  });

  test("splits into blocks on blank lines, so events stay readable units", () => {
    const path = paneLog("first block\nstill first\n\n\nsecond block\n");
    expect(parsePaneLog(path).events.map((event) => event.text)).toEqual([
      "first block\nstill first",
      "second block",
    ]);
  });

  test("marks the capture as terminal output rather than claiming a speaker", () => {
    const path = paneLog("some output\n");
    const [event] = parsePaneLog(path).events;
    expect(event?.role).toBe("system");
    expect(event?.kind).toBe("text");
    expect(event?.tool_name).toBeNull();
  });

  test("recovers no session metadata, because a pane carries none", () => {
    expect(parsePaneLog(paneLog("output\n")).meta).toEqual({
      nativeSessionId: null,
      cwd: null,
      gitBranch: null,
      parentSessionId: null,
    });
  });

  test("keeps the seq of earlier blocks when the log grows", () => {
    const first = parsePaneLog(paneLog("block one\n\nblock two\n"));
    const grown = parsePaneLog(paneLog("block one\n\nblock two\n\nblock three\n"));
    expect(grown.events.slice(0, 2).map((event) => event.seq)).toEqual(
      first.events.map((event) => event.seq),
    );
    expect(grown.events).toHaveLength(3);
  });

  test("truncates a block that would dominate the index on its own", () => {
    const path = paneLog(`${"x".repeat(20_000)}\n`);
    expect(parsePaneLog(path).events[0]?.text).toEndWith("…[truncated]");
  });

  test("a log that is not there reads as empty, never as a throw", () => {
    expect(parsePaneLog(join(tmpdir(), "oma-no-such.pane.log")).events).toEqual(
      [],
    );
  });
});
