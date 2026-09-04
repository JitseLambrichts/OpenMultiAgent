import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import type { Database } from "bun:sqlite";
import {
  search,
  type SearchHit,
} from "@oma/core";

export const SERVER_NAME = "oma-memory";
export const SERVER_VERSION = "0.1.0";

/**
 * Rendered for the agent rather than returned as raw rows: the point of memory
 * is that an agent can read the answer, and provenance (which session, when,
 * how confident) is what lets it judge whether to trust it.
 */
export function renderHit(hit: SearchHit): string {
  if (hit.type === "memory") {
    const provenance = [
      `confidence ${hit.confidence.toFixed(2)}`,
      `recorded ${hit.created_at.slice(0, 10)}`,
      hit.source_session_id
        ? `session ${hit.source_session_id.slice(0, 8)}`
        : null,
    ]
      .filter(Boolean)
      .join(", ");
    return `[${hit.kind}] ${hit.title}\n${hit.body}\n(${provenance})`;
  }
  const label = hit.tool_name ? `${hit.kind}:${hit.tool_name}` : hit.kind;
  return `[transcript · ${hit.agent} · ${label} · ${hit.ts.slice(0, 16)}]\n${hit.text}`;
}

export function renderResults(query: string, hits: SearchHit[]): string {
  if (hits.length === 0) {
    return `No memory found for "${query}".`;
  }
  return hits.map(renderHit).join("\n\n---\n\n");
}

export interface McpServerOptions {
  db: Database;
  /**
   * Scopes results to one repository. Set per session so an agent working in
   * repo A does not get invariants that only hold in repo B.
   */
  repoPath?: string;
  sessionId?: string;
}

export function createMemoryServer(options: McpServerOptions): McpServer {
  const { db, repoPath } = options;

  const server = new McpServer({
    name: SERVER_NAME,
    version: SERVER_VERSION,
  });

  server.registerTool(
    "memory_search",
    {
      title: "Search OMA memory",
      description:
        "Search decisions, invariants, risks and past session transcripts recorded by earlier " +
        "sessions — including sessions run by a different agent. Use this before asking the user " +
        "why something is the way it is, and before re-deriving a project convention.",
      inputSchema: {
        query: z
          .string()
          .min(1)
          .describe("What you want to know, in natural language."),
        limit: z.number().int().min(1).max(50).optional(),
        include_transcripts: z
          .boolean()
          .optional()
          .describe(
            "Also search raw session transcripts, not just promoted memory. Default true.",
          ),
      },
    },
    async ({ query, limit, include_transcripts }) => {
      const hits = search(db, query, {
        limit: limit ?? 10,
        repo_path: repoPath,
        includeEvents: include_transcripts ?? true,
      });
      return {
        content: [{ type: "text", text: renderResults(query, hits) }],
      };
    },
  );

  return server;
}

export async function serveStdio(options: McpServerOptions): Promise<void> {
  const server = createMemoryServer(options);
  await server.connect(new StdioServerTransport());
}
