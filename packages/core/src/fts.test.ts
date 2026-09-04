import { describe, expect, test } from "bun:test";
import { toFtsQuery } from "./fts.ts";

describe("toFtsQuery", () => {
  test("quotes each term so punctuation is never parsed as FTS syntax", () => {
    expect(toFtsQuery("waarom gebruiken X?")).toBe(
      '"waarom" OR "gebruiken" OR "x"',
    );
  });

  test("neutralises characters that are FTS operators", () => {
    const q = toFtsQuery('NEAR("a" b) AND ^c');
    expect(() => q).not.toThrow();
    expect(q).not.toContain("(");
    expect(q).not.toContain("^");
  });

  test("keeps a trailing star as a prefix search", () => {
    expect(toFtsQuery("worktre*")).toBe('"worktre"*');
  });

  test("drops stop words but keeps meaningful short words", () => {
    expect(toFtsQuery("why do we use tmux")).toBe('"why" OR "use" OR "tmux"');
  });

  test("returns empty string when nothing searchable remains", () => {
    expect(toFtsQuery("   ??? ")).toBe("");
    expect(toFtsQuery("the a of")).toBe("");
  });
});
