import AppKit
import Carbon
import XCTest
@testable import SnapInk

@MainActor
final class ShortcutTests: XCTestCase {
    @MainActor
    func testApplicationEditMenuProvidesStandardTextResponderShortcuts() throws {
        let menu = AppDelegate().makeApplicationMenu()
        let applicationMenu = try XCTUnwrap(menu.items.first?.submenu)
        let editMenu = try XCTUnwrap(menu.items.first { $0.submenu?.title == "编辑" }?.submenu)

        let quitItem = try XCTUnwrap(applicationMenu.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        XCTAssertEqual(quitItem.keyEquivalent, "", "保持菜单栏应用现有的退出快捷键行为")

        let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
            (Selector(("undo:")), "z", .command),
            (Selector(("redo:")), "z", [.command, .shift]),
            (#selector(NSText.cut(_:)), "x", .command),
            (#selector(NSText.copy(_:)), "c", .command),
            (#selector(NSText.paste(_:)), "v", .command),
            (#selector(NSText.selectAll(_:)), "a", .command)
        ]

        for (action, key, modifiers) in expected {
            let item = try XCTUnwrap(editMenu.items.first { $0.action == action })
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
            XCTAssertNil(item.target, "编辑命令必须由当前文本控件通过响应者链处理")
        }
    }

    func testDefaultShortcutsAreUniqueAndPreferencesRoundTrip() throws {
        let suiteName = "SnapInk.ShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = ShortcutPreferences.loadAll(defaults: defaults)
        XCTAssertEqual(initial.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(initial.values).count, ShortcutAction.allCases.count)

        let replacement = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "K"
        )
        ShortcutPreferences.save(replacement, for: .pinLibrary, defaults: defaults)
        XCTAssertEqual(ShortcutPreferences.load(.pinLibrary, defaults: defaults), replacement)
    }

    func testRecordingShortcutDefaultsToOptionRAndMigratesLegacyGIFValue() throws {
        let freshSuite = "SnapInk.RecordingShortcutFresh.\(UUID().uuidString)"
        let fresh = try XCTUnwrap(UserDefaults(suiteName: freshSuite))
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let defaultShortcut = ShortcutPreferences.load(.recording, defaults: fresh)
        XCTAssertEqual(defaultShortcut.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(defaultShortcut.modifiers, UInt32(optionKey))

        let legacySuite = "SnapInk.RecordingShortcutLegacy.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer { legacy.removePersistentDomain(forName: legacySuite) }
        legacy.set(Int(kVK_ANSI_K), forKey: "gifCaptureShortcut.keyCode")
        legacy.set(Int(optionKey | shiftKey), forKey: "gifCaptureShortcut.modifiers")
        legacy.set("K", forKey: "gifCaptureShortcut.keyLabel")

        let migrated = ShortcutPreferences.load(.recording, defaults: legacy)
        XCTAssertEqual(migrated.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(migrated.modifiers, UInt32(optionKey | shiftKey))
        XCTAssertEqual(legacy.object(forKey: "recordingShortcut.keyCode") as? Int, kVK_ANSI_K)
    }

    func testValidatorRejectsInternalConflictsAndAllowsCommandComma() {
        let shortcuts = ShortcutPreferences.loadAll(
            defaults: UserDefaults(suiteName: "SnapInk.ShortcutDefaults.\(UUID().uuidString)")!
        )

        XCTAssertEqual(
            ShortcutValidator.conflict(
                for: shortcuts[.capture]!,
                action: .pinClipboard,
                shortcuts: shortcuts
            ),
            .action(.capture)
        )
        XCTAssertNil(ShortcutValidator.conflict(
            for: KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_Comma),
                modifiers: UInt32(cmdKey),
                keyLabel: ","
            ),
            action: .capture,
            shortcuts: shortcuts
        ))
        XCTAssertNil(ShortcutValidator.conflict(
            for: KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(controlKey | optionKey),
                keyLabel: "K"
            ),
            action: .capture,
            shortcuts: shortcuts
        ))
    }

    func testStatusMenuGroupsPinActionsAndQuitHasNoShortcut() throws {
        let menu = AppDelegate().makeStatusMenu()
        let longCapture = try XCTUnwrap(menu.items.first { $0.title == "长截图" })
        XCTAssertEqual(longCapture.keyEquivalent, "l")
        XCTAssertEqual(longCapture.keyEquivalentModifierMask, [.control, .option])
        let recording = try XCTUnwrap(menu.items.first { $0.title == "录屏…" })
        XCTAssertEqual(recording.keyEquivalent, "r")
        XCTAssertEqual(recording.keyEquivalentModifierMask, [.option])
        let pinItem = try XCTUnwrap(menu.items.first { $0.title == "贴图" })
        let pinMenu = try XCTUnwrap(pinItem.submenu)

        XCTAssertEqual(pinMenu.items.map(\.title), [
            "从剪贴板贴图",
            "贴图库…",
            PinManager.shared.visibilityMenuTitle
        ])
        XCTAssertEqual(pinMenu.items[0].keyEquivalent, "v")
        XCTAssertEqual(pinMenu.items[0].keyEquivalentModifierMask, [.option])
        XCTAssertEqual(pinMenu.items[1].keyEquivalent, "s")
        XCTAssertEqual(pinMenu.items[1].keyEquivalentModifierMask, [.option])
        XCTAssertEqual(pinMenu.items[2].keyEquivalent, "h")
        XCTAssertEqual(pinMenu.items[2].keyEquivalentModifierMask, [.option])

        let settings = try XCTUnwrap(menu.items.first { $0.title == "偏好设置…" })
        XCTAssertEqual(settings.keyEquivalent, "")
        XCTAssertTrue(settings.keyEquivalentModifierMask.isEmpty)
        let quit = try XCTUnwrap(menu.items.first { $0.title == "退出 SnapInk" })
        XCTAssertEqual(quit.keyEquivalent, "")
        XCTAssertTrue(quit.keyEquivalentModifierMask.isEmpty)
    }

    func testShortcutSettingsShowsAllRecordersIncludingLongCapture() throws {
        let controller = PreferencesWindowController(
            shortcuts: ShortcutPreferences.loadAll(),
            onShortcutChange: { _, _ in },
            onTranslationToggle: { _ in }
        )
        let content = try XCTUnwrap(controller.window?.contentView)
        let recorders = descendants(of: content).compactMap { $0 as? ShortcutRecorderButton }

        XCTAssertEqual(controller.window?.title, "偏好设置")
        XCTAssertEqual(recorders.count, ShortcutAction.allCases.count)
        XCTAssertNotNil(recorders.first {
            $0.identifier?.rawValue == "shortcut.\(ShortcutAction.longCapture.rawValue)"
        })
        XCTAssertEqual(
            Set(recorders.compactMap { $0.identifier?.rawValue }),
            Set(ShortcutAction.allCases.map { "shortcut.\($0.rawValue)" })
        )
    }

    func testTranslationPreferenceDefaultsOnAndPersistsToggle() throws {
        let suiteName = "SnapInk.TranslationPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TranslationPreferences.isEnabled(defaults: defaults))
        TranslationPreferences.setEnabled(false, defaults: defaults)
        XCTAssertFalse(TranslationPreferences.isEnabled(defaults: defaults))
        TranslationPreferences.setEnabled(true, defaults: defaults)
        XCTAssertTrue(TranslationPreferences.isEnabled(defaults: defaults))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
