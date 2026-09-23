import { describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  claudeProjectSlug,
  claudeTranscriptPath,
  cursorChatsDir,
  homeDirectory,
  isPaneLog,
  paneLogPath,
  opencodeStorageDir,
  tmuxSessionName,
  TMUX_PREFIX,
} from "./paths.ts";

/**
 * Every pair below was read off this machine: the directory name under
 * ~/.claude/projects and the `cwd` recorded inside the transcripts it holds.
 */
const REAL_PAIRS: Array<[cwd: string, dir: string]> = [
  [
    "/Users/jitselambrichts/Desktop/Desktop/Opteco/TestFable",
    "-Users-jitselambrichts-Desktop-Desktop-Opteco-TestFable",
  ],
  [
    "/Users/jitselambrichts/Desktop/Desktop/Vrije_Tijd/MultiAgent",
    "-Users-jitselambrichts-Desktop-Desktop-Vrije-Tijd-MultiAgent",
  ],
  [
    "/Users/jitselambrichts/Desktop/Desktop/Vrije_Tijd/OpenSource/HealthyCharacterV2",
    "-Users-jitselambrichts-Desktop-Desktop-Vrije-Tijd-OpenSource-HealthyCharacterV2",
  ],
  [
    "/Users/jitselambrichts/Desktop/Desktop/Opteco/marketforecasting-worktree-session-jittery-heron-h52c",
    "-Users-jitselambrichts-Desktop-Desktop-Opteco-marketforecasting-worktree-session-jittery-heron-h52c",
  ],
  // The dotted worktree dir is the interesting one: `/.worktrees` becomes `--worktrees`.
  [
    "/Users/jitselambrichts/Desktop/Desktop/Vrije_Tijd/TestDashboard/.worktrees/realtime-imbalance",
    "-Users-jitselambrichts-Desktop-Desktop-Vrije-Tijd-TestDashboard--worktrees-realtime-imbalance",
  ],
];

describe("claudeProjectSlug", () => {
  test.each(REAL_PAIRS)("%s", (cwd, dir) => {
    expect(claudeProjectSlug(cwd)).toBe(dir);
  });

  test("replaces every slash, underscore and dot", () => {
    expect(claudeProjectSlug("/a_b/c.d/e")).toBe("-a-b-c-d-e");
  });

  test("leaves an already-slugged string untouched", () => {
    const slug = claudeProjectSlug("/a/b");
    expect(claudeProjectSlug(slug)).toBe(slug);
  });
});

describe("claudeTranscriptPath", () => {
  test("is deterministic given cwd and a caller-supplied session id", () => {
    expect(
      claudeTranscriptPath("/Users/j/Vrije_Tijd/X", "abc-123", "/home"),
    ).toBe("/home/.claude/projects/-Users-j-Vrije-Tijd-X/abc-123.jsonl");
  });

  test("slugs the resolved path, since Claude does", () => {
    // Regression: a session started in /var/folders/... (a symlink to
    // /private/var/... on macOS) had its transcript filed under the resolved
    // path, so the derived path pointed at a file that never existed.
    const dir = mkdtempSync(join(tmpdir(), "oma-realpath-"));
    try {
      const derived = claudeTranscriptPath(dir, "abc-123", "/home");
      expect(derived).toBe(
        `/home/.claude/projects/${claudeProjectSlug(realpathSync(dir))}/abc-123.jsonl`,
      );
      if (realpathSync(dir) !== dir) {
        // The directory component must be the resolved slug, not the given one.
        expect(derived.split("/").at(-2)).not.toBe(claudeProjectSlug(dir));
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("falls back to the literal path for a directory that does not exist yet", () => {
    expect(claudeTranscriptPath("/nope/not/here", "abc", "/home")).toBe(
      "/home/.claude/projects/-nope-not-here/abc.jsonl",
    );
  });
});

describe("opencodeStorageDir", () => {
  test("defaults to the XDG data directory under the home", () => {
    expect(opencodeStorageDir({}, "/home")).toBe(
      "/home/.local/share/opencode/storage",
    );
  });

  test("honours XDG_DATA_HOME, which is where OpenCode actually looks", () => {
    expect(opencodeStorageDir({ XDG_DATA_HOME: "/data" }, "/home")).toBe(
      "/data/opencode/storage",
    );
  });
});

describe("cursorChatsDir", () => {
  test("is a fixed location in the home, unlike the XDG-aware ones", () => {
    expect(cursorChatsDir("/home")).toBe("/home/.cursor/chats");
  });
});

describe("paneLogPath", () => {
  test("is named so ingest can tell a captured pane from an agent transcript", () => {
    const path = paneLogPath("run-1", "/oma");
    expect(path).toBe("/oma/panes/run-1.pane.log");
    expect(isPaneLog(path)).toBe(true);
    expect(isPaneLog("/home/.codex/sessions/rollout-1.jsonl")).toBe(false);
  });
});

describe("homeDirectory", () => {
  test("prefers $HOME, which Bun's homedir() ignores but POSIX tools follow", () => {
    expect(homeDirectory({ HOME: "/home/dev" }, "/passwd/entry")).toBe(
      "/home/dev",
    );
  });

  test("falls back to the passwd entry when $HOME is unset or blank", () => {
    expect(homeDirectory({}, "/passwd/entry")).toBe("/passwd/entry");
    expect(homeDirectory({ HOME: "  " }, "/passwd/entry")).toBe(
      "/passwd/entry",
    );
  });
});

describe("tmuxSessionName", () => {
  test("prefixes so discovery never collides with foreign sessions", () => {
    expect(tmuxSessionName("s1")).toBe("oma-s1");
    expect(tmuxSessionName("s1").startsWith(TMUX_PREFIX)).toBe(true);
    expect("xirp-foo".startsWith(TMUX_PREFIX)).toBe(false);
  });
});
