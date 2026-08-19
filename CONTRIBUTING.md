# Contributing to Brushot

Thanks for taking the time to improve Brushot. This guide keeps the project predictable for both maintainers and contributors.

---

## Code of Conduct

Be respectful, be specific, and assume good intent. Disagreement is welcome; personal attacks are not.

## Project Layout at a Glance

- `Sources/SnapInk/` — App entry, capture, OCR, watermark, pin library, shortcuts, overlay (single-file monolith; touch with care)
- `Sources/<OtherSwiftFiles>.swift` — Annotation, GIF, long capture, OCR, pin window, region capture, stream capture
- `Tests/` — XCTest suite covering core flows
- `Resources/` — `Info.plist`, `Brushot.entitlements`, `AppIcon.icns`, and one `*.lproj/InfoPlist.strings` per locale
- `scripts/` — `build-app.sh`, `build-dmg.sh`
- `README.md` and `README.<locale>.md` — translated documentation

## Prerequisites

- macOS 13 or later
- Xcode 15+ with the Command Line Tools (`xcode-select --install`)
- Swift 5.9 / Swift 6 toolchain (whichever your macOS toolchain ships)
- A configured Apple Development or Developer ID identity if you intend to sign the `.dkg/.app`

## Build, Test, and Run

This project uses Swift Package Manager for development. The current sandbox blocks SwiftPM's default driver, so always pass `--disable-sandbox` until upstream allows otherwise.

```bash
# Run the app from source
swift run --disable-sandbox Brushot

# Run the full test suite
swift test --disable-sandbox

# Build a signed .app bundle
./scripts/build-app.sh

# Build a notarization-ready .dmg
./scripts/build-dmg.sh
```

`build-app.sh` always uses the bundle identifier `com.brushot.app` and overwrites `/Applications/Brushot.app` on success. Test permissions via the packaged app, not `swift run`, because `swift run` does not carry the bundle's signing identity.

## Permissions

Three macOS privacy prompts are required during local development:

- **Screen & System Audio Recording** — required for any capture or recording.
- **Microphone** — required only if system audio / microphone recording is enabled.
- **Accessibility** — required for the modified-key pre-capture path that preserves tooltip rendering. Without it, Brushot still works but falls back to capture-on-shortcut.

Grant them once in **System Settings → Privacy & Security**, then relaunch `/Applications/Brushot.app`.

## Coding Style

- Swift 6 strict concurrency. All new types must be `Sendable` where they cross actor or queue boundaries.
- Prefer value semantics and `async`/`await` over completion handlers for new code; the legacy main.swift callbacks are frozen.
- Keep public surface area minimal. Internal helpers stay `internal`.
- Comments and identifiers in English. User-facing strings go through the `*.lproj/InfoPlist.strings` files — never hard-code UI text in code.

## Adding a New Locale

1. Add `Resources/<bcp47>.lproj/InfoPlist.strings` mirroring the existing ones.
2. Add a matching `README.<bcp47>.md` with the language switcher row at the top.
3. Update every existing `README.*.md` so the switcher row points to the new locale.
4. Add the locale to the section list at the bottom of this file.

Supported locales so far: `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`.

## Reporting Bugs

Open an issue with:

- Brushot version / commit SHA / DMG build date
- macOS version and architecture (Apple Silicon vs. Intel)
- Reproduction steps
- Expected vs. actual behaviour
- Console output (`Console.app` filtered by `Brushot`) when relevant
- A screenshot or short screen recording

## Proposing Features

Open an issue first. Discuss the user-facing impact (does it require a new permission prompt? a new window? does it affect existing shortcuts or output directories?) before writing code. Bigger features should be broken into reviewable PRs.

## Pull Requests

- One logical change per PR.
- Title in the imperative mood (`fix: pin library dedup race`, `feat: add OCR JP`).
- Body should reference the issue it closes and explain non-obvious trade-offs.
- Re-check the **PR template** checklist before requesting review.
- Squash-merge with the same prefix used in the title.

## Release Process

Maintainer-side: tag with `vX.Y.Z`, run `scripts/build-dmg.sh` on the tag, attach the signed DMG to the GitHub release, and copy the README's feature highlights into release notes.

---

## Supported Documentation Locales

- English — `README.md`
- 简体中文 — `README.zh-CN.md`
- 日本語 — `README.ja.md`
- 한국어 — `README.ko.md`
- 繁體中文 — `README.zh-TW.md`
