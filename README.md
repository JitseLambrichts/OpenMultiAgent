# OpenMultiAgent

<p align="center">
  <strong>A local-first command center for AI coding agents.</strong><br>
  Memory that outlives any one agent, session, or vendor.
</p>

<p align="center">
  <a href="https://open-multi-agent-website.vercel.app/"><strong>Website</strong></a> ·
  <a href="https://open-multi-agent-website.vercel.app/#install">Install</a> 
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat-square">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-111111?style=flat-square">
  <a href="https://github.com/JitseLambrichts/OpenMultiAgent/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/JitseLambrichts/OpenMultiAgent/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-A8E063?style=flat-square">
</p>

<p align="center">
  <img width="1672" height="941" alt="OpenMultiAgent projects dashboard" src="https://github.com/user-attachments/assets/9ad6e3f4-899d-45e6-954b-a777e3cdd2aa">
</p>

OpenMultiAgent (OMA) is a vendor-neutral environment for running AI coding agents on your Mac. Durable state lives in SQLite. Structured transcripts are ingested locally. Relevant knowledge is served back through MCP, so a switch from Claude Code to Codex or Gemini does not wipe the work you already did.

## Features

- **Persistent sessions**: tmux-backed terminals that survive closing a window or quitting the app
- **Agent switching**: hand off a task with a brief of decisions, diffs, and open work
- **Shared memory**: full-text search plus an MCP memory server agents can query
- **Living docs**: extract knowledge, review the Markdown, then promote it into the repo
- **Vendor adapters**: Claude Code, Codex, and Gemini, already signed in on your machine
- **Optional worktrees**: isolate a session without leaving the project

OMA stores no API keys of its own. Transcripts and memory stay on disk unless you explicitly extract knowledge through an agent CLI.

## Install

On Apple Silicon with macOS 15+:

```sh
curl -fsSL https://raw.githubusercontent.com/JitseLambrichts/OpenMultiAgent/main/scripts/install-macos.sh | bash
```

The script downloads the latest prebuilt app from [GitHub Releases](https://github.com/JitseLambrichts/OpenMultiAgent/releases), checks its SHA-256, and installs it into `/Applications`. It installs Git and tmux with Homebrew when they are missing. No Xcode is needed.

The app is ad-hoc signed, not notarized. Installing through the script avoids a Gatekeeper prompt. If you download the zip in a browser instead, macOS blocks the first launch; allow it under **System Settings → Privacy & Security → Open Anyway**.

To build from source instead, which needs Xcode 26, Bun, and XcodeGen:

```sh
curl -fsSL https://raw.githubusercontent.com/JitseLambrichts/OpenMultiAgent/main/scripts/install-macos.sh | OMA_BUILD_FROM_SOURCE=1 bash
```

Set `OMA_VERSION=v0.1.0` to install a specific release. See [`scripts/install-macos.sh`](scripts/install-macos.sh) for the full install path.

## Requirements

| Needed to run | Needed to build the Mac app |
| --- | --- |
| macOS 15+ on Apple Silicon | **Xcode 26** |
| Git and tmux | [Bun](https://bun.sh) 1.2+ |
| At least one signed-in agent CLI (`claude`, `codex`, or `gemini`) | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

```sh
brew install bun git tmux xcodegen
```

## Releases

Pushing a tag such as `v0.1.0` runs [`release.yml`](.github/workflows/release.yml), which builds the Release app on a macOS runner, checks that the embedded sidecar answers as both the app API and the MCP memory server, and publishes `OpenMultiAgent-macos-arm64.zip` with its checksum.

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Development

```sh
git clone https://github.com/JitseLambrichts/OpenMultiAgent.git
cd OpenMultiAgent
bun install
bun run check
bun run macos:build
open apps/macos/Build/DerivedData/Build/Products/Debug/OpenMultiAgent.app
```

On first launch macOS may ask for access to the folder that contains this checkout. Grant it, or the sidecar cannot start.

The database defaults to `~/.oma/oma.db`. Set `OMA_HOME` to redirect all OMA state, which is useful for tests and disposable environments.

| Command | What it does |
| --- | --- |
| `bun run macos:generate` | Regenerate `apps/macos/OpenMultiAgent.xcodeproj` |
| `bun run macos:test` | Swift unit and contract tests |
| `bun run macos:build` | Compile the sidecar and produce a signed dev `.app` |
| `bun run macos:smoke` | Six-terminal acceptance run against real tmux |

## How continuity works

OMA promises continuity of **knowledge**, not a literal copy of an agent's private context window.

A switch ingests the current transcript, summarizes the task, decisions, changed files, diff, and open work into a handoff brief, then starts the next agent in the same worktree with that brief and MCP access to shared memory. The original and replacement runs stay linked to one OMA session.

**Extract Knowledge** sends normalized events (not raw terminal ANSI) to a supported headless agent. Proposed decisions, invariants, risks, ownership notes, and how-tos stay pending in SQLite. **Promote Knowledge** shows the Markdown diff without writing. Only applying that preview records the memory and renders `.oma/docs/*.md` in the repository. A correction links to and supersedes the old record rather than erasing history.

Ending a session stops and records it locally, and tries to extract knowledge. If the model is unavailable, the session still ends. Use **Extract Knowledge** in the session workspace to retry.

## Desktop app

`apps/macos` is a native SwiftUI app. It never opens `oma.db` directly. It talks JSON-RPC 2.0 over stdin/stdout to the `@oma/desktop-api` sidecar and embeds tmux through SwiftTerm using an executable plus argument array, never a shell string.

During development the app launches the sidecar with `bun run` from this checkout. `scripts/build-macos-app.sh` compiles the sidecar with `bun build --compile` and embeds it at `Contents/Resources/oma-desktop-api`. Set `OMA_DESKTOP_SIDECAR` (and the `\u{1F}`-separated `OMA_DESKTOP_SIDECAR_ARGS`) to point the app at another sidecar.

The project cockpit includes a **Code** tab: a file tree of the checkout or session worktree, a native text editor, and the tmux terminal. Click a changed file to preview the diff, then **Open in editor** to jump to that path.

| Shortcut | Action |
| --- | --- |
| ⌘N | New session |
| ⌘O | Add project |
| ⌘F | Search memory |
| ⌘S | Save the open editor file |
| ⌥⌘I | Inspector |
| ⌃1–⌃4 | Terminal layouts |

Closing a terminal cell or the app never ends a tmux session. **End Session** is an explicit, confirmed action.

`bun run macos:smoke` seeds a disposable OMA home with six sessions, drives the app through `SmokeUITests`, and verifies from outside the app that six tmux clients attach, typed input reaches a pane, closing a cell drops exactly one client, and quitting leaves every session alive. The UI tests bundle a fixture sidecar and copy nothing from user folders.

## Privacy

Transcripts and memory stay local. Explicit extraction (**Extract Knowledge**) sends normalized session text to the selected agent CLI, which may use a remote model. OMA does not edit an agent's global MCP configuration; it injects a session-scoped configuration into the launched process.

## AI disclaimer

This project, including its code, documentation, and website, was built entirely with the help of AI coding agents.

## License

[MIT](LICENSE)
