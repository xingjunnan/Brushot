#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/distribution/SnapInk.app"
DMG_PATH="$ROOT_DIR/dist/SnapInk.dmg"
LEGACY_APP_PATH="$ROOT_DIR/dist/SnapInk.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SnapInk-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build-app.sh"

# Older builds left a runnable copy in dist, which Spotlight could launch in
# place of /Applications/SnapInk.app and thereby mismatch TCC permissions.
rm -rf "$LEGACY_APP_PATH"

cp -R "$APP_PATH" "$STAGING_DIR/SnapInk.app"
cp "$ROOT_DIR/Resources/安装说明.txt" "$STAGING_DIR/安装说明.txt"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "SnapInk" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Built $DMG_PATH"
