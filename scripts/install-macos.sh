#!/usr/bin/env bash
# Clones OpenMultiAgent, builds the Release app, and copies it to /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/jlambrichtsopt/OpenMultiAgent/master/scripts/install-macos.sh | bash
#
# Requires macOS 15 or newer on Apple Silicon, Xcode 26, and Homebrew.
# Bun, XcodeGen, Git and tmux are installed with Homebrew when missing.
# Override the checkout or destination with OMA_SRC and OMA_DEST.
set -euo pipefail

REPO_URL="${OMA_REPO:-https://github.com/jlambrichtsopt/OpenMultiAgent.git}"
SRC_DIR="${OMA_SRC:-$HOME/.oma/src/OpenMultiAgent}"
DEST_DIR="${OMA_DEST:-/Applications}"
APP_NAME="OpenMultiAgent.app"
CONFIGURATION="${CONFIGURATION:-Release}"

export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.bun/bin:${PATH}"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "OpenMultiAgent's desktop app runs on macOS."
  [[ "$(uname -m)" == "arm64" ]] || die "This build is Apple Silicon (arm64) only."
  local version major
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  [[ "$major" -ge 15 ]] || die "macOS 15 or newer is required (found $version)."
}

require_xcode() {
  local devdir version major
  devdir="$(xcode-select -p 2>/dev/null || true)"
  [[ -n "$devdir" ]] || die "Xcode 26 is required. Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
  [[ "$devdir" != *CommandLineTools ]] || die "Full Xcode is required, not only the Command Line Tools. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
  version="$(xcodebuild -version 2>/dev/null | awk 'NR==1 { print $2 }' || true)"
  [[ -n "$version" ]] || die "xcodebuild failed. Open Xcode once and accept the license: sudo xcodebuild -license"
  major="${version%%.*}"
  [[ "$major" -ge 26 ]] || die "Xcode 26 or newer is required (found $version)."
}

ensure_formula() {
  local cmd="$1"
  local formula="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  command -v brew >/dev/null 2>&1 || die "'$cmd' is not installed, and Homebrew was not found. Install Homebrew from https://brew.sh and run this command again."
  log "Installing $formula"
  brew install "$formula"
  hash -r
  command -v "$cmd" >/dev/null 2>&1 || die "Homebrew installed $formula, but '$cmd' is still not on PATH."
}

require_bun_version() {
  local version major minor
  version="$(bun --version)"
  major="$(printf '%s' "$version" | cut -d. -f1)"
  minor="$(printf '%s' "$version" | cut -d. -f2)"
  if [[ "$major" -lt 1 ]] || [[ "$major" -eq 1 && "$minor" -lt 2 ]]; then
    die "Bun 1.2 or newer is required (found $version)."
  fi
}

sync_source() {
  mkdir -p "$(dirname "$SRC_DIR")"
  if [[ -d "$SRC_DIR/.git" ]]; then
    if [[ -n "$(git -C "$SRC_DIR" status --porcelain)" ]]; then
      die "$SRC_DIR has local changes. Move it aside, or set OMA_SRC to another directory."
    fi
    log "Updating $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin HEAD
    git -C "$SRC_DIR" reset --hard FETCH_HEAD
  elif [[ -e "$SRC_DIR" ]]; then
    die "$SRC_DIR exists but is not a git checkout. Remove it and run this command again."
  else
    log "Cloning $REPO_URL"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
  fi
  log "Source $(git -C "$SRC_DIR" rev-parse --short HEAD)"
}

quit_running_app() {
  if ! pgrep -xq OpenMultiAgent; then
    return 0
  fi
  log "Quitting OpenMultiAgent"
  osascript -e 'tell application "OpenMultiAgent" to quit' || true
  local _attempt
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xq OpenMultiAgent || return 0
    sleep 0.5
  done
  die "OpenMultiAgent is still running. Quit it and run this command again."
}

install_app() {
  local built="$1"
  local target="$DEST_DIR/$APP_NAME"
  [[ -d "$built" ]] || die "Build did not produce $built"

  quit_running_app
  if [[ -w "$DEST_DIR" ]] && { [[ ! -e "$target" ]] || [[ -w "$target" ]]; }; then
    log "Installing $target"
    rm -rf "$target"
    ditto "$built" "$target"
    xattr -cr "$target"
    codesign --force --deep --sign - "$target" >/dev/null
  else
    log "Administrator permission is required to install into $DEST_DIR"
    sudo mkdir -p "$DEST_DIR"
    sudo rm -rf "$target"
    sudo ditto "$built" "$target"
    sudo xattr -cr "$target"
    sudo codesign --force --deep --sign - "$target" >/dev/null
    sudo chown -R "$(id -un):admin" "$target"
  fi

  [[ -d "$target" ]] || die "Install failed: $target was not created."
  [[ -x "$target/Contents/Resources/oma-desktop-api" ]] || die "The installed app is missing its sidecar."
  log "Installed $target"
  log "Open OpenMultiAgent from Applications. Git, tmux, and a signed-in agent CLI (claude, codex, or gemini) are required to run sessions."
}

main() {
  require_macos
  require_xcode
  ensure_formula git git
  ensure_formula bun bun
  ensure_formula xcodegen xcodegen
  ensure_formula tmux tmux
  require_bun_version
  command -v codesign >/dev/null 2>&1 || die "codesign is required."

  sync_source
  log "Installing dependencies"
  (cd "$SRC_DIR" && bun install)
  log "Building $APP_NAME ($CONFIGURATION). The first build can take several minutes."
  (cd "$SRC_DIR" && CONFIGURATION="$CONFIGURATION" bun run macos:build)
  install_app "$SRC_DIR/apps/macos/Build/DerivedData/Build/Products/$CONFIGURATION/$APP_NAME"
}

main "$@"
