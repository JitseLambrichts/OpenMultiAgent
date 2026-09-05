#!/usr/bin/env bash
# Six-terminal tmux acceptance run for the macOS app.
#
# Creates a disposable OMA home with six sessions backed by stand-in tmux panes,
# compiles the sidecar, drives the app through SmokeUITests, and verifies from
# the outside that six tmux clients attach, typed text reaches a pane, closing
# a cell drops exactly one client, and quitting leaves every session alive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${OMA_SMOKE_HOME:-/tmp/oma-smoke}"
REPO="${OMA_SMOKE_REPO:-/tmp/oma-smoke-repo}"
SIDECAR="$HOME_DIR/oma-desktop-api"
SAMPLES="$HOME_DIR/clients.samples"

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }
command -v bun >/dev/null || { echo "bun is required" >&2; exit 1; }

echo "==> Preparing disposable OMA home at $HOME_DIR"
# Kill only the stand-in tmux sessions a previous smoke run left behind.
if [[ -f "$HOME_DIR/oma.db" ]]; then
  for id in $(sqlite3 "$HOME_DIR/oma.db" "SELECT id FROM session;" 2>/dev/null); do
    tmux kill-session -t "=oma-$id" 2>/dev/null || true
  done
fi
rm -rf "$HOME_DIR" "$REPO"
mkdir -p "$HOME_DIR" "$REPO"
(cd "$REPO" && git init -q -b main && git config user.email smoke@example.com && git config user.name Smoke \
  && echo '# smoke' > README.md && git add . && git commit -qm init)

echo "==> Compiling sidecar"
# bun build --compile stages a .{hash}.bun-build tempfile in cwd (oven-sh/bun#14020).
(cd "$HOME_DIR" && bun build --compile --target=bun-darwin-arm64 "$ROOT/packages/desktop-api/src/index.ts" --outfile "$SIDECAR" >/dev/null)
find "$HOME_DIR" "$ROOT" -maxdepth 1 -name '*.bun-build' -delete

echo "==> Seeding six sessions with stand-in tmux panes"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"system.hello","params":{}}' | OMA_HOME="$HOME_DIR" "$SIDECAR" >/dev/null
REAL_REPO="$(cd "$REPO" && pwd -P)"
SESSION_IDS=()
for title in "Smoke A" "Smoke 2" "Smoke 3" "Smoke 4" "Smoke 5" "Smoke 6"; do
  id="$(uuidgen | tr 'A-Z' 'a-z')"
  SESSION_IDS+=("$id")
  sqlite3 "$HOME_DIR/oma.db" "INSERT INTO session (id, repo_path, worktree_path, branch, title, status, started_at, ended_at)
    VALUES ('$id', '$REAL_REPO', '$REAL_REPO', 'main', '$title', 'active', '2026-09-04T17:00:00.000Z', NULL);"
  # A real shell stands in for the agent so typed commands produce output.
  tmux new-session -d -s "oma-$id" -c "$REPO" "printf '[smoke] stand-in agent pane for %s\\n' '$title'; exec /bin/sh -i"
done
sqlite3 "$HOME_DIR/oma.db" "INSERT OR IGNORE INTO project (id, repo_path, display_name, created_at, last_opened_at)
  VALUES ('$(uuidgen | tr 'A-Z' 'a-z')', '$REAL_REPO', 'oma-smoke-repo', '2026-09-04T17:00:00.000Z', '2026-09-04T17:00:00.000Z');"

count_clients() { tmux list-clients -F '#{session_name}' 2>/dev/null | grep -c '^oma-' || true; }

echo "==> Sampling tmux clients in the background"
: > "$SAMPLES"
( while true; do count_clients >> "$SAMPLES"; sleep 1; done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

echo "==> Driving the app through SmokeUITests"
(cd "$ROOT/apps/macos" && TEST_RUNNER_OMA_SMOKE_SIDECAR="$SIDECAR" TEST_RUNNER_OMA_SMOKE_HOME="$HOME_DIR" \
  xcodebuild test -project OpenMultiAgent.xcodeproj -scheme OpenMultiAgentUITests \
  -only-testing:OpenMultiAgentUITests/SmokeUITests -destination 'platform=macOS' 2>&1 \
  | grep -E 'Test Case.*(passed|failed|skipped)| error:|\*\* ' || true)
kill $SAMPLER 2>/dev/null || true
sleep 2

echo "==> Verifying from outside the app"
MAX_CLIENTS="$(sort -n "$SAMPLES" | tail -1)"
FINAL_CLIENTS="$(count_clients)"
ALIVE=0
for id in "${SESSION_IDS[@]}"; do tmux has-session -t "=oma-$id" 2>/dev/null && ALIVE=$((ALIVE + 1)); done
TYPED="no"
for id in "${SESSION_IDS[@]}"; do
  # capture-pane takes a pane target; the exact-match "=" prefix only applies to sessions.
  if tmux capture-pane -p -S -50 -t "oma-$id" 2>/dev/null | grep -q 'smoke-typing-ok'; then TYPED="yes"; fi
done
# A "5" only counts when it follows the last "6": that is the cell close, not the ramp-up.
SAW_FIVE="no"
LAST_SIX="$(grep -nx '6' "$SAMPLES" | tail -1 | cut -d: -f1 || true)"
if [[ -n "$LAST_SIX" ]] && tail -n +"$LAST_SIX" "$SAMPLES" | grep -qx '5'; then SAW_FIVE="yes"; fi

echo "max attached clients : $MAX_CLIENTS (expected 6)"
echo "saw five after close : $SAW_FIVE (expected yes)"
echo "typed text in a pane : $TYPED (expected yes)"
echo "sessions alive       : $ALIVE / ${#SESSION_IDS[@]} (expected all)"
echo "clients after quit   : $FINAL_CLIENTS (expected 0)"

[[ "$MAX_CLIENTS" == "6" && "$SAW_FIVE" == "yes" && "$TYPED" == "yes" && "$ALIVE" == "${#SESSION_IDS[@]}" && "$FINAL_CLIENTS" == "0" ]] \
  && echo "SMOKE PASSED" || { echo "SMOKE FAILED" >&2; exit 1; }

echo "==> Cleaning up stand-in tmux sessions"
for id in "${SESSION_IDS[@]}"; do tmux kill-session -t "=oma-$id" 2>/dev/null || true; done
