#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/app-release"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
APP_DIR="$ROOT_DIR/.build/distribution/Brushot.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
APP_RESOURCES_DIR="$CONTENTS_DIR/Resources"
RESOURCES_DIR="$ROOT_DIR/Resources"
ENTITLEMENTS_PATH="$RESOURCES_DIR/Brushot.entitlements"
SOURCE_DIR="$ROOT_DIR/Sources/Brushot"
SOURCE_FILES=("$SOURCE_DIR"/*.swift)
ARCHS=(arm64 x86_64)

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$APP_RESOURCES_DIR" "$BUILD_DIR" "$MODULE_CACHE_DIR"

ARCH_BINARIES=()
for ARCH in "${ARCHS[@]}"; do
    ARCH_MODULE_CACHE_DIR="$MODULE_CACHE_DIR/$ARCH"
    ARCH_BINARY="$BUILD_DIR/Brushot-$ARCH"
    mkdir -p "$ARCH_MODULE_CACHE_DIR"
    xcrun swiftc \
        -O \
        -swift-version 6 \
        -target "${ARCH}-apple-macosx13.0" \
        -module-cache-path "$ARCH_MODULE_CACHE_DIR" \
        -framework AppKit \
        -framework AVFoundation \
        -framework Carbon \
        -framework CoreGraphics \
        -framework CoreImage \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework ImageIO \
        -framework QuartzCore \
        -framework ScreenCaptureKit \
        -framework SwiftUI \
        -framework Translation \
        -framework Vision \
        "${SOURCE_FILES[@]}" \
        -o "$ARCH_BINARY"
    ARCH_BINARIES+=("$ARCH_BINARY")
done
lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/Brushot"

cp "$RESOURCES_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$RESOURCES_DIR/AppIcon.icns" "$APP_RESOURCES_DIR/AppIcon.icns"
find "$RESOURCES_DIR" -name '*.lproj' -type d -maxdepth 1 -exec cp -R {} "$APP_RESOURCES_DIR/" \;

# Sign after every bundle resource has been copied so Info.plist and resources
# are sealed as part of the app. Prefer an explicitly configured identity, then
# a Developer ID Application identity when available, then the first Apple
# Development identity in the user's keychain.
EXPLICIT_CODE_SIGN_IDENTITY=false
if [[ -n "${BRUSHOT_CODESIGN_IDENTITY:-}" ]]; then
    CODE_SIGN_IDENTITY="$BRUSHOT_CODESIGN_IDENTITY"
    EXPLICIT_CODE_SIGN_IDENTITY=true
else
    CODE_SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '
                /"Developer ID Application:/ { print $2; found=1; exit }
                /"Apple Development:/ && fallback == "" { fallback=$2 }
                END { if (!found && fallback != "") print fallback }
            '
    )" || CODE_SIGN_IDENTITY=""
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
fi
CODESIGN_ARGS=(
    --force
    --deep
    --entitlements "$ENTITLEMENTS_PATH"
    --options runtime
    --identifier "com.brushot.app"
    --sign "$CODE_SIGN_IDENTITY"
)
# Secure timestamps are required for distributable Developer ID builds, but
# Apple Development and ad-hoc signatures should not depend on Apple's remote
# timestamp service. This keeps local builds stable when that service is down.
if [[ "$CODE_SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    CODESIGN_ARGS+=(--timestamp)
fi
codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"

# A certificate can remain in the keychain after it expires or loses trust.
# codesign can still produce a CMS signature with it, but macOS then rejects
# the app identity and privacy permissions become unreliable. For automatic
# identity selection, prefer a valid ad-hoc signature over an invalid
# certificate-backed signature. An explicitly requested identity remains a
# hard failure so release signing mistakes are never hidden.
if ! codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
    if [[ "$EXPLICIT_CODE_SIGN_IDENTITY" == true ]]; then
        echo "Error: the explicitly selected code-signing identity did not produce a valid signature." >&2
        exit 1
    fi
    echo "Warning: the automatically selected signing identity is not trusted; falling back to ad-hoc signing." >&2
    CODE_SIGN_IDENTITY="-"
    codesign \
        --force \
        --deep \
        --entitlements "$ENTITLEMENTS_PATH" \
        --options runtime \
        --identifier "com.brushot.app" \
        --sign "$CODE_SIGN_IDENTITY" \
        "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
fi

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    echo "Warning: using an ad-hoc signature; privacy permissions may reset after rebuilding."
    echo "Install an Apple Development certificate or set BRUSHOT_CODESIGN_IDENTITY."
fi

echo "Built $APP_DIR"
