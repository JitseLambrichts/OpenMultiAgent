import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const directory = join(import.meta.dir, "..", "testdata", "contracts");

describe("desktop contract fixtures", () => {
  test("every fixture is a complete JSON-RPC 2.0 envelope with a numeric id", () => {
    const files = readdirSync(directory).filter((name) => name.endsWith(".json"));
    expect(files.length).toBeGreaterThanOrEqual(10);
    for (const name of files) {
      const envelope = JSON.parse(readFileSync(join(directory, name), "utf8"));
      expect(envelope.jsonrpc).toBe("2.0");
      expect(typeof envelope.id).toBe("number");
      expect("result" in envelope !== "error" in envelope).toBe(true);
    }
  });

  test("error fixtures carry a stable code and an optional recovery hint", () => {
    for (const name of ["rpc-error.json", "rpc-error-conflict.json"]) {
      const envelope = JSON.parse(readFileSync(join(directory, name), "utf8"));
      expect(envelope.error.code).toBeLessThan(-32000);
      expect(typeof envelope.error.data.recovery).toBe("string");
    }
  });
});
