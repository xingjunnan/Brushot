import AppKit
import Carbon
import XCTest
@testable import Brushot

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
        let suiteName = "Brushot.ShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = ShortcutPreferences.loadAll(defaults: defaults)
        XCTAssertEqual(initial.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(initial.values).count, ShortcutAction.allCases.count)
        XCTAssertEqual(initial[.fullscreenCapture]?.keyCode, UInt32(kVK_ANSI_F))
        XCTAssertEqual(initial[.fullscreenCapture]?.modifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(initial[.delayedCapture]?.keyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(initial[.delayedCapture]?.modifiers, UInt32(controlKey | optionKey))

        let replacement = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "K"
        )
        ShortcutPreferences.save(replacement, for: .pinLibrary, defaults: defaults)
        XCTAssertEqual(ShortcutPreferences.load(.pinLibrary, defaults: defaults), replacement)
    }

    func testAppLanguagePreferenceDefaultsToSystemAndRoundTripsEveryLanguage() throws {
        let suiteName = "Brushot.AppLanguagePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguagePreferences.selectedLanguage(defaults: defaults), .system)
        for language in AppLanguage.allCases {
            AppLanguagePreferences.setSelectedLanguage(language, defaults: defaults)
            XCTAssertEqual(AppLanguagePreferences.selectedLanguage(defaults: defaults), language)
        }
        defaults.set("unsupported", forKey: "appLanguage")
        XCTAssertEqual(AppLanguagePreferences.selectedLanguage(defaults: defaults), .system)
    }

    func testRecordingShortcutDefaultsToOptionRAndMigratesLegacyGIFValue() throws {
        let freshSuite = "Brushot.RecordingShortcutFresh.\(UUID().uuidString)"
        let fresh = try XCTUnwrap(UserDefaults(suiteName: freshSuite))
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let defaultShortcut = ShortcutPreferences.load(.recording, defaults: fresh)
        XCTAssertEqual(defaultShortcut.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(defaultShortcut.modifiers, UInt32(optionKey))

        let legacySuite = "Brushot.RecordingShortcutLegacy.\(UUID().uuidString)"
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
            defaults: UserDefaults(suiteName: "Brushot.ShortcutDefaults.\(UUID().uuidString)")!
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
        XCTAssertEqual(Array(menu.items.prefix(8).map(\.title)), [
            "区域截图", "全屏截图", "延时截图…", "长截图", "", "区域录屏", "全屏录屏", ""
        ])
        XCTAssertTrue(menu.items[4].isSeparatorItem)
        XCTAssertTrue(menu.items[7].isSeparatorItem)
        let fullscreen = try XCTUnwrap(menu.items.first { $0.title == "全屏截图" })
        XCTAssertEqual(fullscreen.keyEquivalent, "f")
        XCTAssertEqual(fullscreen.keyEquivalentModifierMask, [.control, .option])
        let delayed = try XCTUnwrap(menu.items.first { $0.title == "延时截图…" })
        XCTAssertEqual(delayed.keyEquivalent, "d")
        XCTAssertEqual(delayed.keyEquivalentModifierMask, [.control, .option])
        let longCapture = try XCTUnwrap(menu.items.first { $0.title == "长截图" })
        XCTAssertEqual(longCapture.keyEquivalent, "l")
        XCTAssertEqual(longCapture.keyEquivalentModifierMask, [.control, .option])
        let recording = try XCTUnwrap(menu.items.first { $0.title == "区域录屏" })
        XCTAssertEqual(recording.keyEquivalent, "r")
        XCTAssertEqual(recording.keyEquivalentModifierMask, [.option])
        let fullscreenRecording = try XCTUnwrap(menu.items.first { $0.title == "全屏录屏" })
        XCTAssertEqual(fullscreenRecording.keyEquivalent, "")
        XCTAssertTrue(fullscreenRecording.keyEquivalentModifierMask.isEmpty)
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
        let settingsIndex = try XCTUnwrap(menu.items.firstIndex(of: settings))
        XCTAssertEqual(menu.items[settingsIndex + 1].title, "水印设置…")
        XCTAssertEqual(menu.items[settingsIndex + 1].keyEquivalent, "")
        XCTAssertTrue(menu.items[settingsIndex + 1].keyEquivalentModifierMask.isEmpty)
        let feedback = try XCTUnwrap(menu.items.first { $0.title == "问题反馈…" })
        XCTAssertEqual(feedback.keyEquivalent, "")
        XCTAssertTrue(feedback.keyEquivalentModifierMask.isEmpty)
        let quit = try XCTUnwrap(menu.items.first { $0.title == "退出 Brushot" })
        let feedbackIndex = try XCTUnwrap(menu.items.firstIndex(of: feedback))
        XCTAssertEqual(menu.items[feedbackIndex + 1], quit)
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
        XCTAssertNotNil(recorders.first {
            $0.identifier?.rawValue == "shortcut.\(ShortcutAction.fullscreenCapture.rawValue)"
        })
        XCTAssertNotNil(recorders.first {
            $0.identifier?.rawValue == "shortcut.\(ShortcutAction.delayedCapture.rawValue)"
        })
        XCTAssertNotNil(descendants(of: content).first {
            $0.identifier?.rawValue == "selfTimerDurationStepper"
        })
        XCTAssertNotNil(descendants(of: content).first {
            $0.identifier?.rawValue == "selfTimerTickSound"
        })
        let selectionMagnifier = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "selectionMagnifierEnabled"
        } as? NSButton)
        XCTAssertEqual(selectionMagnifier.state, AppPreferences.selectionMagnifierEnabled ? .on : .off)
        let completionSound = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "completionSoundEnabled"
        } as? NSButton)
        XCTAssertEqual(completionSound.title, "播放操作完成提示音")
        XCTAssertEqual(completionSound.state, AppPreferences.completionSoundEnabled ? .on : .off)
        let languageSection = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "languageSection"
        } as? NSStackView)
        let languagePopUp = try XCTUnwrap(descendants(of: languageSection).first {
            $0.identifier?.rawValue == "appLanguage"
        } as? NSPopUpButton)
        XCTAssertEqual(languagePopUp.itemArray.compactMap { $0.representedObject as? String }, AppLanguage.allCases.map(\.rawValue))
        XCTAssertEqual(
            languagePopUp.selectedItem?.representedObject as? String,
            AppLanguagePreferences.selectedLanguage().rawValue
        )
        let languageRestartHint = try XCTUnwrap(descendants(of: languageSection).first {
            $0.identifier?.rawValue == "appLanguageRestartHint"
        } as? NSTextField)
        XCTAssertTrue(languageRestartHint.isHidden)
        let shortcutGroups = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "shortcutGroups"
        } as? NSStackView)
        XCTAssertEqual(shortcutGroups.spacing, 16)
        XCTAssertEqual(shortcutGroups.arrangedSubviews.count, 2)
        XCTAssertNotNil(descendants(of: content).first {
            $0.identifier?.rawValue == "shortcutGroup.capture"
        })
        XCTAssertNotNil(descendants(of: content).first {
            $0.identifier?.rawValue == "shortcutGroup.pin"
        })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(recorders.allSatisfy { abs($0.frame.width - 112) < 1 })
        let captureCard = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "shortcutGroup.capture"
        })
        let pinCard = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "shortcutGroup.pin"
        })
        XCTAssertGreaterThan(captureCard.frame.width, 200)
        XCTAssertEqual(captureCard.frame.width, pinCard.frame.width, accuracy: 1)
        let captureHeading = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "shortcutGroup.capture.heading"
        })
        XCTAssertEqual(captureHeading.stringValue, "截图与录制")
        XCTAssertGreaterThanOrEqual(captureHeading.frame.height, 17)
        XCTAssertEqual(
            Set(recorders.compactMap { $0.identifier?.rawValue }),
            Set(ShortcutAction.allCases.map { "shortcut.\($0.rawValue)" })
        )
    }

    func testWatermarkSettingsExplainsMissingContentAndBlocksEmptyEnable() throws {
        let previousWatermark = WatermarkPreferences.load()
        defer {
            WatermarkPreferences.save(previousWatermark)
        }

        WatermarkPreferences.save(.default)
        let controller = WatermarkSettingsWindowController()
        let content = try XCTUnwrap(controller.window?.contentView)
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        let screenshotInfo = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "watermarkScreenshotInfo" })
        XCTAssertEqual(screenshotInfo.toolTip, "请先填写水印文字或选择 Logo")
        XCTAssertNil(buttons.first { $0.identifier?.rawValue == "watermarkRecordingInfo" })
        XCTAssertNil(buttons.first { $0.title == "应用到录制视频/GIF" })
        XCTAssertTrue(descendants(of: content).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "录制水印在录制完成后选择"
        })
        let preview = try XCTUnwrap(descendants(of: content).first {
            $0.identifier?.rawValue == "watermarkSettings.preview"
        })
        XCTAssertEqual(preview.constraints.first { $0.firstAttribute == .height }?.constant, 150)
        let colorWell = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSColorWell }.first {
            $0.identifier?.rawValue == "watermarkSettings.textColor"
        })
        XCTAssertEqual(colorWell.constraints.first { $0.firstAttribute == .width }?.constant, 54)

        XCTAssertFalse(controller.applyWatermarkEnabledState(true))
        XCTAssertFalse(WatermarkPreferences.load().isEnabled)
    }

    func testWatermarkSettingsAllowsEnableAfterTextIsConfigured() throws {
        let previousWatermark = WatermarkPreferences.load()
        defer {
            WatermarkPreferences.save(previousWatermark)
        }

        var config = WatermarkConfiguration.default
        config.text = "Brushot"
        WatermarkPreferences.save(config)
        let controller = WatermarkSettingsWindowController()

        XCTAssertTrue(controller.applyWatermarkEnabledState(true))
        XCTAssertTrue(WatermarkPreferences.load().isEnabled)
    }

    func testTranslationPreferenceDefaultsOnAndPersistsToggle() throws {
        let suiteName = "Brushot.TranslationPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TranslationPreferences.isEnabled(defaults: defaults))
        TranslationPreferences.setEnabled(false, defaults: defaults)
        XCTAssertFalse(TranslationPreferences.isEnabled(defaults: defaults))
        TranslationPreferences.setEnabled(true, defaults: defaults)
        XCTAssertTrue(TranslationPreferences.isEnabled(defaults: defaults))
    }

    func testSelectionMagnifierPreferenceDefaultsOffAndPersists() throws {
        let suiteName = "Brushot.SelectionMagnifier.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppPreferences.selectionMagnifierEnabled(defaults: defaults))
        AppPreferences.setSelectionMagnifierEnabled(true, defaults: defaults)
        XCTAssertTrue(AppPreferences.selectionMagnifierEnabled(defaults: defaults))
        AppPreferences.setSelectionMagnifierEnabled(false, defaults: defaults)
        XCTAssertFalse(AppPreferences.selectionMagnifierEnabled(defaults: defaults))
    }

    func testCompletionSoundPreferenceDefaultsOnAndPersists() throws {
        let suiteName = "Brushot.CompletionSound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(AppPreferences.completionSoundEnabled(defaults: defaults))
        AppPreferences.setCompletionSoundEnabled(false, defaults: defaults)
        XCTAssertFalse(AppPreferences.completionSoundEnabled(defaults: defaults))
        AppPreferences.setCompletionSoundEnabled(true, defaults: defaults)
        XCTAssertTrue(AppPreferences.completionSoundEnabled(defaults: defaults))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
