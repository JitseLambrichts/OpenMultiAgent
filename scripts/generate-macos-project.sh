#!/usr/bin/env bash
# Regenerates the Xcode project and marks Icon Composer bundles so actool compiles them.
#
# XcodeGen 2.46 writes lastKnownFileType = wrapper.icon. Xcode 26's asset catalog
# compiler only accepts folder.iconcomposer.icon, so an unpatched project copies
# the .icon package as a loose resource and the Dock keeps the generic icon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
PBXPROJ="$APP_DIR/OpenMultiAgent.xcodeproj/project.pbxproj"

(cd "$APP_DIR" && xcodegen generate "$@")

perl -pi -e 's/lastKnownFileType = wrapper\.icon;/lastKnownFileType = folder.iconcomposer.icon;/g' "$PBXPROJ"
