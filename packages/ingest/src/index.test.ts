import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import {
  createAgentRun,
  createSession,
  listAgentRuns,
  openDb,
} from "@oma/core";
import { ingestRun } from "./index.ts";

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
});
