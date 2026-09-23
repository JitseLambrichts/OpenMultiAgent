#!/usr/bin/env bash
# Builds the development macOS app bundle with the compiled sidecar embedded.
#
#   scripts/build-macos-app.sh            # Debug build, ad-hoc signed
#   CONFIGURATION=Release scripts/build-macos-app.sh
#
# Every resolved path is validated before anything is copied.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
BUILD_DIR="$APP_DIR/Build"
SIDECAR_ENTRY="$ROOT/packages/desktop-api/src/index.ts"
SIDECAR_BIN="$BUILD_DIR/oma-desktop-api"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED="$BUILD_DIR/DerivedData"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: '$1' is required but not on PATH" >&2
    exit 1
  fi
}

require bun
require xcodegen
require xcodebuild
require codesign

[[ -f "$SIDECAR_ENTRY" ]] || { echo "error: sidecar entry not found: $SIDECAR_ENTRY" >&2; exit 1; }
mkdir -p "$BUILD_DIR"

echo "==> Compiling sidecar (arm64)"
# bun build --compile stages a .{hash}.bun-build tempfile in cwd (oven-sh/bun#14020).
# Compile from Build/ so leftovers stay out of the repo root, then delete them.
(cd "$BUILD_DIR" && bun build --compile --target=bun-darwin-arm64 "$SIDECAR_ENTRY" --outfile "$SIDECAR_BIN")
find "$BUILD_DIR" "$ROOT" -maxdepth 1 -name '*.bun-build' -delete
[[ -x "$SIDECAR_BIN" ]] || { echo "error: sidecar binary was not produced" >&2; exit 1; }

echo "==> Generating Xcode project"
"$ROOT/scripts/generate-macos-project.sh" >/dev/null

echo "==> Building OpenMultiAgent ($CONFIGURATION)"
(cd "$APP_DIR" && xcodebuild build \
  -project OpenMultiAgent.xcodeproj \
  -scheme OpenMultiAgent \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  | grep -E 'error:|warning: .*Sources|\*\* ' || true)

APP_BUNDLE="$DERIVED/Build/Products/$CONFIGURATION/OpenMultiAgent.app"
[[ -d "$APP_BUNDLE" ]] || { echo "error: app bundle not found: $APP_BUNDLE" >&2; exit 1; }
RESOURCES="$APP_BUNDLE/Contents/Resources"
[[ -d "$RESOURCES" ]] || { echo "error: Resources directory missing in bundle" >&2; exit 1; }

echo "==> Embedding sidecar"
cp "$SIDECAR_BIN" "$RESOURCES/oma-desktop-api"
chmod +x "$RESOURCES/oma-desktop-api"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "==> Done: $APP_BUNDLE"
echo "    open \"$APP_BUNDLE\""
