import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { EMBEDDED_MIGRATIONS } from "./migrations/index.ts";
import { dbPath } from "./paths.ts";

interface Migration {
  version: number;
  name: string;
  sql: string;
}

function loadMigrations(): Migration[] {
  return EMBEDDED_MIGRATIONS.map(({ name, sql }) => {
    const version = Number.parseInt(name.slice(0, name.indexOf("_")), 10);
    if (Number.isNaN(version)) {
      throw new Error(`migration ${name} does not start with a number`);
    }
    return { version, name, sql };
  }).sort((a, b) => a.version - b.version);
}

export function migrate(db: Database): number {
  db.run(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
       version    INTEGER PRIMARY KEY,
       name       TEXT NOT NULL,
       applied_at TEXT NOT NULL
     )`,
  );

  const applied = new Set(
    db
      .query<{ version: number }, []>("SELECT version FROM schema_migrations")
      .all()
      .map((r) => r.version),
  );

  let count = 0;
  for (const migration of loadMigrations()) {
    if (applied.has(migration.version)) continue;
    db.transaction(() => {
      // `exec` is required for migration files containing multiple statements;
      // `run` may execute only the first and still let the version be recorded.
      db.exec(migration.sql);
      db.run(
        "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
        [migration.version, migration.name, new Date().toISOString()],
      );
    })();
    count++;
  }
  return count;
}

export interface OpenOptions {
  /** Absolute path, or `:memory:` for tests. */
  path?: string;
}

export function openDb(options: OpenOptions = {}): Database {
  const path = options.path ?? dbPath();
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }
  const db = new Database(path, { create: true });
  db.run("PRAGMA busy_timeout = 5000");
  db.run("PRAGMA journal_mode = WAL");
  db.run("PRAGMA foreign_keys = ON");
  migrate(db);
  return db;
}

export type { Database };
