**[English]** | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [繁體中文](README.zh-TW.md)

---

# Brushot

Brushot is a lightweight native macOS screenshot app for fast capture, annotation, OCR, pinning, and screen recording. The current build includes the complete capture and inline annotation loop:

It supports macOS 13 or later on both Apple Silicon and Intel Macs through a Universal 2 executable.

- menu bar app
- configurable global shortcuts for area, full-screen, delayed, and scrolling capture, recording, clipboard pinning, the pin library, and hiding/showing pins
- drag-to-select capture overlay
- smart detection of the topmost window under the pointer: click to select the window, or drag to draw a free-form region
- single-display full-screen capture with automatic mouse-display targeting
- 1–60 second delayed area capture with an optional countdown sound
- selection action bar with cancel, local OCR, copy, and save actions
- inline annotation tools for rectangle, ellipse, line, arrow, pen, text, numbered steps with optional descriptions, mosaic, and spotlight highlight
- editable annotation objects with move, resize, restyle, delete, undo, redo, and context-sensitive drawing/move/resize cursors
- per-tool color, opacity, width, line, fill, arrow, text, mosaic, and highlight styles
- per-tool style persistence across launches
- PNG output to Downloads
- optional text and Logo watermarks for screenshots and recordings, configured from the menu bar with `{date}`, `{time}`, `{datetime}` placeholders
- screenshot and clipboard image pinning in always-on-top desktop windows
- persistent pin library with SHA-256 content deduplication and up to 100 recent images
- pin opacity, corner radius, current/all-desktop behavior, pixel-level arrow-key movement, and hide/show all
- right-click or double-click secondary annotation for pinned images
- on-device Chinese and English text recognition using macOS Vision, with editable result preview
- on-device English-to-Simplified-Chinese translation on macOS 15 or later using Apple Translation
- unified MP4 video and adaptive GIF recording with a 3–2–1 countdown, system audio, microphone, camera picture-in-picture, pause/resume, and live annotations
- recording preview with save, clipboard copy, and discard actions
- screen, system audio, and microphone recording permission prompts

## Capture Workflow

1. Press the configured shortcut or choose `Capture Region` from the menu bar.
2. Drag to select an area.
3. Move the selection or drag any edge/corner handle to resize it, then choose an annotation tool to freeze the selected image and enter editing mode.
4. Add and edit annotations, then recognize the original image text, copy the flattened result to the clipboard, or save it to Downloads. Newly created annotations remain selected and can be moved or resized without switching away from the active drawing tool.

The `text.viewfinder` button runs OCR entirely on the Mac and opens an editable result window. On macOS 15 or later, the compact side-by-side result window can translate the currently edited English text into Simplified Chinese using Apple's on-device Translation framework; use the menu bar's `Enable OCR English to Chinese` check item to turn this feature on or off. On macOS 13 and 14 the menu shows a disabled compatibility note instead. macOS may ask to download the language models on first use. Copying either the original or translated text writes plain text to the clipboard. In annotation mode OCR always reads the frozen original screenshot, so arrows, text, mosaic, and other annotations are ignored.

Use `Command + C` or `Command + S` while the selection is active for the copy and save actions. Global shortcuts can be changed in `Preferences...` from the menu bar.

Choose `Full Screen Capture` or press `Control + Option + F` to freeze the display under the mouse and preselect its entire area. The normal Brushot action and annotation controls remain available, so the selection can still be adjusted before output.

Choose `Delayed Capture...` or press `Control + Option + D` to select an area first, then start the countdown. Brushot restores the live desktop during the countdown and captures the current pixels when time expires; its border and countdown HUD are hidden before capture. The delay defaults to 5 seconds and can be set from 1 to 60 seconds in Preferences, together with the countdown sound option.

Watermarks can be configured from the menu bar via `Watermark Settings...`, below `Preferences...`. Brushot supports text, Logo images, or both together, plus position, opacity, size, margin, and text color. Screenshot and recording watermarks can be enabled independently while sharing the same visual style. Recording watermarks are burned into video/GIF pixels using the recording start time for `{date}`, `{time}`, and `{datetime}`. OCR reads the original image.

Annotation tool shortcuts are `V/R/O/L/A/P/T/N/M/H`. Use `Command + Z` and `Shift + Command + Z` for undo and redo, and Delete to remove the selected annotation. While editing text, `Command + Return` commits and Escape cancels the text edit.

Double-click an empty part of the annotated screenshot or any non-text annotation to copy the flattened PNG. Double-click text to edit it. While a drawing tool is active, existing annotations take pointer priority; hold Option while dragging to force creation of a new overlapping annotation. Color, opacity, width, and other style choices are applied immediately but are not added to the undo history.

Sequence annotations are numeric badges only and increment automatically. Add explanatory text next to a badge with the separate text tool.

