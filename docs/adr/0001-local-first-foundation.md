# ADR 0001: Local-first vertical slice

- Status: accepted
- Date: 2026-08-11

## Context

The original product vision contains session orchestration, shared memory,
living documentation, a catalog, workspaces and a desktop UI. Building each as
a horizontal layer would postpone validation of the central claim: knowledge
created by one agent must be retrievable by another in a later session.

## Decision

Build a thin vertical slice first with these binding choices:

1. Bun and TypeScript for the core, because the MCP SDK and SQLite FTS5 are
   available without a service dependency.
2. tmux as the persistent terminal substrate and Git worktrees as optional
   isolation.
3. Structured on-disk transcripts as the ingest source; do not scrape ANSI
   terminal output.
4. SQLite FTS5 before embeddings. Add semantic indexing only when measured
   recall demonstrates a gap.
5. Claude Code and Codex in M1, Gemini in M2, behind one adapter interface.
6. The desktop technology decision is deferred to M4 and the API remains
   client-neutral.
7. Generated documentation requires explicit promotion until extraction
   quality is proven.

## Consequences

The first usable release is offline and inexpensive, works for sessions that
were started outside OMA, and makes format drift testable with transcript
fixtures. Semantic similarity, remote collaboration and polished UI are
deliberately absent from the first proof.
