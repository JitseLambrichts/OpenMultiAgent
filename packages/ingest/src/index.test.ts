import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentName } from "@oma/core";
import {
  createAgentRun,
  createSession,
  listAgentRuns,
  listEventsPage,
  openDb,
} from "@oma/core";
import { ingestRun, parseTranscriptFile, parserFor } from "./index.ts";

const TRANSCRIPTS = join(import.meta.dir, "../../../testdata/transcripts");
const OPENCODE_SESSION = join(
  TRANSCRIPTS,
  "opencode-storage/session/proj-demo/ses_demo.json",
);

/**
 * A custom agent's id is whatever the user typed, so the parser can only be
 * found through the binary it runs. These tests install one in a throwaway
 * OMA_HOME.
 */
function homeWithAgent(id: string, binary: string): string {
  const home = mkdtempSync(join(tmpdir(), "oma-ingest-"));
  writeFileSync(
    join(home, "custom-agents.json"),
    JSON.stringify([{ id, name: id, binary, launchArgs: [], symbol: "terminal" }]),
  );
  homes.push(home);
  return home;
}

const homes: string[] = [];
const previousHome = process.env.OMA_HOME;

afterAll(() => {
  if (previousHome === undefined) delete process.env.OMA_HOME;
  else process.env.OMA_HOME = previousHome;
  for (const home of homes) rmSync(home, { recursive: true, force: true });
});

describe("ingestRun", () => {
  test("backfills a native session id discovered inside a transcript", () => {
    const db = openDb({ path: ":memory:" });
    const session = createSession(db, {
      repo_path: "/repo",
      worktree_path: "/repo",
    });
    const run = createAgentRun(db, {
      session_id: session.id,
      agent: "codex",
      native_session_id: null,
      transcript_path: join(
        import.meta.dir,
        "../../../testdata/transcripts/codex-sample.jsonl",
      ),
    });

    ingestRun(db, run);

    expect(listAgentRuns(db, session.id)[0]?.native_session_id).toBe(
      "019ff1c2-1111-2222-3333-444455556666",
    );
  });

  test("ingests an OpenCode session tree through a custom agent id", () => {
    process.env.OMA_HOME = homeWithAgent("ocode", "opencode");
    const db = openDb({ path: ":memory:" });
    const session = createSession(db, {
      repo_path: "/repo",
      worktree_path: "/repo",
    });
    const run = createAgentRun(db, {
      session_id: session.id,
      agent: "ocode",
      native_session_id: null,
      transcript_path: OPENCODE_SESSION,
    });

    const report = ingestRun(db, run);

    expect(report?.inserted).toBeGreaterThan(0);
    expect(listAgentRuns(db, session.id)[0]?.native_session_id).toBe("ses_demo");
    expect(
      listEventsPage(db, { session_id: session.id }).items.map((e) => e.kind),
    ).toContain("tool_use");
  });
});

describe("parserFor", () => {
  test("routes a custom agent by the binary it runs, not by its id", () => {
    process.env.OMA_HOME = homeWithAgent("mycode", "opencode");
    expect(parserFor("mycode").agent).toBe("opencode");
  });

  test("routes cursor-agent to the Cursor reader", () => {
    process.env.OMA_HOME = homeWithAgent("cursor", "cursor-agent");
    expect(parserFor("cursor").agent).toBe("cursor");
  });

  test("falls back to the empty parser for an unknown binary", () => {
    process.env.OMA_HOME = homeWithAgent("grok", "grok");
    expect(parserFor("grok").readEvents(OPENCODE_SESSION).events).toEqual([]);
  });
});

describe("parseTranscriptFile", () => {
  test("lets a directory-backed parser read the tree itself", () => {
    process.env.OMA_HOME = homeWithAgent("ocode", "opencode");
    const result = parseTranscriptFile("ocode", OPENCODE_SESSION);
    expect(result.meta.nativeSessionId).toBe("ses_demo");
    expect(result.events.length).toBeGreaterThan(0);
  });
});

describe("the captured-pane fallback", () => {
  test("is recognised by the locator, whichever agent the run used", () => {
    const dir = mkdtempSync(join(tmpdir(), "oma-pane-dispatch-"));
    homes.push(dir);
    const log = join(dir, "run-1.pane.log");
    writeFileSync(log, "some terminal output\n");

    for (const agent of ["terminal", "claude", "grok"]) {
      const result = parseTranscriptFile(agent, log);
      expect({ agent, texts: result.events.map((event) => event.text) }).toEqual(
        { agent, texts: ["some terminal output"] },
      );
    }
  });

  test("never shadows an agent's own transcript", () => {
    const result = parseTranscriptFile(
      "claude",
      join(TRANSCRIPTS, "claude-sample.jsonl"),
    );
    expect(result.events.every((event) => event.role === "system")).toBe(false);
  });
});

/**
 * Every parser reads from a locator, never from content handed to it: a JSONL
 * file for Claude, Codex and Gemini, a directory tree for OpenCode. Anything
 * that only knows how to parse a string cannot serve an agent that does not
 * write one file per session.
 */
describe("the parser contract", () => {
  test("every parser reads its own source from a locator", () => {
    const cases: Array<[AgentName, string]> = [
      ["claude", join(TRANSCRIPTS, "claude-sample.jsonl")],
      ["codex", join(TRANSCRIPTS, "codex-sample.jsonl")],
      ["gemini", join(TRANSCRIPTS, "gemini-sample.jsonl")],
    ];
    for (const [agent, locator] of cases) {
      const result = parserFor(agent).readEvents(locator);
      expect({ agent, events: result.events.length > 0 }).toEqual({
        agent,
        events: true,
      });
    }
  });

  test("a locator that is not there yields an empty result, never a throw", () => {
    for (const agent of ["claude", "codex", "gemini"]) {
      const result = parserFor(agent).readEvents("/nope/missing.jsonl");
      expect({ agent, events: result.events }).toEqual({ agent, events: [] });
    }
  });
});
