import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { EMBEDDED_MIGRATIONS } from "./index.ts";

describe("embedded migrations", () => {
  test("cover every .sql file in the migrations directory, in order", () => {
    const onDisk = readdirSync(import.meta.dir)
      .filter((name) => name.endsWith(".sql"))
      .sort();
    expect(EMBEDDED_MIGRATIONS.map((m) => m.name)).toEqual(onDisk);
    for (const migration of EMBEDDED_MIGRATIONS) {
      expect(migration.sql).toBe(readFileSync(join(import.meta.dir, migration.name), "utf8"));
    }
  });
});