## Recording Workflow

1. Choose `Record Region` from the menu bar or press its configurable shortcut (default `Option + R`). You can also choose `Record Full Screen` or `Record Window...`.
   For region recording, the confirmation bar shows `Selection W × H`. Click it to enter an exact screen-pixel size, choose Free / 16:9 / 4:3 / 1:1 / 9:16, lock the current aspect ratio, or restore the last recorded region. These controls stay in a popover so they do not cover the other recording options, and they do not appear for full-screen or window recording.
2. For a window, point to the live highlight and click to lock that exact window. Then choose `Start Recording Video` or `Start Recording GIF`. Video can capture system audio, a selected built-in/USB/Bluetooth microphone, or both; GIF is always silent.
3. A centered 3–2–1 countdown appears before capture starts and can be cancelled. During recording, use the compact floating controls to pause, resume, stop, cancel, or collapse/expand the annotation tools. Full-screen recordings start with the controls collapsed so less of the screen is covered. The real-time annotation bar provides select, rectangle, arrow, pen, color, stroke width, undo, and redo controls; annotations enter both video and GIF output while the countdown, red border, and controls stay excluded.
4. After export, preview the result and save it to the configured location, copy it to the clipboard, or discard it.

Video defaults to 1080p at 30 FPS, with Original, 4K, and 720p resolution choices plus 15 and 60 FPS options. Scaling preserves the source aspect ratio without cropping or upscaling smaller content, and Brushot remembers the selection. Video is exported as network-optimized H.264/AAC MP4. When system audio and microphone are both enabled, they are synchronized and mixed into the exported audio. GIF export defaults to 720 pixels wide and 15 FPS; long recordings automatically reduce sampling to keep the result at approximately 600 frames instead of imposing the previous 30-second limit.

Camera picture-in-picture starts off for every new recording. Horizontal flip defaults to on the first time; after enabling the camera, open Picture-in-Picture Settings to choose circle or rounded rectangle, Small / Medium / Large, a corner, and horizontal flip. Brushot remembers the last device, position, size, shape, and horizontal-flip choice. You can also drag, resize, and snap it inside the selection, then toggle it or change these settings live during recording. On first use, recording remains disabled until the camera permission request finishes. A disconnected or failed camera does not stop screen recording. Camera pixels enter video output, while GIF does not use the camera.

GIF recording stops automatically at 3 minutes. Video recording stops automatically at 2 hours and shows the remaining time after the first hour. Brushot warns below 16 GB, blocks starting below 12 GB, and safely stops an active recording below 12 GB before macOS can terminate the stream under disk pressure.

## Pin Workflow

- Click the pin button in the screenshot toolbar to float the selected or annotated result above other windows.
- Open the menu bar's `Pins` submenu and choose `Pin from Clipboard` to pin PNG, TIFF, or other image content currently on the clipboard.
- In the same submenu, choose `Pin Library...` to reopen, delete, or clear persistent pin history. Identical image content is stored only once.
- Drag a pinned image to move it. After clicking it, use the arrow keys for one-pixel movement or Shift + arrow keys for ten pixels.
- Right-click a pin to change opacity or corner radius, keep it on the current desktop or show it on every desktop, copy/save it, or annotate it again.
- Double-clicking a pin opens the complete annotation toolset; completing the edit updates the pin and adds the edited result to history.
- Use `Hide All Pins` / `Show All Pins` from the menu bar to temporarily toggle every open pin.
- Open `Preferences...` to customize all global actions. Brushot rejects duplicate combinations and shortcuts already reserved by macOS or other applications.

## Run From Source

```bash
swift run Brushot
```

This path uses Swift Package Manager for development. The packaging scripts below use the Xcode toolchain directly and keep build output inside the project.

## Build `.app`

```bash
./scripts/build-app.sh
open .build/distribution/Brushot.app
```

## Build `.dmg`

```bash
./scripts/build-dmg.sh
open dist/Brushot.dmg
```

The generated app and DMG are signed as complete app bundles. `build-app.sh` always uses the bundle identifier `com.brushot.app` and overwrites `/Applications/Brushot.app` after a successful build, so normal local updates keep the same app path and do not require repeatedly removing the app or granting privacy permissions again.

The build prefers an explicitly configured identity, then the signing identity already used by `/Applications/Brushot.app`, then a Developer ID Application identity, then the first Apple Development identity in the login keychain. To select a different Apple Development or Developer ID identity:

```bash
BRUSHOT_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

macOS screen recording permission is required on first use. For permission testing, launch `/Applications/Brushot.app` instead of `swift run`, because direct command-line builds do not have the packaged app's signing identity.

The first capture requires macOS screen recording permission. If permission is denied, enable Brushot in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the app.

## Distribution TODO

Current work and release status are tracked in [TODO.md](TODO.md).
