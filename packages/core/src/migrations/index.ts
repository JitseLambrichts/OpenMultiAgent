/**
 * Migrations are imported as text so `bun build --compile` embeds them in the
 * desktop sidecar binary; a directory scan would fail inside the bundle.
 * Add every new migration file here; `db.test.ts` verifies the list is complete.
 */
import m001 from "./001_init.sql" with { type: "text" };
import m002 from "./002_promotion_candidates.sql" with { type: "text" };
import m003 from "./003_memory_confidence.sql" with { type: "text" };
import m004 from "./004_agent_run_identity.sql" with { type: "text" };
import m005 from "./005_repair_agent_run_identity_indexes.sql" with { type: "text" };
import m006 from "./006_projects.sql" with { type: "text" };

export interface EmbeddedMigration {
  name: string;
  sql: string;
}

export const EMBEDDED_MIGRATIONS: readonly EmbeddedMigration[] = [
  { name: "001_init.sql", sql: m001 },
  { name: "002_promotion_candidates.sql", sql: m002 },
  { name: "003_memory_confidence.sql", sql: m003 },
  { name: "004_agent_run_identity.sql", sql: m004 },
  { name: "005_repair_agent_run_identity_indexes.sql", sql: m005 },
  { name: "006_projects.sql", sql: m006 },
];
