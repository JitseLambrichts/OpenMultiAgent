# OpenMultiAgent architecture

## Design goal

OMA separates durable knowledge from the CLI agent that happened to produce
it. Sessions, agent runs, normalized transcript events and curated memory are
owned by one local daemon/store boundary. User interfaces and agents are
clients of that boundary.

```text
macOS desktop app / agents through MCP
                    |
            local OMA API boundary
                    |
   +----------------+----------------+
   | session manager | memory + docs |
   | tmux + worktree | SQLite + FTS5 |
   | agent adapters  | transcript IO |
   +----------------+----------------+
                    |
      ~/.oma/oma.db and <repo>/.oma/docs
```

## Layers

### Core

`@oma/core` owns the schema, migrations, session lifecycle, tmux and Git
integration. An OMA `session` spans multiple `agent_run` rows. This is the
boundary that makes a vendor switch possible without pretending two agents
share an internal context window.

### Adapters

`@oma/adapters` translates the common launch interface into each CLI's flags
and transcript-discovery rules. Claude accepts a caller-supplied session UUID;
Gemini also accepts a pinned UUID and is discovered from its chat metadata;
Codex is correlated by a new rollout's `session_meta.cwd`. Per-adapter
`resolveTranscript` keeps these incompatible rules out of core.

### Ingest

`@oma/ingest` parses the structured JSONL written by each agent and normalizes
it into a small event vocabulary. Unknown records remain in `raw_json` and do
not crash ingestion. Stable `(agent_run_id, seq)` identity makes repeated
ingestion of growing files safe.

### Memory and MCP

SQLite is the source of truth. FTS5 indexes promoted memory and transcript
text; curated memory ranks before raw events and may be repository-scoped or
global. `@oma/mcp` exposes read-only search without dumping the entire store
into an initial prompt. Persistent writes stay behind the desktop app's review
boundary so transcript prompt injection cannot mutate durable memory.

### Living documentation

Completed sessions are converted into schema-validated candidate memories by
a headless adapter. Promotion remains a user-reviewed operation: accepted
records are stored with provenance and rendered as versioned Markdown under
`.oma/docs/`. Contradictions supersede old memory rather than erasing history.

In the desktop app, **Extract Knowledge** produces pending candidates and
**Promote Knowledge** shows a Markdown preview. Only applying that preview
writes memory and renders `.oma/docs/`. Keeping extraction separate also makes
retries safe when an agent is temporarily unavailable.

## Operational invariants

- tmux names always start with `oma-`; foreign sessions are never adopted.
- The main checkout is never removed; only explicitly created worktrees may be
  cleaned up.
- The daemon/database is the sole owner of state. A UI is always a client.
- Transcript parsers are tolerant at their input boundary and strict in their
  normalized output.
- Repository-scoped memory never leaks into another repository.
- LLM extraction never writes documentation without a reviewable promotion.

## Milestone boundaries

- M0: workspace, tests, lint and architecture records.
- M1: end-to-end shared memory across Claude Code and Codex.
- M2: deeper orchestration, switch/resume and Gemini adapter.
- M3: reviewed extraction and living Markdown docs.
- M4: desktop client, chosen only after terminal-grid measurements.
- M5: optional catalog/workspace features for demonstrated team needs.
- M6: stabilize the plugin API and package releases after dogfooding.
