# OpenMultiAgent

OpenMultiAgent (OMA) is a local-first, vendor-neutral environment for running
AI coding agents with memory that outlives any one agent or session. It keeps
the durable state in SQLite, reads the agents' own structured transcripts and
offers relevant knowledge back through MCP.

OMA currently delivers the command-line vertical slice: persistent tmux
sessions, optional Git worktrees, Claude Code, Codex and Gemini adapters,
agent switching/resume, transcript ingestion, full-text memory search, an MCP
memory server, and reviewed living-document promotion.

## Requirements

- Bun 1.2 or newer
- Git and tmux
- At least one supported agent CLI (`claude`, `codex`, or `gemini`)

## Setup

```sh
bun install
bun run check
```

Use `bun run oma -- ...` from a checkout, or link the package so `oma` is on
your `PATH`.

```sh
bun run oma -- new /path/to/repo --agent claude --worktree
bun run oma -- ls
bun run oma -- watch                         # live TUI overview
bun run oma -- attach <session-id>
bun run oma -- status <session-id>
bun run oma -- sync <session-id>
bun run oma -- search "why do we use Redis Streams?" --repo /path/to/repo
bun run oma -- switch <session-id> --agent codex
bun run oma -- end <session-id>             # local sync + stop
bun run oma -- end <session-id> --extract   # optionally extract candidates
bun run oma -- resume <session-id>
bun run oma -- fork <session-id>
bun run oma -- extract <session-id>
bun run oma -- promote <session-id>        # preview only
bun run oma -- promote <session-id> --apply
```

The database defaults to `~/.oma/oma.db`. Set `OMA_HOME` to redirect all OMA
state, which is useful for tests and disposable environments.

## What an agent switch preserves

OMA promises continuity of knowledge, not a literal transfer of an agent's
private context window. A switch ingests the current transcript, summarizes
the task, decisions, changed files, diff and open work into a handoff brief,
then starts the next agent in the same worktree with that brief and MCP access
to the shared memory. The original and replacement runs remain linked to one
OMA session.

## Living documentation workflow

`oma extract` sends normalized events—not raw terminal ANSI—to a supported
headless agent with a strict candidate schema. The resulting decisions,
invariants, risks, ownership notes and how-tos remain pending in SQLite.
`oma promote` prints the proposed Markdown diff without writing. Only the
explicit `--apply` form records the memory and renders `.oma/docs/*.md` in the
repository. A correction links to and supersedes the old record rather than
erasing its history.

`oma end` only stops and records the session locally. Knowledge extraction is
an explicit model call: run `oma extract <id>`, or opt in while ending with
`oma end <id> --extract`. If the model is unavailable, the session still ends
and extraction can safely be retried.

## macOS desktop app (M4)

`apps/macos` contains the native SwiftUI app, the **Calm Command Center**. It
never opens `oma.db`; it talks JSON-RPC 2.0 over stdin/stdout to the
`@oma/desktop-api` sidecar and embeds tmux terminals through SwiftTerm using an
executable plus argument array, never a shell string.

Requirements: macOS 15 or newer, Xcode 26, [XcodeGen](https://github.com/yonaslab/XcodeGen)
(`brew install xcodegen`), and Bun on `PATH`.

```sh
bun run macos:generate   # regenerate apps/macos/OpenMultiAgent.xcodeproj
bun run macos:test       # Swift unit and contract tests
bun run macos:build      # compile the sidecar and produce a signed dev .app
bun run macos:smoke      # six-terminal acceptance run against real tmux
```

During development the app launches the sidecar with `bun run` from this
checkout. `scripts/build-macos-app.sh` compiles the sidecar with
`bun build --compile` and embeds it in the bundle under
`Contents/Resources/oma-desktop-api`. Set `OMA_DESKTOP_SIDECAR` (and the
`\u{1F}`-separated `OMA_DESKTOP_SIDECAR_ARGS`) to point the app at another
sidecar, which is how the UI tests use `apps/macos/UITests/FixtureSidecar`.

`bun run macos:smoke` seeds a disposable OMA home with six sessions backed by
stand-in tmux panes, drives the app through `SmokeUITests`, and verifies from
outside the app that six tmux clients attach, typed input reaches a pane,
closing a cell drops exactly one client, and quitting leaves every session
alive. The UI tests bundle a fixture sidecar and copy nothing from user
folders: processes started by the test runner have no access to Desktop or
Documents and would block on a permission prompt.

On first launch macOS may ask for access to the folder that contains this
checkout (for example Desktop or Documents); the sidecar cannot start until
that is granted.

Keyboard: ⌘N new session, ⌘O add project, ⌘F search memory, ⌥⌘I inspector,
⌃1–⌃4 terminal layouts. Closing a terminal cell or the app never ends a tmux
session; **End Session** is an explicit, confirmed action.

## Architecture and roadmap

The architecture is described in [docs/architecture.md](docs/architecture.md).
The implementation is deliberately staged: the CLI vertical slice proves the
memory loop before a desktop UI or organization-scale catalog is added. M5's
catalog/workspace layer remains optional until daily use demonstrates a need.

## Privacy

Transcripts and memory stay local. Explicit extraction (`oma extract` or
`oma end --extract`) sends normalized session text to the selected agent CLI,
which may use a remote model. OMA does not edit an agent's global MCP
configuration; it injects a session-scoped configuration into the launched
process.

## License

MIT
