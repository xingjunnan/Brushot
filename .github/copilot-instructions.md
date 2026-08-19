# Brushot — Copilot Repository Instructions

You are assisting with **Brushot**, a native macOS menu-bar screenshot app (capture, annotation, OCR, pinning, GIF/MP4 recording). Read these instructions before proposing changes.

## Project Facts

- Swift Package Manager project, **Swift 6 strict concurrency**. Every type crossing actor/queue boundaries must be `Sendable`.
- Entry point is `Sources/SnapInk/main.swift` — a deliberate ~2500-line monolith holding AppDelegate, CaptureController, PreCaptureStore, TooltipPreCaptureEventTap, hotkeys, preferences, overlay, and OCR orchestration. Do not propose splitting it unless asked.
- Other sources under `Sources/`: Annotation*, GIF*, LongCapture, OCR, Pinning, ScreenRegionCapturer, StreamScreenshotCapturer.
- Menu-bar-only app (`NSApplication.setActivationPolicy(.accessory)`), no Dock icon, no main window.

## Build Commands (critical)

The local sandbox blocks SwiftPM's default driver. **Always** add `--disable-sandbox`:

```bash
swift build --disable-sandbox
swift test --disable-sandbox
swift run --disable-sandbox Brushot
```

Packaging uses the Xcode toolchain directly (not `swift build`):

```bash
./scripts/build-app.sh   # signed .app, overwrites /Applications/Brushot.app
./scripts/build-dmg.sh   # arm64 + x86_64 universal DMG via xcrun swiftc + lipo
```

Signing identity resolution order: `BRUSHOT_CODESIGN_IDENTITY` env → identity already used by `/Applications/Brushot.app` → Developer ID Application → first Apple Development identity.

## Architecture — Capture Chain

Hotkey → pre-capture → overlay presents frozen screen → user selects region → `cropFromPreCaptured` crops (or falls back to live capture).

Key mechanisms:

- **Hotkeys**: Carbon `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget(), ...)`. `KeyboardShortcut.modifiers` is a UInt32 bitmask of Carbon constants (`cmdKey | shiftKey | optionKey | controlKey`). Do not suggest NSEvent global monitors for the primary path.
- **PreCaptureStore**: thread-safe pre-capture cache. `capture()` fills it by capturing all displays synchronously via `CGWindowListCreateImage`; `retrieve()` consumes and clears. Selection then crops from the frozen frame instead of re-capturing.
- **TooltipPreCaptureEventTap**: a `CGEventTap` (`.cgSessionEventTap`) that intercepts `flagsChanged` *before* AppKit dispatch and pre-captures on modifier-key rising edges, so tooltips survive in screenshots. The Carbon handler is a fallback used only when the tap is inactive.

## Swift 6 / API Pitfalls (known traps)

- `kAXTrustedCheckOptionPrompt` is a non-Sendable C global — access it via the string literal `"AXTrustedCheckOptionPrompt"` instead.
- CGEventTap C API must go through the Swift overlay: `CGEvent.tapCreate / tapEnable / tapIsEnabled`, not the raw C symbols.
- Carbon handler callbacks must not touch AppKit on the callback thread; hop to main.

## Permissions (do not conflate)

- **Screen recording** — required for any capture. Preflight: `CGPreflightScreenCaptureAccess` + `SCShareableContent`.
- **Accessibility** — required only for the tooltip pre-capture CGEventTap. Check: `AXIsProcessTrusted`. Without it the app still works (degraded path).
- **Microphone / system audio** — recording only.
- Permission testing must run `/Applications/Brushot.app`, not `swift run` (CLI builds lack the bundle's signing identity, so TCC prompts misbehave).

## Conventions

- UI strings live in `Resources/<locale>.lproj/InfoPlist.strings` (`en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`). Never hard-code user-facing text in code.
- The README family (`README.md`, `README.zh-CN.md`, `README.zh-TW.md`, `README.ja.md`, `README.ko.md`) is kept structure-aligned at ~115 lines. Content changes must be mirrored across all five.
- Commit prefixes: `feat:`, `fix:`, `refactor:`, `docs:` (see `git log`).
- Output files go to `~/Downloads` by default; watermarks support `{date}`, `{time}`, `{datetime}` placeholders and are burned into recording pixels at export time.
- OCR always reads the frozen original frame — annotations are ignored by design. Keep it that way.

## When Proposing Changes

- Prefer minimal diffs inside the existing monolith; match surrounding style, not textbook refactors.
- For recording changes, respect the existing limits: GIF auto-stops at 3 min, video at 2 h, recording blocked under 1 GB free disk.
- Anything that changes the hotkey/permission/capture chain should mention which of the three TCC prompts it affects.
