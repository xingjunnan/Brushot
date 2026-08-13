#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/distribution/Brushot.app"
DMG_PATH="$ROOT_DIR/dist/Brushot.dmg"
LEGACY_APP_PATH="$ROOT_DIR/dist/Brushot.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/Brushot-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build-app.sh"

# Older builds left a runnable copy in dist, which Spotlight could launch in
# place of /Applications/Brushot.app and thereby mismatch TCC permissions.
rm -rf "$LEGACY_APP_PATH"

cp -R "$APP_PATH" "$STAGING_DIR/Brushot.app"
cp "$ROOT_DIR/Resources/安装说明.txt" "$STAGING_DIR/安装说明.txt"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Brushot" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Built $DMG_PATH"
