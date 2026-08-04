import AppKit
import Carbon
import XCTest
@testable import SnapInk

@MainActor
final class ShortcutTests: XCTestCase {
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

        let settings = try XCTUnwrap(menu.items.first { $0.title == "快捷键设置…" })
        XCTAssertEqual(settings.keyEquivalent, "")
        XCTAssertTrue(settings.keyEquivalentModifierMask.isEmpty)
        let quit = try XCTUnwrap(menu.items.first { $0.title == "退出 SnapInk" })
        XCTAssertEqual(quit.keyEquivalent, "")
        XCTAssertTrue(quit.keyEquivalentModifierMask.isEmpty)
    }

    func testShortcutSettingsShowsFourRecorders() throws {
        let controller = ShortcutSettingsWindowController(
            shortcuts: ShortcutPreferences.loadAll(),
            onChange: { _, _ in }
        )
        let content = try XCTUnwrap(controller.window?.contentView)
        let recorders = descendants(of: content).compactMap { $0 as? ShortcutRecorderButton }

        XCTAssertEqual(controller.window?.title, "SnapInk 快捷键设置")
        XCTAssertEqual(recorders.count, ShortcutAction.allCases.count)
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

    func testTranslationMenuExplainsSystemRequirementAndOffersToggleWhenAvailable() {
        let delegate = AppDelegate()
        let unavailable = delegate.makeTranslationMenuItem(systemAvailable: false)
        XCTAssertEqual(unavailable.title, "OCR 英译中（需要 macOS 15 或更高版本）")
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertNil(unavailable.action)

        let available = delegate.makeTranslationMenuItem(systemAvailable: true)
        XCTAssertEqual(available.title, "启用 OCR 英译中")
        XCTAssertTrue(available.isEnabled)
        XCTAssertNotNil(available.action)
        XCTAssertEqual(
            available.state,
            TranslationPreferences.isEnabled() ? .on : .off
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
