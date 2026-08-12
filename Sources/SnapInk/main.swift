import AppKit
import Carbon
import CoreGraphics
import Darwin
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers

struct KeyboardShortcut: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultCapture = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "S"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard eventModifiers.contains(.command)
                || eventModifiers.contains(.control)
                || eventModifiers.contains(.option) else {
            return nil
        }

        var carbonModifiers: UInt32 = 0
        if eventModifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if eventModifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if eventModifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if eventModifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        keyCode = UInt32(event.keyCode)
        modifiers = carbonModifiers
        keyLabel = Self.label(for: event.keyCode)
    }

    var displayText: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { value.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { value.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { value.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { value.insert(.command) }
        return value
    }

    var menuKeyEquivalent: String {
        let equivalents: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "a", UInt32(kVK_ANSI_B): "b", UInt32(kVK_ANSI_C): "c",
            UInt32(kVK_ANSI_D): "d", UInt32(kVK_ANSI_E): "e", UInt32(kVK_ANSI_F): "f",
            UInt32(kVK_ANSI_G): "g", UInt32(kVK_ANSI_H): "h", UInt32(kVK_ANSI_I): "i",
            UInt32(kVK_ANSI_J): "j", UInt32(kVK_ANSI_K): "k", UInt32(kVK_ANSI_L): "l",
            UInt32(kVK_ANSI_M): "m", UInt32(kVK_ANSI_N): "n", UInt32(kVK_ANSI_O): "o",
            UInt32(kVK_ANSI_P): "p", UInt32(kVK_ANSI_Q): "q", UInt32(kVK_ANSI_R): "r",
            UInt32(kVK_ANSI_S): "s", UInt32(kVK_ANSI_T): "t", UInt32(kVK_ANSI_U): "u",
            UInt32(kVK_ANSI_V): "v", UInt32(kVK_ANSI_W): "w", UInt32(kVK_ANSI_X): "x",
            UInt32(kVK_ANSI_Y): "y", UInt32(kVK_ANSI_Z): "z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
            UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
            UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
            UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_Space): " ",
            UInt32(kVK_Return): "\r", UInt32(kVK_Tab): "\t",
            UInt32(kVK_Delete): "\u{8}", UInt32(kVK_ForwardDelete): "\u{F728}",
            UInt32(kVK_LeftArrow): "\u{F702}", UInt32(kVK_RightArrow): "\u{F703}",
            UInt32(kVK_UpArrow): "\u{F700}", UInt32(kVK_DownArrow): "\u{F701}",
            UInt32(kVK_F1): "\u{F704}", UInt32(kVK_F2): "\u{F705}",
            UInt32(kVK_F3): "\u{F706}", UInt32(kVK_F4): "\u{F707}",
            UInt32(kVK_F5): "\u{F708}", UInt32(kVK_F6): "\u{F709}",
            UInt32(kVK_F7): "\u{F70A}", UInt32(kVK_F8): "\u{F70B}",
            UInt32(kVK_F9): "\u{F70C}", UInt32(kVK_F10): "\u{F70D}",
            UInt32(kVK_F11): "\u{F70E}", UInt32(kVK_F12): "\u{F70F}"
        ]
        return equivalents[keyCode] ?? ""
    }

    static func == (lhs: KeyboardShortcut, rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    private static func label(for keyCode: UInt16) -> String {
        let labels: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
            UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
            UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
            UInt16(kVK_ANSI_9): "9",
            UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
            UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
            UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
            UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
            UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
            UInt16(kVK_ANSI_Grave): "`",
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
        ]
        return labels[keyCode] ?? "Key (keyCode)"
    }
}

enum ShortcutAction: UInt32, CaseIterable, Hashable {
    case capture = 1
    case pinClipboard = 2
    case pinLibrary = 3
    case togglePins = 4
    case longCapture = 5
    case recording = 6
    case fullscreenCapture = 7
    case delayedCapture = 8

    var title: String {
        switch self {
        case .capture: "区域截图"
        case .longCapture: "长截图"
        case .recording: "录屏…"
        case .fullscreenCapture: "全屏截图"
        case .delayedCapture: "延时截图…"
        case .pinClipboard: "从剪贴板贴图"
        case .pinLibrary: "贴图库…"
        case .togglePins: "隐藏全部贴图"
        }
    }

    var preferencePrefix: String {
        switch self {
        case .capture: "captureShortcut"
        case .longCapture: "longCaptureShortcut"
        case .recording: "recordingShortcut"
        case .fullscreenCapture: "fullscreenCaptureShortcut"
        case .delayedCapture: "delayedCaptureShortcut"
        case .pinClipboard: "pinClipboardShortcut"
        case .pinLibrary: "pinLibraryShortcut"
        case .togglePins: "togglePinsShortcut"
        }
    }

    var defaultShortcut: KeyboardShortcut {
        switch self {
        case .capture:
            .defaultCapture
        case .longCapture:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_L),
                modifiers: UInt32(controlKey | optionKey),
                keyLabel: "L"
            )
        case .recording:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_R),
                modifiers: UInt32(optionKey),
                keyLabel: "R"
            )
        case .fullscreenCapture:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_F),
                modifiers: UInt32(controlKey | optionKey),
                keyLabel: "F"
            )
        case .delayedCapture:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_D),
                modifiers: UInt32(controlKey | optionKey),
                keyLabel: "D"
            )
        case .pinClipboard:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(optionKey),
                keyLabel: "V"
            )
        case .pinLibrary:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_S),
                modifiers: UInt32(optionKey),
                keyLabel: "S"
            )
        case .togglePins:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_H),
                modifiers: UInt32(optionKey),
                keyLabel: "H"
            )
        }
    }
}

enum ShortcutConflict: Equatable {
    case action(ShortcutAction)
}

enum ShortcutValidator {
    static func conflict(
        for shortcut: KeyboardShortcut,
        action: ShortcutAction,
        shortcuts: [ShortcutAction: KeyboardShortcut]
    ) -> ShortcutConflict? {
        if let existing = ShortcutAction.allCases.first(where: {
            $0 != action && shortcuts[$0] == shortcut
        }) {
            return .action(existing)
        }
        return nil
    }
}

enum ShortcutPreferences {
    static func load(
        _ action: ShortcutAction,
        defaults: UserDefaults = .standard
    ) -> KeyboardShortcut {
        let prefix = action.preferencePrefix
        if action == .recording,
           defaults.object(forKey: "\(prefix).keyCode") == nil,
           defaults.object(forKey: "gifCaptureShortcut.keyCode") != nil,
           let label = defaults.string(forKey: "gifCaptureShortcut.keyLabel") {
            let migrated = KeyboardShortcut(
                keyCode: UInt32(defaults.integer(forKey: "gifCaptureShortcut.keyCode")),
                modifiers: UInt32(defaults.integer(forKey: "gifCaptureShortcut.modifiers")),
                keyLabel: label
            )
            save(migrated, for: action, defaults: defaults)
            return migrated
        }
        guard defaults.object(forKey: "\(prefix).keyCode") != nil,
              let label = defaults.string(forKey: "\(prefix).keyLabel") else {
            return action.defaultShortcut
        }
        return KeyboardShortcut(
            keyCode: UInt32(defaults.integer(forKey: "\(prefix).keyCode")),
            modifiers: UInt32(defaults.integer(forKey: "\(prefix).modifiers")),
            keyLabel: label
        )
    }

    static func loadAll(defaults: UserDefaults = .standard) -> [ShortcutAction: KeyboardShortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map {
            ($0, load($0, defaults: defaults))
        })
    }

    static func save(
        _ shortcut: KeyboardShortcut,
        for action: ShortcutAction,
        defaults: UserDefaults = .standard
    ) {
        let prefix = action.preferencePrefix
        defaults.set(Int(shortcut.keyCode), forKey: "\(prefix).keyCode")
        defaults.set(Int(shortcut.modifiers), forKey: "\(prefix).modifiers")
        defaults.set(shortcut.keyLabel, forKey: "\(prefix).keyLabel")
    }
}

enum TranslationPreferences {
    private static let enabledKey = "ocrTranslation.enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static var isSystemAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}

enum AppPreferences {
    private static let launchAtLoginKey = "launchAtLogin"
    private static let saveLocationKey = "saveLocation"
    private static let imageFormatKey = "imageFormat"
    private static let selectionMagnifierEnabledKey = "selectionMagnifierEnabled"

    // MARK: - Launch at login

    static var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: launchAtLoginKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: launchAtLoginKey)
            applyLaunchAtLogin(newValue)
        }
    }

    static func syncLaunchAtLogin() {
        applyLaunchAtLogin(launchAtLogin)
    }

    private static func applyLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                try? service.register()
            } else {
                try? service.unregister()
            }
        }
    }

    // MARK: - Save location

    static var saveLocation: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: saveLocationKey),
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return defaultSaveLocation
        }
        set { UserDefaults.standard.set(newValue.path, forKey: saveLocationKey) }
    }

    static var defaultSaveLocation: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Image format

    enum ImageFormat: String, CaseIterable {
        case png
        case jpg

        var displayName: String {
            switch self {
            case .png: "PNG"
            case .jpg: "JPG"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpg: "jpg"
            }
        }

        var utType: String {
            switch self {
            case .png: "public.png"
            case .jpg: "public.jpeg"
            }
        }
    }

    static var imageFormat: ImageFormat {
        get {
            ImageFormat(rawValue: UserDefaults.standard.string(forKey: imageFormatKey) ?? "png") ?? .png
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: imageFormatKey) }
    }

    // MARK: - Capture overlay

    /// Shows the live loupe/color sampler while choosing an area.
    ///
    /// Default is off because the live loupe repeatedly captures a tiny screen
    /// region around the cursor, which can make macOS show its screen-capture
    /// privacy banner during ordinary screenshots.
    static var selectionMagnifierEnabled: Bool {
        get { selectionMagnifierEnabled(defaults: .standard) }
        set { setSelectionMagnifierEnabled(newValue, defaults: .standard) }
    }

    static func selectionMagnifierEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: selectionMagnifierEnabledKey)
    }

    static func setSelectionMagnifierEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: selectionMagnifierEnabledKey)
    }
}

private enum DisplaySnapshotCapturer {
    typealias CGDisplayCreateImageFunction = @convention(c) (CGDirectDisplayID) -> CGImage?

    /// Capture the whole display with the lowest-impact synchronous path first.
    ///
    /// ``CGDisplayCreateImage`` is deprecated at compile time on newer macOS
    /// SDKs, but it still exists at runtime and avoids the more visible
    /// ScreenCaptureKit/stream capture path for the frozen selection backdrop.
    /// If the symbol disappears or the call fails, fall back to the existing
    /// CGWindowList path.
    static func captureDisplay(_ displayID: CGDirectDisplayID) -> CGImage? {
        if let image = captureWithCGDisplayCreateImage(displayID) {
            return image
        }
        return CGWindowListCreateImage(
            CGDisplayBounds(displayID),
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        )
    }

    static func scale(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID),
              mode.width > 0 else {
            return 1
        }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func captureWithCGDisplayCreateImage(_ displayID: CGDirectDisplayID) -> CGImage? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "CGDisplayCreateImage") else {
            return nil
        }

        let function = unsafeBitCast(symbol, to: CGDisplayCreateImageFunction.self)
        return function(displayID)
    }
}

@MainActor
@objcMembers
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var shortcutMenuItems: [ShortcutAction: NSMenuItem] = [:]
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let captureController = CaptureController()
    private var settingsWindowController: PreferencesWindowController?
    private var watermarkSettingsWindowController: WatermarkSettingsWindowController?
    private var pinVisibilityMenuItem: NSMenuItem!
    private let pinManager = PinManager.shared
    private var shortcuts = ShortcutPreferences.loadAll()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeApplicationMenu()
        configureStatusItem()
        installHotKeyHandler()
        registerInitialHotKeys()
        AppPreferences.syncLaunchAtLogin()
        RecordingPreviewWindowController.cleanupExpiredClipboardFiles()
    }

    /// Accessory applications do not get the standard application menu that
    /// AppKit normally creates from a storyboard or nib. Text controls rely on
    /// these responder-chain actions for their conventional keyboard shortcuts.
    func makeApplicationMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "SnapInk")
        let quitItem = NSMenuItem(
            title: "退出 SnapInk",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quitItem.keyEquivalentModifierMask = []
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(makeResponderMenuItem(title: "撤销", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(makeResponderMenuItem(
            title: "重做",
            action: Selector(("redo:")),
            key: "z",
            modifiers: [.command, .shift]
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(makeResponderMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(makeResponderMenuItem(title: "复制", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(makeResponderMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(makeResponderMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    private func makeResponderMenuItem(
        title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // A nil target sends the action through the current key window's
        // responder chain, so this works for NSTextField and NSTextView alike.
        item.target = nil
        return item
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureController.cancelTransientCapture()
        hotKeyRefs.values.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "SnapInk 截图"
            button.setAccessibilityLabel("SnapInk")
        }

        statusItem.menu = makeStatusMenu()
        pinManager.onVisibilityChanged = { [weak self] in
            guard let self else { return }
            self.pinVisibilityMenuItem.title = self.pinManager.visibilityMenuTitle
        }
    }

    func makeStatusMenu() -> NSMenu {
        shortcutMenuItems.removeAll()
        let menu = NSMenu()

        let capture = makeShortcutMenuItem(
            action: .capture,
            title: "区域截图",
            selector: #selector(captureSelection)
        )
        menu.addItem(capture)

        let fullscreen = makeShortcutMenuItem(
            action: .fullscreenCapture,
            title: "全屏截图",
            selector: #selector(captureFullscreen)
        )
        menu.addItem(fullscreen)

        let delayed = makeShortcutMenuItem(
            action: .delayedCapture,
            title: "延时截图…",
            selector: #selector(captureDelayed)
        )
        menu.addItem(delayed)

        let longCapture = makeShortcutMenuItem(
            action: .longCapture,
            title: "长截图",
            selector: #selector(captureLongScreenshot)
        )
        menu.addItem(longCapture)

        let recording = makeShortcutMenuItem(
            action: .recording,
            title: "录屏…",
            selector: #selector(captureRecording)
        )
        menu.addItem(recording)

        let pinItem = NSMenuItem(title: "贴图", action: nil, keyEquivalent: "")
        let pinMenu = NSMenu(title: "贴图")
        pinMenu.addItem(makeShortcutMenuItem(
            action: .pinClipboard,
            title: "从剪贴板贴图",
            selector: #selector(pinClipboard)
        ))
        pinMenu.addItem(makeShortcutMenuItem(
            action: .pinLibrary,
            title: "贴图库…",
            selector: #selector(showPinLibrary)
        ))
        pinVisibilityMenuItem = NSMenuItem(
            title: pinManager.visibilityMenuTitle,
            action: #selector(toggleAllPins),
            keyEquivalent: ""
        )
        pinVisibilityMenuItem.target = self
        shortcutMenuItems[.togglePins] = pinVisibilityMenuItem
        applyShortcut(shortcuts[.togglePins] ?? ShortcutAction.togglePins.defaultShortcut, to: pinVisibilityMenuItem)
        pinMenu.addItem(pinVisibilityMenuItem)
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        menu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(
            title: "偏好设置…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settings.target = self
        settings.keyEquivalentModifierMask = []
        menu.addItem(settings)
        let watermarkSettings = NSMenuItem(
            title: "水印设置…",
            action: #selector(showWatermarkSettings),
            keyEquivalent: ""
        )
        watermarkSettings.target = self
        watermarkSettings.keyEquivalentModifierMask = []
        menu.addItem(watermarkSettings)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 SnapInk", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = []
        menu.addItem(quitItem)
        return menu
    }

    private func makeShortcutMenuItem(
        action: ShortcutAction,
        title: String,
        selector: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        shortcutMenuItems[action] = item
        applyShortcut(shortcuts[action] ?? action.defaultShortcut, to: item)
        return item
    }

    private func applyShortcut(_ shortcut: KeyboardShortcut, to item: NSMenuItem) {
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.menuModifierMask
    }

    @objc private func pinClipboard() {
        do { _ = try pinManager.pinClipboard() }
        catch { showPinFailure(error.localizedDescription) }
    }

    @objc private func showPinLibrary() {
        pinManager.showLibrary()
    }

    @objc private func toggleAllPins() {
        pinManager.toggleAllPins()
    }

    private func showPinFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "贴图失败"
        alert.informativeText = message
        alert.runModal()
    }

    func makeStatusBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            corners.move(to: NSPoint(x: 2.5, y: 7))
            corners.line(to: NSPoint(x: 2.5, y: 14.5))
            corners.line(to: NSPoint(x: 7, y: 14.5))
            corners.move(to: NSPoint(x: 11, y: 14.5))
            corners.line(to: NSPoint(x: 15.5, y: 14.5))
            corners.line(to: NSPoint(x: 15.5, y: 10))
            corners.move(to: NSPoint(x: 2.5, y: 8))
            corners.line(to: NSPoint(x: 2.5, y: 3.5))
            corners.line(to: NSPoint(x: 7, y: 3.5))
            corners.move(to: NSPoint(x: 11, y: 3.5))
            corners.line(to: NSPoint(x: 15.5, y: 3.5))
            corners.line(to: NSPoint(x: 15.5, y: 8))
            corners.stroke()

            // Reuse the system pencil silhouette so the center mark reads as
            // annotation rather than an export arrow at menu-bar size.
            let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: "SnapInk")?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
            pencil?.draw(
                in: NSRect(x: 3.75, y: 3.75, width: 10.5, height: 10.5),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let userData else { return noErr }
            var eventID = EventHotKeyID()
            GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &eventID
            )

            guard let action = ShortcutAction(rawValue: eventID.id) else { return noErr }

            Task { @MainActor in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                delegate.performShortcutAction(action)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)

        if status != noErr {
            NSLog("SnapInk failed to install hotkey handler: \(status)")
        }
    }

    @discardableResult
    private func registerHotKey(_ shortcut: KeyboardShortcut, for action: ShortcutAction) -> Bool {
        let hotKeyID = EventHotKeyID(
            signature: OSType(UInt32(truncatingIfNeeded: 0x53494E4B)),
            id: action.rawValue
        )
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            NSLog("SnapInk failed to register \(action) hotkey: \(status)")
            return false
        }
        if let hotKeyRef {
            hotKeyRefs[action] = hotKeyRef
        }
        return true
    }

    private func unregisterHotKey(for action: ShortcutAction) {
        guard let reference = hotKeyRefs.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(reference)
    }

    private func registerInitialHotKeys() {
        var registeredShortcuts: [ShortcutAction: KeyboardShortcut] = [:]
        for action in ShortcutAction.allCases {
            var candidate = shortcuts[action] ?? action.defaultShortcut
            let duplicatesAnotherAction = registeredShortcuts.values.contains(candidate)
            if duplicatesAnotherAction || !registerHotKey(candidate, for: action) {
                candidate = action.defaultShortcut
                guard !registeredShortcuts.values.contains(candidate),
                      registerHotKey(candidate, for: action) else {
                    NSLog("SnapInk could not register a fallback hotkey for \(action)")
                    continue
                }
                shortcuts[action] = candidate
                ShortcutPreferences.save(candidate, for: action)
                applyShortcut(candidate, to: shortcutMenuItems[action]!)
            }
            registeredShortcuts[action] = candidate
        }
    }

    private func updateShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        let previousShortcut = shortcuts[action] ?? action.defaultShortcut
        if let conflict = ShortcutValidator.conflict(
            for: shortcut,
            action: action,
            shortcuts: shortcuts
        ) {
            settingsWindowController?.setShortcut(previousShortcut, for: action)
            showInternalHotKeyConflictAlert(conflict)
            return
        }

        unregisterHotKey(for: action)
        guard registerHotKey(shortcut, for: action) else {
            _ = registerHotKey(previousShortcut, for: action)
            settingsWindowController?.setShortcut(previousShortcut, for: action)
            showHotKeyConflictAlert()
            return
        }

        shortcuts[action] = shortcut
        ShortcutPreferences.save(shortcut, for: action)
        if let item = shortcutMenuItems[action] {
            applyShortcut(shortcut, to: item)
        }
    }

    private func showHotKeyConflictAlert() {
        let alert = NSAlert()
        alert.messageText = "快捷键不可用"
        alert.informativeText = "该快捷键可能已被其他应用占用，请换一个组合。"
        alert.runModal()
    }

    private func showInternalHotKeyConflictAlert(_ conflict: ShortcutConflict) {
        let name: String
        switch conflict {
        case .action(let action): name = action.title
        }
        let alert = NSAlert()
        alert.messageText = "快捷键冲突"
        alert.informativeText = "该快捷键已用于“\(name)”，请换一个组合。"
        alert.runModal()
    }

    private func performShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .capture: captureSelection()
        case .longCapture: captureLongScreenshot()
        case .recording: captureRecording()
        case .fullscreenCapture: captureFullscreen()
        case .delayedCapture: captureDelayed()
        case .pinClipboard: pinClipboard()
        case .pinLibrary: showPinLibrary()
        case .togglePins: toggleAllPins()
        }
    }

    @objc private func captureSelection() {
        captureController.beginSelectionCapture()
    }

    @objc private func captureLongScreenshot() {
        captureController.beginLongCapture()
    }

    @objc private func captureFullscreen() {
        captureController.beginFullscreenCapture()
    }

    @objc private func captureDelayed() {
        captureController.beginDelayedCapture()
    }

    @objc private func captureRecording() {
        captureController.beginRecordingCapture()
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = PreferencesWindowController(
                shortcuts: shortcuts,
                onShortcutChange: { [weak self] action, shortcut in
                    self?.updateShortcut(shortcut, for: action)
                },
                onTranslationToggle: { [weak self] enabled in
                    self?.captureController.setTranslationEnabled(enabled)
                }
            )
        }
        settingsWindowController?.setShortcuts(shortcuts)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showWatermarkSettings() {
        if watermarkSettingsWindowController == nil {
            watermarkSettingsWindowController = WatermarkSettingsWindowController()
        }
        watermarkSettingsWindowController?.showWindow(nil)
        watermarkSettingsWindowController?.window?.center()
        watermarkSettingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private var recorderButtons: [ShortcutAction: ShortcutRecorderButton] = [:]
    private let onShortcutChange: (ShortcutAction, KeyboardShortcut) -> Void
    private let onTranslationToggle: (Bool) -> Void

    private var launchAtLoginCheckbox: NSButton!
    private var translationCheckbox: NSButton!
    private var saveLocationLabel: NSTextField!
    private var formatPopUp: NSPopUpButton!
    private var selectionMagnifierCheckbox: NSButton!
    private var selfTimerDurationLabel: NSTextField!
    private var selfTimerDurationStepper: NSStepper!
    private var selfTimerTickCheckbox: NSButton!

    init(
        shortcuts: [ShortcutAction: KeyboardShortcut],
        onShortcutChange: @escaping (ShortcutAction, KeyboardShortcut) -> Void,
        onTranslationToggle: @escaping (Bool) -> Void
    ) {
        self.onShortcutChange = onShortcutChange
        self.onTranslationToggle = onTranslationToggle
        for action in ShortcutAction.allCases {
            recorderButtons[action] = ShortcutRecorderButton(
                shortcut: shortcuts[action] ?? action.defaultShortcut
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        for (action, button) in recorderButtons {
            button.identifier = NSUserInterfaceItemIdentifier("shortcut.\(action.rawValue)")
            button.onRecordingStarted = { [weak self, weak button] in
                guard let self, let button else { return }
                self.stopRecording(except: button)
            }
            button.onShortcutChange = { [weak self] shortcut in
                self?.onShortcutChange(action, shortcut)
            }
        }
        configureContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        recorderButtons[action]?.setShortcut(shortcut)
    }

    func setShortcuts(_ shortcuts: [ShortcutAction: KeyboardShortcut]) {
        for (action, shortcut) in shortcuts {
            setShortcut(shortcut, for: action)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(except: nil)
    }

    // MARK: - Layout

    private func configureContentView() {
        guard let contentView = window?.contentView else { return }

        // --- 通用 ---
        launchAtLoginCheckbox = makeCheckbox(
            title: "开机自动启动",
            action: #selector(toggleLaunchAtLogin)
        )
        launchAtLoginCheckbox.state = AppPreferences.launchAtLogin ? .on : .off

        translationCheckbox = makeCheckbox(
            title: TranslationPreferences.isSystemAvailable
                ? "启用 OCR 英译中"
                : "启用 OCR 英译中（需要 macOS 15 或更高版本）",
            action: #selector(toggleTranslation)
        )
        translationCheckbox.state = TranslationPreferences.isEnabled() ? .on : .off
        translationCheckbox.isEnabled = TranslationPreferences.isSystemAvailable

        let generalSection = makeSection(
            title: "通用",
            views: [launchAtLoginCheckbox, translationCheckbox]
        )

        // --- 图片 ---
        saveLocationLabel = NSTextField(labelWithString: AppPreferences.saveLocation.path)
        saveLocationLabel.font = .systemFont(ofSize: 12)
        saveLocationLabel.lineBreakMode = .byTruncatingMiddle
        saveLocationLabel.cell?.truncatesLastVisibleLine = true
        saveLocationLabel.cell?.wraps = false
        saveLocationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveLocationLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let chooseButton = NSButton(title: "选择…", target: self, action: #selector(chooseSaveLocation))
        chooseButton.bezelStyle = .rounded

        let locationRow = makeRow(
            label: "保存位置",
            trailingViews: [saveLocationLabel, chooseButton]
        )

        formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopUp.addItems(withTitles: AppPreferences.ImageFormat.allCases.map { $0.displayName })
        formatPopUp.selectItem(withTitle: AppPreferences.imageFormat.displayName)
        formatPopUp.target = self
        formatPopUp.action = #selector(changeImageFormat)

        let formatRow = makeRow(
            label: "存储格式",
            trailingViews: [formatPopUp]
        )

        let imageSection = makeSection(
            title: "图片",
            views: [locationRow, formatRow]
        )

        // --- 截图 ---
        selectionMagnifierCheckbox = makeCheckbox(
            title: "启用选区放大镜与取色",
            action: #selector(toggleSelectionMagnifier)
        )
        selectionMagnifierCheckbox.state = AppPreferences.selectionMagnifierEnabled ? .on : .off
        selectionMagnifierCheckbox.identifier = NSUserInterfaceItemIdentifier("selectionMagnifierEnabled")

        let magnifierHelper = NSTextField(labelWithString: "默认关闭。开启后会实时读取鼠标附近屏幕，可能触发 macOS 屏幕捕捉提示。")
        magnifierHelper.font = .systemFont(ofSize: 11)
        magnifierHelper.textColor = .secondaryLabelColor
        magnifierHelper.lineBreakMode = .byWordWrapping
        magnifierHelper.maximumNumberOfLines = 2

        let captureSection = makeSection(
            title: "截图",
            views: [selectionMagnifierCheckbox, magnifierHelper]
        )

        // --- 延时截图 ---
        selfTimerDurationLabel = NSTextField(labelWithString: "\(SelfTimerPreferences.durationSeconds()) 秒")
        selfTimerDurationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        selfTimerDurationLabel.alignment = .right
        selfTimerDurationLabel.identifier = NSUserInterfaceItemIdentifier("selfTimerDurationValue")
        selfTimerDurationLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        selfTimerDurationStepper = NSStepper()
        selfTimerDurationStepper.minValue = Double(SelfTimerPreferences.durationRange.lowerBound)
        selfTimerDurationStepper.maxValue = Double(SelfTimerPreferences.durationRange.upperBound)
        selfTimerDurationStepper.increment = 1
        selfTimerDurationStepper.integerValue = SelfTimerPreferences.durationSeconds()
        selfTimerDurationStepper.target = self
        selfTimerDurationStepper.action = #selector(changeSelfTimerDuration)
        selfTimerDurationStepper.identifier = NSUserInterfaceItemIdentifier("selfTimerDurationStepper")
        let durationRow = makeRow(
            label: "倒计时时长",
            trailingViews: [selfTimerDurationLabel, selfTimerDurationStepper]
        )

        selfTimerTickCheckbox = makeCheckbox(
            title: "播放倒计时提示音",
            action: #selector(toggleSelfTimerTickSound)
        )
        selfTimerTickCheckbox.state = SelfTimerPreferences.playsTickSound() ? .on : .off
        selfTimerTickCheckbox.identifier = NSUserInterfaceItemIdentifier("selfTimerTickSound")
        let selfTimerSection = makeSection(
            title: "延时截图",
            views: [durationRow, selfTimerTickCheckbox]
        )

        // --- 快捷键 ---
        let shortcutGroups = makeShortcutGroups()
        let shortcutSection = makeSection(title: "快捷键", views: [shortcutGroups])

        // --- Note ---
        let note = NSTextField(labelWithString: "快捷键必须包含 ⌘、⌃ 或 ⌥；重复或已被系统占用的组合不会保存。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // --- Assemble ---
        let outerStack = NSStackView(views: [
            generalSection,
            imageSection,
            captureSection,
            selfTimerSection,
            shortcutSection,
            note
        ])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 22
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedPreferencesView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(outerStack)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            outerStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            outerStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            outerStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            outerStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
    }

    // MARK: - Layout helpers

    private func makeSection(title: String, views: [NSView]) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .controlAccentColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        views.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeRow(label: String, trailingViews: [NSView]) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let trailing = NSStackView(views: trailingViews)
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [labelField, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 86).isActive = true
        return row
    }

    private func makeShortcutGroups() -> NSStackView {
        let captureGroup = makeShortcutGroup(
            title: "截图与录制",
            identifier: "shortcutGroup.capture",
            actions: [.capture, .fullscreenCapture, .delayedCapture, .longCapture, .recording]
        )
        let pinGroup = makeShortcutGroup(
            title: "贴图",
            identifier: "shortcutGroup.pin",
            actions: [.pinClipboard, .pinLibrary, .togglePins]
        )
        let groups = NSStackView(views: [captureGroup, pinGroup])
        groups.orientation = .horizontal
        groups.alignment = .top
        groups.distribution = .fillEqually
        groups.spacing = 16
        groups.translatesAutoresizingMaskIntoConstraints = false
        groups.identifier = NSUserInterfaceItemIdentifier("shortcutGroups")
        pinGroup.heightAnchor.constraint(equalTo: captureGroup.heightAnchor).isActive = true
        return groups
    }

    private func makeShortcutGroup(
        title: String,
        identifier: String,
        actions: [ShortcutAction]
    ) -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        card.layer?.masksToBounds = true
        card.identifier = NSUserInterfaceItemIdentifier(identifier)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.identifier = NSUserInterfaceItemIdentifier("\(identifier).heading")
        heading.setContentCompressionResistancePriority(.required, for: .vertical)
        heading.heightAnchor.constraint(greaterThanOrEqualToConstant: 17).isActive = true

        let rows = actions.compactMap { action -> NSView? in
            guard let recorderButton = recorderButtons[action] else { return nil }
            let label = NSTextField(labelWithString: action.title)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            recorderButton.translatesAutoresizingMaskIntoConstraints = false
            recorderButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
            recorderButton.heightAnchor.constraint(equalToConstant: 27).isActive = true

            let row = NSStackView(views: [label, recorderButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        let content = NSStackView(views: [heading] + rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(12, after: heading)
        content.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
            card.heightAnchor.constraint(equalToConstant: 236)
        ])
        return card
    }

    private func makeCheckbox(title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = title
        button.setButtonType(.switch)
        button.target = self
        button.action = action
        return button
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        AppPreferences.launchAtLogin = launchAtLoginCheckbox.state == .on
    }

    @objc private func toggleTranslation() {
        let enabled = translationCheckbox.state == .on
        TranslationPreferences.setEnabled(enabled)
        onTranslationToggle(enabled)
    }

    @objc private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppPreferences.saveLocation
        if panel.runModal() == .OK, let url = panel.url {
            AppPreferences.saveLocation = url
            saveLocationLabel.stringValue = url.path
        }
    }

    @objc private func changeImageFormat() {
        guard let title = formatPopUp.titleOfSelectedItem,
              let format = AppPreferences.ImageFormat.allCases.first(where: { $0.displayName == title }) else { return }
        AppPreferences.imageFormat = format
    }

    @objc private func toggleSelectionMagnifier() {
        AppPreferences.selectionMagnifierEnabled = selectionMagnifierCheckbox.state == .on
    }

    @objc private func changeSelfTimerDuration() {
        let duration = selfTimerDurationStepper.integerValue
        SelfTimerPreferences.setDurationSeconds(duration)
        selfTimerDurationLabel.stringValue = "\(duration) 秒"
    }

    @objc private func toggleSelfTimerTickSound() {
        SelfTimerPreferences.setPlaysTickSound(selfTimerTickCheckbox.state == .on)
    }

    private func stopRecording(except activeButton: ShortcutRecorderButton?) {
        for button in recorderButtons.values where button !== activeButton {
            button.stopRecording()
        }
    }
}

private final class FlippedPreferencesView: NSView {
    override var isFlipped: Bool { true }
}

final class WatermarkSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var watermarkCheckbox: NSButton!
    private var watermarkContentHintLabel: NSTextField!
    private var watermarkTextField: NSTextField!
    private var watermarkLogoLabel: NSTextField!
    private var watermarkRepeatModePopUp: NSPopUpButton!
    private var watermarkPositionPopUp: NSPopUpButton!
    private var watermarkOpacityLabel: NSTextField!
    private var watermarkOpacitySlider: NSSlider!
    private var watermarkScaleLabel: NSTextField!
    private var watermarkScaleSlider: NSSlider!
    private var watermarkMarginLabel: NSTextField!
    private var watermarkMarginStepper: NSStepper!
    private var watermarkColorWell: NSColorWell!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "水印设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        changeWatermarkText()
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else { return }
        let watermarkConfig = WatermarkPreferences.load()
        watermarkCheckbox = makeCheckbox(
            title: "启用截图水印",
            action: #selector(toggleWatermarkEnabled)
        )
        watermarkCheckbox.state = watermarkConfig.isEnabled ? .on : .off
        watermarkContentHintLabel = makeHelperLabel("")
        updateWatermarkContentHint(for: watermarkConfig)

        watermarkTextField = NSTextField(string: watermarkConfig.text)
        watermarkTextField.placeholderString = "例如：SnapInk {datetime}"
        watermarkTextField.target = self
        watermarkTextField.action = #selector(changeWatermarkText)
        watermarkTextField.delegate = self
        watermarkTextField.translatesAutoresizingMaskIntoConstraints = false
        watermarkTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let textHelper = makeHelperLabel("可使用 {date}、{time}、{datetime}")
        let textGroup = makeFieldGroup(rows: [
            makeRow(label: "文字", trailingViews: [watermarkTextField]),
            makeIndentedView(textHelper)
        ])

        watermarkLogoLabel = NSTextField(labelWithString: watermarkLogoDisplayName(from: watermarkConfig))
        watermarkLogoLabel.font = .systemFont(ofSize: 12)
        watermarkLogoLabel.textColor = .secondaryLabelColor
        watermarkLogoLabel.lineBreakMode = .byTruncatingMiddle
        watermarkLogoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        watermarkLogoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseLogoButton = NSButton(title: "选择…", target: self, action: #selector(chooseWatermarkLogo))
        chooseLogoButton.bezelStyle = .rounded
        let removeLogoButton = NSButton(title: "移除", target: self, action: #selector(removeWatermarkLogo))
        removeLogoButton.bezelStyle = .rounded
        let logoRow = makeRow(
            label: "Logo",
            trailingViews: [watermarkLogoLabel, chooseLogoButton, removeLogoButton]
        )
        let logoHelper = makeHelperLabel("支持 PNG/JPG/HEIC，小于 3MB；导入后会自动优化为安全副本")
        let logoGroup = makeFieldGroup(rows: [
            logoRow,
            makeIndentedView(logoHelper)
        ])

        watermarkRepeatModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        WatermarkConfiguration.RepeatMode.allCases.forEach { repeatMode in
            watermarkRepeatModePopUp.addItem(withTitle: repeatMode.title)
            watermarkRepeatModePopUp.lastItem?.representedObject = repeatMode.rawValue
        }
        watermarkRepeatModePopUp.selectItem(withTitle: watermarkConfig.repeatMode.title)
        watermarkRepeatModePopUp.target = self
        watermarkRepeatModePopUp.action = #selector(changeWatermarkRepeatMode)
        let repeatModeRow = makeRow(label: "重复方式", trailingViews: [watermarkRepeatModePopUp])

        watermarkPositionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        WatermarkConfiguration.Position.allCases.forEach { position in
            watermarkPositionPopUp.addItem(withTitle: position.title)
            watermarkPositionPopUp.lastItem?.representedObject = position.rawValue
        }
        watermarkPositionPopUp.selectItem(withTitle: watermarkConfig.position.title)
        watermarkPositionPopUp.target = self
        watermarkPositionPopUp.action = #selector(changeWatermarkPosition)
        watermarkPositionPopUp.isEnabled = watermarkConfig.repeatMode == .single
        let positionRow = makeRow(label: "位置", trailingViews: [watermarkPositionPopUp])

        watermarkOpacityLabel = makeValueLabel("\(Int(watermarkConfig.opacity * 100))%", width: 42)
        watermarkOpacitySlider = NSSlider(
            value: Double(watermarkConfig.opacity),
            minValue: 0.1,
            maxValue: 1,
            target: self,
            action: #selector(changeWatermarkOpacity)
        )
        watermarkOpacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let opacityRow = makeRow(label: "透明度", trailingViews: [watermarkOpacitySlider, watermarkOpacityLabel])

        watermarkScaleLabel = makeValueLabel("\(Int(watermarkConfig.scale * 100))%", width: 42)
        watermarkScaleSlider = NSSlider(
            value: Double(watermarkConfig.scale),
            minValue: 0.5,
            maxValue: 2,
            target: self,
            action: #selector(changeWatermarkScale)
        )
        watermarkScaleSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let scaleRow = makeRow(label: "大小", trailingViews: [watermarkScaleSlider, watermarkScaleLabel])

        watermarkMarginLabel = makeValueLabel("\(Int(watermarkConfig.margin)) pt", width: 52)
        watermarkMarginStepper = NSStepper()
        watermarkMarginStepper.minValue = 0
        watermarkMarginStepper.maxValue = 80
        watermarkMarginStepper.increment = 2
        watermarkMarginStepper.doubleValue = Double(watermarkConfig.margin)
        watermarkMarginStepper.target = self
        watermarkMarginStepper.action = #selector(changeWatermarkMargin)
        let marginRow = makeRow(label: "边距", trailingViews: [watermarkMarginLabel, watermarkMarginStepper])

        watermarkColorWell = NSColorWell()
        watermarkColorWell.color = watermarkConfig.textColor
        watermarkColorWell.target = self
        watermarkColorWell.action = #selector(changeWatermarkColor)
        let colorRow = makeRow(label: "文字颜色", trailingViews: [watermarkColorWell])

        let section = makeSection(
            title: "水印",
            views: [
                watermarkCheckbox,
                makeIndentedView(watermarkContentHintLabel, indentation: 18),
                textGroup,
                logoGroup,
                repeatModeRow,
                positionRow,
                opacityRow,
                scaleRow,
                marginRow,
                colorRow
            ]
        )
        section.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            section.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            section.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            section.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    private func makeSection(title: String, views: [NSView]) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .controlAccentColor

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        views.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        header.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeRow(label: String, trailingViews: [NSView]) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let trailing = NSStackView(views: trailingViews)
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelField, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        labelField.widthAnchor.constraint(equalToConstant: 86).isActive = true
        return row
    }

    private func makeFieldGroup(rows: [NSView]) -> NSStackView {
        let group = NSStackView(views: rows)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        rows.forEach { $0.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        return group
    }

    private func makeIndentedView(_ view: NSView, indentation: CGFloat = 102) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: indentation).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        return row
    }

    private func makeHelperLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeCheckbox(title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = title
        button.setButtonType(.switch)
        button.target = self
        button.action = action
        return button
    }

    private func makeValueLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    @objc private func toggleWatermarkEnabled() {
        let wasEnabled = applyWatermarkEnabledState(watermarkCheckbox.state == .on)
        if watermarkCheckbox.state == .on, !wasEnabled {
            showError(title: "无法启用水印", message: "请先填写水印文字或选择 Logo。")
        }
    }

    @discardableResult
    func applyWatermarkEnabledState(_ enabled: Bool) -> Bool {
        var config = currentWatermarkConfiguration()
        if enabled, !config.hasRenderableContent {
            config.isEnabled = false
            watermarkCheckbox.state = .off
            WatermarkPreferences.save(config)
            updateWatermarkContentHint(for: config)
            return false
        }
        config.isEnabled = enabled
        watermarkCheckbox.state = enabled ? .on : .off
        WatermarkPreferences.save(config)
        updateWatermarkContentHint(for: config)
        return true
    }

    @objc private func changeWatermarkText() {
        var config = currentWatermarkConfiguration()
        config.text = watermarkTextField.stringValue
        if config.isEnabled, !config.hasRenderableContent {
            config.isEnabled = false
            watermarkCheckbox.state = .off
        }
        WatermarkPreferences.save(config)
        updateWatermarkContentHint(for: config)
    }

    @objc private func chooseWatermarkLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                var config = currentWatermarkConfiguration()
                let oldLogo = config.logoURL
                config.logoURL = try WatermarkPreferences.importLogo(from: url)
                config.logoDisplayName = url.lastPathComponent
                WatermarkPreferences.removeLogoFileIfManaged(oldLogo)
                WatermarkPreferences.save(config)
                watermarkLogoLabel.stringValue = watermarkLogoDisplayName(from: config)
                updateWatermarkContentHint(for: config)
            } catch {
                showError(title: "水印图片无效", message: error.localizedDescription)
            }
        }
    }

    @objc private func removeWatermarkLogo() {
        var config = currentWatermarkConfiguration()
        WatermarkPreferences.removeLogoFileIfManaged(config.logoURL)
        config.logoURL = nil
        config.logoDisplayName = nil
        if !config.hasRenderableContent {
            config.isEnabled = false
            watermarkCheckbox.state = .off
        }
        WatermarkPreferences.save(config)
        watermarkLogoLabel.stringValue = "未选择"
        updateWatermarkContentHint(for: config)
    }

    @objc private func changeWatermarkPosition() {
        guard let rawValue = watermarkPositionPopUp.selectedItem?.representedObject as? String,
              let position = WatermarkConfiguration.Position(rawValue: rawValue) else { return }
        var config = currentWatermarkConfiguration()
        config.position = position
        WatermarkPreferences.save(config)
    }

    @objc private func changeWatermarkRepeatMode() {
        let config = currentWatermarkConfiguration()
        watermarkPositionPopUp.isEnabled = config.repeatMode == .single
        WatermarkPreferences.save(config)
    }

    @objc private func changeWatermarkOpacity() {
        var config = currentWatermarkConfiguration()
        config.opacity = CGFloat(watermarkOpacitySlider.doubleValue)
        watermarkOpacityLabel.stringValue = "\(Int(config.opacity * 100))%"
        WatermarkPreferences.save(config)
    }

    @objc private func changeWatermarkScale() {
        var config = currentWatermarkConfiguration()
        config.scale = CGFloat(watermarkScaleSlider.doubleValue)
        watermarkScaleLabel.stringValue = "\(Int(config.scale * 100))%"
        WatermarkPreferences.save(config)
    }

    @objc private func changeWatermarkMargin() {
        var config = currentWatermarkConfiguration()
        config.margin = CGFloat(watermarkMarginStepper.doubleValue)
        watermarkMarginLabel.stringValue = "\(Int(config.margin)) pt"
        WatermarkPreferences.save(config)
    }

    @objc private func changeWatermarkColor() {
        var config = currentWatermarkConfiguration()
        config.textColor = watermarkColorWell.color
        WatermarkPreferences.save(config)
    }

    private func currentWatermarkConfiguration() -> WatermarkConfiguration {
        var config = WatermarkPreferences.load()
        config.isEnabled = watermarkCheckbox.state == .on
        config.text = watermarkTextField.stringValue
        if let rawValue = watermarkRepeatModePopUp.selectedItem?.representedObject as? String,
           let repeatMode = WatermarkConfiguration.RepeatMode(rawValue: rawValue) {
            config.repeatMode = repeatMode
        }
        if let rawValue = watermarkPositionPopUp.selectedItem?.representedObject as? String,
           let position = WatermarkConfiguration.Position(rawValue: rawValue) {
            config.position = position
        }
        config.opacity = CGFloat(watermarkOpacitySlider.doubleValue)
        config.scale = CGFloat(watermarkScaleSlider.doubleValue)
        config.margin = CGFloat(watermarkMarginStepper.doubleValue)
        config.textColor = watermarkColorWell.color
        return config
    }

    private func watermarkLogoDisplayName(from config: WatermarkConfiguration) -> String {
        config.logoURL == nil ? "未选择" : (config.logoDisplayName ?? config.logoURL?.lastPathComponent ?? "已选择")
    }

    private func updateWatermarkContentHint(for config: WatermarkConfiguration) {
        if config.hasRenderableContent {
            watermarkContentHintLabel.stringValue = "已配置水印内容，截图工具栏会显示水印按钮。"
            watermarkContentHintLabel.textColor = .secondaryLabelColor
        } else {
            watermarkContentHintLabel.stringValue = "请先填写文字或选择 Logo，否则无法启用水印，截图工具栏也不会显示水印按钮。"
            watermarkContentHintLabel.textColor = .systemOrange
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === watermarkTextField {
            changeWatermarkText()
        }
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onShortcutChange: ((KeyboardShortcut) -> Void)?
    var onRecordingStarted: (() -> Void)?

    private var shortcut: KeyboardShortcut
    private var keyMonitor: Any?

    init(shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        setButtonType(.momentaryPushIn)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setShortcut(_ shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
        updateTitle()
    }

    @objc private func startRecording() {
        guard keyMonitor == nil else { return }
        onRecordingStarted?()
        title = "输入新快捷键…"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        updateTitle()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        guard let shortcut = KeyboardShortcut(event: event) else {
            NSSound.beep()
            return
        }

        self.shortcut = shortcut
        stopRecording()
        onShortcutChange?(shortcut)
    }

    private func updateTitle() {
        title = shortcut.displayText
    }
}

enum CaptureAction {
    case copy
    case saveToDownloads
    case pin
}

struct CaptureOutputOptions {
    var watermarkConfiguration: WatermarkConfiguration?
    var capturedAt: Date = Date()

    static var noWatermark: CaptureOutputOptions {
        CaptureOutputOptions(watermarkConfiguration: nil, capturedAt: Date())
    }

    static var currentWatermark: CaptureOutputOptions {
        let configuration = WatermarkPreferences.load()
        return CaptureOutputOptions(
            watermarkConfiguration: configuration.isEnabled ? configuration : nil,
            capturedAt: Date()
        )
    }
}

enum OCRSource {
    case globalRect(CGRect)
    case image(CGImage)
}

enum CaptureScreenGeometry {
    static func targetIndex(at point: CGPoint, frames: [CGRect], fallbackIndex: Int? = nil) -> Int? {
        frames.firstIndex(where: { $0.contains(point) }) ?? fallbackIndex ?? frames.indices.first
    }

    @MainActor
    static func targetScreen(at point: CGPoint, screens: [NSScreen], fallback: NSScreen?) -> NSScreen? {
        if let screen = screens.first(where: { $0.frame.contains(point) }) { return screen }
        return fallback ?? screens.first
    }

    @MainActor
    static func targetScreen(for rect: CGRect, screens: [NSScreen]) -> NSScreen? {
        if let containing = screens.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) {
            return containing
        }
        return screens
            .map { ($0, $0.frame.intersection(rect).area) }
            .filter { $0.1 > 0 }
            .max(by: { $0.1 < $1.1 })?.0
    }

    static func localRect(_ globalRect: CGRect, in screenFrame: CGRect) -> CGRect {
        globalRect.intersection(screenFrame).offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).integral
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : width * height }
}

@MainActor
final class CaptureController {
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var preCapturedScreens: [(screen: NSScreen, image: CGImage, scale: CGFloat)] = []
    private var isRequestingScreenCapturePermission = false
    private var isPreparingLongCapture = false
    private var longCaptureSession: LongCaptureSessionController?
    private var longCapturePreview: LongCapturePreviewWindowController?
    private var recordingSession: RecordingSessionController?
    private var recordingPreview: RecordingPreviewWindowController?
    private var recordingExportProgress: RecordingExportProgressWindowController?
    private var isExportingRecording = false
    private var selfTimerCountdown: SelfTimerCountdownController?
    private let textRecognizer: any TextRecognizing
    private var ocrResultWindowController: OCRResultWindowController?
    private var isTranslationEnabled = TranslationPreferences.isEnabled()

    init(textRecognizer: any TextRecognizing = VisionTextRecognizer()) {
        self.textRecognizer = textRecognizer
    }

    func setTranslationEnabled(_ enabled: Bool) {
        guard isTranslationEnabled != enabled else { return }
        isTranslationEnabled = enabled
        guard let existing = ocrResultWindowController else { return }
        let currentText = existing.text
        let wasVisible = existing.window?.isVisible == true
        let topLeft = existing.window.map { CGPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        existing.close()
        ocrResultWindowController = nil

        guard wasVisible else { return }
        let replacement = makeOCRResultWindow(text: currentText)
        ocrResultWindowController = replacement
        if let topLeft {
            replacement.window?.setFrameTopLeftPoint(topLeft)
        }
        replacement.showWindow(nil)
        replacement.window?.makeKeyAndOrderFront(nil)
    }

    func beginSelectionCapture() {
        guard canBeginCaptureFlow else { NSSound.beep(); return }
        requestScreenCapturePermission { [weak self] in
            self?.preCaptureAndPresentOverlays()
        }
    }

    func beginFullscreenCapture() {
        guard canBeginCaptureFlow else { NSSound.beep(); return }
        requestScreenCapturePermission { [weak self] in
            guard let self else { return }
            self.preCaptureScreens()
            self.presentFullscreenOverlay()
        }
    }

    func beginDelayedCapture() {
        guard canBeginCaptureFlow else { NSSound.beep(); return }
        requestScreenCapturePermission { [weak self] in
            self?.preCaptureAndPresentDelayedOverlays()
        }
    }

    func cancelTransientCapture() {
        selfTimerCountdown?.dismiss()
        selfTimerCountdown = nil
        closeOverlays()
    }

    private var canBeginCaptureFlow: Bool {
        overlayWindows.isEmpty && selfTimerCountdown == nil &&
            recordingSession == nil && !isExportingRecording &&
            longCaptureSession == nil && !isPreparingLongCapture
    }

    private func preCaptureAndPresentOverlays() {
        // Capso-style freeze: wait for the global hotkey event to settle, then
        // synchronously capture the display before any overlay becomes key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.preCaptureScreens()
            self.presentSelectionOverlays()
        }
    }

    private func preCaptureAndPresentDelayedOverlays() {
        // Match the regular area capture timing so self-timer selection also
        // freezes from the real desktop after the hotkey has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.preCaptureScreens()
            self.presentDelayedCaptureOverlays()
        }
    }

    /// Capture each screen synchronously before the overlay appears so
    /// transient UI like menus, popovers, and hover states are preserved.
    /// Uses a synchronous CoreGraphics display snapshot first instead of
    /// ScreenCaptureKit (async) to reduce the chance of macOS showing the
    /// capture banner.
    private func preCaptureScreens() {
        preCapturedScreens.removeAll()
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard let cgImage = DisplaySnapshotCapturer.captureDisplay(displayID) else { continue }
            let scale = CGFloat(cgImage.width) / screen.frame.width
            preCapturedScreens.append((screen: screen, image: cgImage, scale: scale))
        }
    }

    /// Crop a region from a pre-captured full-screen image.  Returns nil
    /// if no pre-captured image covers the requested region.
    private func cropFromPreCaptured(globalRect: CGRect) -> CGImage? {
        for entry in preCapturedScreens {
            let screen = entry.screen
            guard screen.frame.intersects(globalRect) else { continue }
            let selection = globalRect.intersection(screen.frame).integral
            guard !selection.isNull, selection.width >= 1, selection.height >= 1 else { continue }
            let scale = entry.scale
            let cropRect = CGRect(
                x: (selection.minX - screen.frame.minX) * scale,
                y: (screen.frame.maxY - selection.maxY) * scale,
                width: selection.width * scale,
                height: selection.height * scale
            ).integral
            if let cropped = entry.image.cropping(to: cropRect) {
                return cropped
            }
        }
        return nil
    }

    func beginLongCapture() {
        guard canBeginCaptureFlow else {
            NSSound.beep()
            return
        }
        requestScreenCapturePermission { [weak self] in
            self?.presentLongCaptureOverlays()
        }
    }

    func beginRecordingCapture() {
        guard canBeginCaptureFlow else {
            NSSound.beep()
            return
        }
        requestScreenCapturePermission { [weak self] in
            self?.presentRecordingCaptureOverlays()
        }
    }

    private func requestScreenCapturePermission(
        then action: @escaping @MainActor () -> Void
    ) {
        guard !isRequestingScreenCapturePermission else {
            NSSound.beep()
            return
        }

        if CGPreflightScreenCaptureAccess() {
            action()
            return
        }

        isRequestingScreenCapturePermission = true
        let granted = CGRequestScreenCaptureAccess()
        isRequestingScreenCapturePermission = false

        if granted || CGPreflightScreenCaptureAccess() {
            action()
        } else {
            showPermissionAlert(error: NSError(
                domain: "SnapInk.ScreenCapturePermission",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "macOS 未授予屏幕录制权限。"
                ]
            ))
        }
    }

    private func presentSelectionOverlays() {
        closeOverlays()

        let screens = NSScreen.screens
        overlayWindows = screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen)
            configureRegularCaptureCallbacks(for: window)
            return window
        }

        // NSPanel + .nonactivatingPanel can receive mouse events and become
        // key without app activation.  Avoid setActivationPolicy/activate —
        // they cause a timing race that intermittently absorbs the first
        // mouse click (the click is consumed by the activation transition
        // instead of reaching the panel).  iShot/Xnip/Snipaste don't have
        // this problem because they don't toggle activation policy.
        // Pass pre-captured images to each overlay window (freeze screen).
        // The overlay displays the captured image as its opaque background,
        // so tooltips and other transient UI are still visible even though
        // they disappeared from the live screen.
        for window in overlayWindows {
            if let entry = preCapturedScreens.first(where: { $0.screen.frame == window.frame }) {
                window.setPreCapturedScreenImage(entry.image)
            }
        }

        overlayWindows.forEach { $0.orderFrontRegardless() }

        // On multi-display setups only one window can be key.  Make the one
        // under the cursor key so mouseMoved events are delivered reliably.
        let mouseLocation = NSEvent.mouseLocation
        for window in overlayWindows {
            if window.frame.contains(mouseLocation) {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        overlayWindows.forEach { $0.refreshCursorAfterPresentation() }
    }

    private func configureRegularCaptureCallbacks(for window: SelectionOverlayWindow) {
        window.onSelectionFinished = { [weak self] rect, action, options in
            self?.finishCapture(globalRect: rect, action: action, options: options)
        }
        window.onSelectionCancelled = { [weak self] in self?.closeOverlays() }
        window.onEditingRequested = { [weak self, weak window] rect, tool, options in
            guard let self, let window else { return }
            self.beginAnnotationEditing(globalRect: rect, tool: tool, window: window, options: options)
        }
        window.onAnnotatedFinished = { [weak self] image, action, displaySize, options in
            self?.finishAnnotatedCapture(
                image: image,
                action: action,
                displaySize: displaySize,
                options: options
            )
        }
        window.onAnnotationFailed = { [weak self] error in
            self?.showFailureAlert(message: error.localizedDescription)
        }
        window.onOCRRequested = { [weak self] source in self?.finishOCR(source: source) }
        window.onLongCaptureRequested = { [weak self] rect in self?.startLongCapture(globalRect: rect) }
        window.onRecordingRequested = { [weak self] rect, format, systemAudio, microphone, deviceID in
            self?.startRecording(
                globalRect: rect,
                format: format,
                systemAudio: systemAudio,
                microphone: microphone,
                microphoneDeviceID: deviceID
            )
        }
    }

    private func presentFullscreenOverlay() {
        closeOverlays()
        guard let screen = CaptureScreenGeometry.targetScreen(
            at: NSEvent.mouseLocation,
            screens: NSScreen.screens,
            fallback: NSScreen.main
        ), let entry = preCapturedScreens.first(where: { $0.screen.frame == screen.frame }) else {
            preCapturedScreens.removeAll()
            showFailureAlert(message: "未找到鼠标所在的显示器，无法进行全屏截图。")
            return
        }

        let window = SelectionOverlayWindow(screen: screen, allowsLiveCaptureActions: false)
        configureRegularCaptureCallbacks(for: window)
        window.setPreCapturedScreenImage(entry.image)
        window.presetSelection(CGRect(origin: .zero, size: screen.frame.size))
        overlayWindows = [window]
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.refreshCursorAfterPresentation()
    }

    private func presentDelayedCaptureOverlays() {
        closeOverlays()
        overlayWindows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen, purpose: .delayedCapture)
            window.onSelectionCancelled = { [weak self] in self?.closeOverlays() }
            window.onDelayedCaptureRequested = { [weak self] rect in self?.startSelfTimer(globalRect: rect) }
            if let entry = preCapturedScreens.first(where: { $0.screen.frame == screen.frame }) {
                window.setPreCapturedScreenImage(entry.image)
            }
            return window
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }
        let mouseLocation = NSEvent.mouseLocation
        overlayWindows.first(where: { $0.frame.contains(mouseLocation) })?.makeKeyAndOrderFront(nil)
        overlayWindows.forEach { $0.refreshCursorAfterPresentation() }
    }

    private func startSelfTimer(globalRect: CGRect) {
        guard selfTimerCountdown == nil,
              let screen = CaptureScreenGeometry.targetScreen(for: globalRect, screens: NSScreen.screens) else {
            closeOverlays()
            showFailureAlert(message: "所选区域所在的显示器已断开，请重新截图。")
            return
        }

        closeOverlays()
        preCapturedScreens.removeAll()
        selfTimerCountdown = SelfTimerCountdownController(
            selectionRect: globalRect,
            screen: screen,
            duration: SelfTimerPreferences.durationSeconds(),
            playsTickSound: SelfTimerPreferences.playsTickSound(),
            onComplete: { [weak self] in self?.finishSelfTimer(globalRect: globalRect) },
            onCancel: { [weak self] in self?.selfTimerCountdown = nil }
        )
    }

    private func finishSelfTimer(globalRect: CGRect) {
        selfTimerCountdown = nil
        preCaptureScreens()
        guard let screen = CaptureScreenGeometry.targetScreen(for: globalRect, screens: NSScreen.screens),
              let entry = preCapturedScreens.first(where: { $0.screen.frame == screen.frame }) else {
            preCapturedScreens.removeAll()
            showFailureAlert(message: "延时截图区域已失效，可能是显示器配置发生了变化。")
            return
        }

        let localRect = CaptureScreenGeometry.localRect(globalRect, in: screen.frame)
        guard localRect.width >= 2, localRect.height >= 2 else {
            preCapturedScreens.removeAll()
            showFailureAlert(message: "延时截图区域无效，请重新选择。")
            return
        }
        let window = SelectionOverlayWindow(screen: screen, allowsLiveCaptureActions: false)
        configureRegularCaptureCallbacks(for: window)
        window.setPreCapturedScreenImage(entry.image)
        window.presetSelection(localRect)
        overlayWindows = [window]
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.refreshCursorAfterPresentation()
    }

    private func presentLongCaptureOverlays() {
        closeOverlays()
        overlayWindows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen, purpose: .longCapture)
            window.onSelectionCancelled = { [weak self] in
                self?.closeOverlays()
            }
            window.onLongCaptureRequested = { [weak self] rect in
                self?.startLongCapture(globalRect: rect)
            }
            return window
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }

        let mouseLocation = NSEvent.mouseLocation
        for window in overlayWindows {
            if window.frame.contains(mouseLocation) {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        overlayWindows.forEach { $0.refreshCursorAfterPresentation() }
    }

    private func presentRecordingCaptureOverlays() {
        closeOverlays()
        overlayWindows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen, purpose: .recording)
            window.onSelectionCancelled = { [weak self] in
                self?.closeOverlays()
            }
            window.onRecordingRequested = { [weak self] rect, format, systemAudio, microphone, deviceID in
                self?.startRecording(
                    globalRect: rect,
                    format: format,
                    systemAudio: systemAudio,
                    microphone: microphone,
                    microphoneDeviceID: deviceID
                )
            }
            return window
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }

        let mouseLocation = NSEvent.mouseLocation
        for window in overlayWindows {
            if window.frame.contains(mouseLocation) {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        overlayWindows.forEach { $0.refreshCursorAfterPresentation() }
    }

    private func startLongCapture(globalRect: CGRect) {
        guard !isPreparingLongCapture, longCaptureSession == nil else { return }
        isPreparingLongCapture = true
        closeOverlays()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(90))
                let capturer = try await ScreenRegionCapturer(globalRect: globalRect)
                let firstFrame = try await capturer.capture()
                let session = try LongCaptureSessionController(
                    selectionRect: globalRect,
                    firstFrame: firstFrame,
                    captureFrame: {
                        await capturer.prepareForOverlayExclusion()
                        return try await capturer.capture()
                    },
                    onFinish: { [weak self] image, logicalWidth in
                        guard let self else { return }
                        self.longCaptureSession = nil
                        self.showLongCapturePreview(image: image, logicalWidth: logicalWidth)
                    },
                    onCancel: { [weak self] in
                        self?.longCaptureSession = nil
                    },
                    onError: { [weak self] error in
                        self?.longCaptureSession = nil
                        self?.showFailureAlert(message: error.localizedDescription)
                    }
                )
                isPreparingLongCapture = false
                longCaptureSession = session
                session.start()
                await capturer.prepareForOverlayExclusion()
            } catch {
                isPreparingLongCapture = false
                showFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func startRecording(
        globalRect: CGRect,
        format: RecordingFormat,
        systemAudio: Bool,
        microphone: Bool,
        microphoneDeviceID: String?
    ) {
        guard recordingSession == nil, !isExportingRecording else { return }
        closeOverlays()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(90))
                let capturer = try await ScreenRegionCapturer(globalRect: globalRect)
                let session = RecordingSessionController(
                    selectionRect: globalRect,
                    capturer: capturer,
                    configuration: RecordingConfiguration(
                        format: format,
                        fps: 30,
                        capturesSystemAudio: format == .video && systemAudio,
                        capturesMicrophone: format == .video && microphone,
                        microphoneDeviceID: microphoneDeviceID,
                        showsCursor: true
                    ),
                    onFinish: { [weak self] result in
                        guard let self else { return }
                        self.recordingSession = nil
                        self.finishRecording(result)
                    },
                    onCancel: { [weak self] in
                        self?.recordingSession = nil
                    },
                    onError: { [weak self] error in
                        self?.recordingSession = nil
                        self?.showFailureAlert(message: error.localizedDescription)
                    }
                )
                recordingSession = session
                session.start()
                await capturer.prepareForOverlayExclusion()
            } catch {
                showFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func finishRecording(_ result: RecordingResult) {
        isExportingRecording = true
        let progressWindow = RecordingExportProgressWindowController(format: result.format)
        recordingExportProgress = progressWindow
        progressWindow.showWindow(nil)
        progressWindow.window?.makeKeyAndOrderFront(nil)
        let exportedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapInk-Export-\(UUID().uuidString)")
            .appendingPathExtension(result.format.fileExtension)
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await RecordingExporter.export(
                    source: result.sourceURL,
                    format: result.format,
                    destination: exportedURL,
                    progress: { [weak progressWindow] stage, fraction in
                        Task { @MainActor in progressWindow?.update(stage: stage, fraction: fraction) }
                    }
                )
                try? FileManager.default.removeItem(at: result.sourceURL)
                progressWindow.close()
                self.recordingExportProgress = nil
                let preview = RecordingPreviewWindowController(
                    fileURL: url,
                    format: result.format,
                    duration: result.duration,
                    pixelSize: result.pixelSize,
                    onClose: { [weak self] in self?.recordingPreview = nil }
                )
                self.recordingPreview?.close()
                self.recordingPreview = preview
                self.isExportingRecording = false
                preview.showWindow(nil)
                preview.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                self.isExportingRecording = false
                progressWindow.close()
                self.recordingExportProgress = nil
                try? FileManager.default.removeItem(at: result.sourceURL)
                try? FileManager.default.removeItem(at: exportedURL)
                self.showFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func showLongCapturePreview(image: CGImage, logicalWidth: CGFloat) {
        longCapturePreview?.close()
        let preview = LongCapturePreviewWindowController(
            image: image,
            logicalWidth: logicalWidth,
            onOCR: { [weak self] image, completion in
                guard let self else {
                    completion()
                    return
                }
                self.finishOCR(source: .image(image), completion: completion)
            },
            onDismiss: { [weak self] in
                self?.longCapturePreview = nil
            }
        )
        longCapturePreview = preview
        preview.showWindow(nil)
    }

    private func finishCapture(globalRect: CGRect, action: CaptureAction, options: CaptureOutputOptions) {
        closeOverlays()

        guard globalRect.width >= 2, globalRect.height >= 2 else {
            preCapturedScreens.removeAll()
            return
        }

        // Use the frozen image if available (preserves menus, popovers, and
        // other transient UI that disappeared when the overlay appeared).
        if let cropped = cropFromPreCaptured(globalRect: globalRect) {
            preCapturedScreens.removeAll()
            do {
                try output(cropped, action: action, pinDisplaySize: globalRect.size, options: options)
            } catch {
                showFailureAlert(message: error.localizedDescription)
            }
            return
        }

        NSLog("SnapInk: finishCapture fallback - preCapture empty")
        preCapturedScreens.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.preCaptureScreens()
            if let cropped = self.cropFromPreCaptured(globalRect: globalRect) {
                do {
                    try self.output(cropped, action: action, pinDisplaySize: globalRect.size, options: options)
                } catch {
                    self.showFailureAlert(message: error.localizedDescription)
                }
                return
            }
            self.showFailureAlert(message: "截图失败：无法通过同步冻结画面获取所选区域。请确认屏幕录制权限已开启后重试。")
        }
    }

    private func beginAnnotationEditing(
        globalRect: CGRect,
        tool: AnnotationTool,
        window: SelectionOverlayWindow,
        options: CaptureOutputOptions
    ) {
        // Use the frozen image if available.
        if let image = cropFromPreCaptured(globalRect: window.frame) {
            preCapturedScreens.removeAll()
            window.enterAnnotationEditing(baseImage: image, initialTool: tool, outputOptions: options)
            return
        }

        window.annotationEditingDidFail()
        showFailureAlert(message: "无法进入标注：没有可用的同步冻结截图。请重新截图。")
    }

    private func finishAnnotatedCapture(
        image: CGImage,
        action: CaptureAction,
        displaySize: CGSize,
        options: CaptureOutputOptions
    ) {
        closeOverlays()
        do {
            try output(image, action: action, pinDisplaySize: displaySize, options: options)
        } catch {
            showFailureAlert(message: error.localizedDescription)
        }
    }

    private func finishOCR(source: OCRSource, completion: (() -> Void)? = nil) {
        closeOverlays()

        Task { [weak self] in
            guard let self else {
                completion?()
                return
            }
            defer { completion?() }
            do {
                let image: CGImage
                switch source {
                case .globalRect(let rect):
                    if let preCaptured = cropFromPreCaptured(globalRect: rect) {
                        image = preCaptured
                    } else {
                        throw NSError(
                            domain: "SnapInk.OCR",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "无法读取同步冻结截图，已取消 OCR。请重新截图后再试。"
                            ]
                        )
                    }
                case .image(let sourceImage):
                    image = sourceImage
                }

                let result = try await textRecognizer.recognizeText(in: image)
                showOCRResult(result.text)
            } catch OCRRecognitionError.noText {
                showNoTextAlert()
            } catch {
                showOCRFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func showOCRResult(_ text: String) {
        let isNewWindow = ocrResultWindowController == nil
        if let controller = ocrResultWindowController {
            controller.setText(text)
        } else {
            ocrResultWindowController = makeOCRResultWindow(text: text)
        }

        guard let controller = ocrResultWindowController else { return }
        if isNewWindow {
            controller.window?.center()
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeOCRResultWindow(text: String) -> OCRResultWindowController {
        OCRResultWindowController(
            text: text,
            translationProvider: isTranslationEnabled ? .system : .unavailable
        )
    }

    private func showNoTextAlert() {
        let alert = NSAlert()
        alert.messageText = "未识别到文字"
        alert.informativeText = "当前区域未识别到文字。"
        alert.runModal()
    }

    private func showOCRFailureAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "文字识别失败"
        alert.informativeText = message
        alert.runModal()
    }

    private func output(
        _ image: CGImage,
        action: CaptureAction,
        pinDisplaySize: CGSize? = nil,
        options: CaptureOutputOptions = .currentWatermark
    ) throws {
        let image = try finalImage(from: image, options: options)
        switch action {
        case .copy:
            try ScreenshotWriter.copyToPasteboard(image)
            NSSound(named: "Tink")?.play()
        case .saveToDownloads:
            let url = try ScreenshotWriter.writeImage(image)
            NSSound(named: "Glass")?.play()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .pin:
            _ = try PinManager.shared.pin(image, displaySize: pinDisplaySize)
            NSSound(named: "Tink")?.play()
        }
    }

    private func finalImage(from image: CGImage, options: CaptureOutputOptions) throws -> CGImage {
        guard let configuration = options.watermarkConfiguration else { return image }
        return try WatermarkRenderer.render(
            image: image,
            configuration: configuration,
            context: WatermarkContext(capturedAt: options.capturedAt)
        )
    }

    private func closeOverlays() {
        let windowsToClose = overlayWindows
        overlayWindows.removeAll()

        // A toolbar action is delivered by a view inside one of these windows.
        // Closing and releasing every overlay synchronously from that action can
        // race AppKit's window transform transaction. Hide immediately so the
        // overlays are absent from the screenshot, then close after the current
        // event and Core Animation transaction have completed.
        windowsToClose.forEach { window in
            window.onSelectionFinished = nil
            window.onSelectionCancelled = nil
            window.onEditingRequested = nil
            window.onAnnotatedFinished = nil
            window.onAnnotationFailed = nil
            window.onOCRRequested = nil
            window.onLongCaptureRequested = nil
            window.onRecordingRequested = nil
            window.onDelayedCaptureRequested = nil
            window.orderOut(nil)
        }

        // No setActivationPolicy reset needed — we never changed it from
        // .accessory.  The app stays an agent app throughout.

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            windowsToClose.forEach { $0.close() }
        }
    }

    private func showPermissionAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "SnapInk 已向 macOS 发起屏幕录制授权申请。请在“系统设置 > 隐私与安全性 > 录屏与系统录音”中开启 SnapInk，然后退出并重新打开应用。\n\n如果列表中仍没有 SnapInk，请点击列表底部的“+”，手动选择“应用程序”中的 SnapInk。\n\n系统信息：\(error.localizedDescription)"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "退出 SnapInk")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func showFailureAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = message
        alert.runModal()
    }

    private func makeCaptureError(_ message: String) -> NSError {
        NSError(
            domain: "SnapInk.Capture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum SelectionPurpose {
    case regular
    case longCapture
    case recording
    case delayedCapture
}

final class SelectionOverlayWindow: NSPanel {
    var onSelectionFinished: ((CGRect, CaptureAction, CaptureOutputOptions) -> Void)?
    var onSelectionCancelled: (() -> Void)?
    var onEditingRequested: ((CGRect, AnnotationTool, CaptureOutputOptions) -> Void)?
    var onAnnotatedFinished: ((CGImage, CaptureAction, CGSize, CaptureOutputOptions) -> Void)?
    var onAnnotationFailed: ((Error) -> Void)?
    var onOCRRequested: ((OCRSource) -> Void)?
    var onLongCaptureRequested: ((CGRect) -> Void)?
    var onRecordingRequested: ((CGRect, RecordingFormat, Bool, Bool, String?) -> Void)?
    var onDelayedCaptureRequested: ((CGRect) -> Void)?

    private var overlayView: SelectionOverlayView? {
        contentView as? SelectionOverlayView
    }

    init(
        screen: NSScreen,
        purpose: SelectionPurpose = .regular,
        allowsLiveCaptureActions: Bool = true
    ) {
        let view = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            purpose: purpose,
            allowsLiveCaptureActions: allowsLiveCaptureActions
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = view
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        isReleasedWhenClosed = false
        hasShadow = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false

        view.onSelectionFinished = { [weak self] rect, action, options in
            self?.onSelectionFinished?(rect, action, options)
        }
        view.onSelectionCancelled = { [weak self] in
            self?.onSelectionCancelled?()
        }
        view.onEditingRequested = { [weak self] rect, tool, options in
            self?.onEditingRequested?(rect, tool, options)
        }
        view.onAnnotatedFinished = { [weak self] image, action, displaySize, options in
            self?.onAnnotatedFinished?(image, action, displaySize, options)
        }
        view.onAnnotationFailed = { [weak self] error in
            self?.onAnnotationFailed?(error)
        }
        view.onOCRRequested = { [weak self] source in
            self?.onOCRRequested?(source)
        }
        view.onLongCaptureRequested = { [weak self] rect in
            self?.onLongCaptureRequested?(rect)
        }
        view.onRecordingRequested = { [weak self] rect, format, systemAudio, microphone, deviceID in
            self?.onRecordingRequested?(rect, format, systemAudio, microphone, deviceID)
        }
        view.onDelayedCaptureRequested = { [weak self] rect in
            self?.onDelayedCaptureRequested?(rect)
        }
    }

    func enterAnnotationEditing(
        baseImage: CGImage,
        initialTool: AnnotationTool,
        outputOptions: CaptureOutputOptions = .noWatermark
    ) {
        overlayView?.enterAnnotationEditing(
            baseImage: baseImage,
            initialTool: initialTool,
            outputOptions: outputOptions
        )
    }

    func annotationEditingDidFail() {
        overlayView?.annotationEditingDidFail()
    }

    func setPreCapturedScreenImage(_ image: CGImage) {
        overlayView?.setPreCapturedScreenImage(image)
    }

    func presetSelection(_ rect: CGRect) {
        overlayView?.presetSelection(rect)
    }

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        // Cursor rects are only evaluated for the key window.  When the
        // overlay first appears there is a brief moment before it becomes
        // key where the system shows the default arrow cursor.  Force the
        // selection cursor immediately and re-invalidate cursor rects.
        if let view = overlayView {
            view.refreshCursor()
            view.window?.invalidateCursorRects(for: view)
        }
    }

    func refreshCursorAfterPresentation() {
        overlayView?.refreshCursor()
        DispatchQueue.main.async { [weak self] in
            self?.overlayView?.refreshCursor()
        }
    }
}

final class SelectionOverlayView: NSView {
    private enum SelectionHandle {
        case topLeft
        case top
        case topRight
        case left
        case right
        case bottomLeft
        case bottom
        case bottomRight
    }

    private enum DragOperation {
        case selecting
        case moving
        case resizing(SelectionHandle)
    }

    var onSelectionFinished: ((CGRect, CaptureAction, CaptureOutputOptions) -> Void)?
    var onSelectionCancelled: (() -> Void)?
    var onEditingRequested: ((CGRect, AnnotationTool, CaptureOutputOptions) -> Void)?
    var onAnnotatedFinished: ((CGImage, CaptureAction, CGSize, CaptureOutputOptions) -> Void)?
    var onAnnotationFailed: ((Error) -> Void)?
    var onOCRRequested: ((OCRSource) -> Void)?
    var onLongCaptureRequested: ((CGRect) -> Void)?
    var onRecordingRequested: ((CGRect, RecordingFormat, Bool, Bool, String?) -> Void)?
    var onDelayedCaptureRequested: ((CGRect) -> Void)?

    private let purpose: SelectionPurpose
    private let allowsLiveCaptureActions: Bool
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var dragOperation: DragOperation?
    private var moveAnchorPoint: NSPoint?
    private var moveInitialRect: CGRect?
    private var resizeInitialRect: CGRect?
    private var isSelectionFinalized = false
    private var isPreselected = false
    private var preselectClickStart: CGPoint?
    private var colorSamplerLocation: CGPoint?
    private var sampledColor: NSColor?
    private var sampledScreenPosition: CGPoint?
    private var magnifierImage: CGImage?
    private var selectionGuideLocation: CGPoint?
    private var mouseTrackingTimer: Timer?
    private var lastPolledMouseLocation: CGPoint?
    private var isRecordingConfirming = false
    private var isPreparingAnnotation = false
    private var isSubmitting = false
    private var annotationCanvas: AnnotationCanvasView?
    private var annotationPreviewOptions: CaptureOutputOptions?
    private var annotatedOutputOptions: CaptureOutputOptions?
    private var selectionOutputOptions: CaptureOutputOptions?
    private var selectionWatermarkPreviewImage: CGImage?
    private var selectionWatermarkPreviewRect: CGRect?
    private var sessionWatermarkEnabled = WatermarkPreferences.load().isEnabled
    private var frozenScreenImage: CGImage?
    private var activeAnnotationTool: AnnotationTool = .select
    private var annotationStyles: [AnnotationTool: AnnotationStyle] = Dictionary(
        uniqueKeysWithValues: AnnotationTool.drawingTools.map {
            ($0, AnnotationStylePreferences.load(for: $0))
        }
    )
    private lazy var actionBar = makeActionBar()
    private lazy var longCaptureBar: LongCaptureStartBar = {
        let bar = LongCaptureStartBar(
            frame: CGRect(x: 0, y: 0, width: 430, height: 48),
            hint: "框内内容需全部能够上下滚动",
            startTitle: "开始长截图"
        )
        bar.onStart = { [weak self] in self?.requestLongCapture() }
        bar.onCancel = { [weak self] in self?.onSelectionCancelled?() }
        return bar
    }()
    private lazy var recordingBar: RecordingStartBar = {
        let bar = RecordingStartBar(frame: CGRect(x: 0, y: 0, width: 650, height: 104))
        bar.onStart = { [weak self] format, systemAudio, microphone, deviceID in
            guard let self,
                  let selection = self.currentSelection(),
                  selection.width >= 80,
                  selection.height >= 80,
                  let globalRect = self.currentGlobalSelectionRect() else {
                NSSound.beep()
                return
            }
            self.isSubmitting = true
            self.hideSelectionControls()
            self.onRecordingRequested?(globalRect, format, systemAudio, microphone, deviceID)
        }
        bar.onCancel = { [weak self] in
            guard let self else { return }
            if self.purpose == .recording {
                self.onSelectionCancelled?()
            } else if let selection = self.currentSelection() {
                self.isRecordingConfirming = false
                self.recordingBar.isHidden = true
                self.positionSelectionControls(for: selection)
            }
        }
        return bar
    }()
    private lazy var delayedCaptureBar: DelayedCaptureStartBar = {
        let bar = DelayedCaptureStartBar(
            frame: CGRect(x: 0, y: 0, width: 330, height: 48),
            duration: SelfTimerPreferences.durationSeconds()
        )
        bar.onStart = { [weak self] in self?.requestDelayedCapture() }
        bar.onCancel = { [weak self] in self?.onSelectionCancelled?() }
        return bar
    }()
    private let infoAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white
    ]
    private let handleHitHalfSize: CGFloat = 10
    private var isDrawingSyntheticSelectionCursor = false
    private var syntheticSelectionCursorLocation: CGPoint?
    private var didHideSystemCursorForSelection = false
    private static let invisibleSelectionCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    init(
        frame frameRect: NSRect,
        purpose: SelectionPurpose = .regular,
        allowsLiveCaptureActions: Bool = true
    ) {
        self.purpose = purpose
        self.allowsLiveCaptureActions = allowsLiveCaptureActions
        super.init(frame: frameRect)
        switch purpose {
        case .regular:
            addSubview(actionBar)
            actionBar.isHidden = true
            addSubview(recordingBar)
            recordingBar.isHidden = true
            updateLiveCaptureActionAvailability(for: nil)
        case .longCapture:
            addSubview(longCaptureBar)
            longCaptureBar.isHidden = true
        case .recording:
            addSubview(recordingBar)
            recordingBar.isHidden = true
        case .delayedCapture:
            addSubview(delayedCaptureBar)
            delayedCaptureBar.isHidden = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // Mirror the window-level override so the view also accepts the first
    // click when the app is not active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isSelectionFinalized, !isPreselected, selectionHandle(at: point) != nil {
            return self
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(
            bounds,
            cursor: shouldUseSyntheticSelectionCursor ? Self.invisibleSelectionCursor : .crosshair
        )
        if isSelectionFinalized, !isPreselected, let selection = currentSelection() {
            if annotationCanvas == nil {
                addCursorRect(selection, cursor: .crosshair)
            }
            for controls in visibleSelectionControls {
                addCursorRect(controls.frame, cursor: .arrow)
            }
            for (handle, point) in selectionHandlePoints(for: selection) {
                addCursorRect(
                    CGRect(
                        x: point.x - handleHitHalfSize,
                        y: point.y - handleHitHalfSize,
                        width: handleHitHalfSize * 2,
                        height: handleHitHalfSize * 2
                    ),
                    cursor: cursor(for: handle)
                )
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        // The overlay is intentionally non-activating so menus/popovers can be
        // preserved. During raw area selection AppKit may hand cursor ownership
        // back to the foreground app, so we hide the system cursor and draw a
        // SnapInk reticle until the selection is finalized.
        updateCursorAtCurrentMouseLocation()
        DispatchQueue.main.async { [weak self] in
            self?.updateCursorAtCurrentMouseLocation()
        }

        // Immediate full-screen preselection as fallback.  This does not
        // depend on mouseMoved events, so the user can always click to
        // enter annotation mode or drag to draw a new selection right
        // away — even if the timer below hasn't fired yet.
        startPoint = .zero
        currentPoint = CGPoint(x: bounds.maxX, y: bounds.maxY)
        isSelectionFinalized = true
        isPreselected = true
        needsDisplay = true

        // Start a timer that continuously polls the mouse position.
        // mouseMoved events are unreliable on non-key windows (multi-display)
        // and before the app is fully activated.  The timer refines the
        // full-screen fallback to the actual window under the cursor.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMousePosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTrackingTimer = timer
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            mouseTrackingTimer?.invalidate()
            mouseTrackingTimer = nil
            restoreSystemCursorIfNeeded()
        }
    }

    /// Timer-based fallback that polls ``NSEvent.mouseLocation`` so window
    /// detection works even when ``mouseMoved`` events are not delivered.
    private func pollMousePosition() {
        guard let window else { return }

        let mouseLocation = NSEvent.mouseLocation
        let windowPoint = window.convertFromScreen(
            CGRect(origin: mouseLocation, size: .zero)).origin
        let viewPoint = convert(windowPoint, from: nil)

        guard bounds.contains(viewPoint) else {
            restoreSystemCursorIfNeeded()
            return
        }
        updateOverlayCursor(at: viewPoint)
        guard isSelectionHoverTrackingActive else {
            clearColorSampler()
            return
        }

        // Skip if the mouse hasn't moved since the last poll.
        if let last = lastPolledMouseLocation, last == viewPoint {
            return
        }
        lastPolledMouseLocation = viewPoint

        detectWindowUnderCursor(at: viewPoint)
        updateColorSampler(at: viewPoint)
        updateOverlayCursor(at: viewPoint)
        needsDisplay = true
    }

    // MARK: - Color Sampler (iShot-style eyedropper)

    private var isSelectionHoverTrackingActive: Bool {
        guard annotationCanvas == nil,
              !isPreparingAnnotation,
              !isSubmitting,
              !isRecordingConfirming else { return false }
        if case .moving = dragOperation { return false }
        if case .resizing = dragOperation { return false }
        if isSelectionFinalized && !isPreselected { return false }
        return true
    }

    private var isColorSamplerActive: Bool {
        AppPreferences.selectionMagnifierEnabled && isSelectionHoverTrackingActive
    }

    private var visibleSelectionControls: [NSView] {
        let candidates: [NSView]
        switch purpose {
        case .regular:
            candidates = [actionBar, recordingBar]
        case .longCapture:
            candidates = [longCaptureBar]
        case .recording:
            candidates = [recordingBar]
        case .delayedCapture:
            candidates = [delayedCaptureBar]
        }
        return candidates.filter {
            $0.superview === self && !$0.isHidden
        }
    }

    private func cursor(for handle: SelectionHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            .resizeLeftRight
        case .top, .bottom:
            .resizeUpDown
        case .topLeft, .bottomRight:
            AnnotationCursorFactory.cursor(for: .resizeDiagonalDown)
        case .topRight, .bottomLeft:
            AnnotationCursorFactory.cursor(for: .resizeDiagonalUp)
        }
    }

    func refreshCursor() {
        updateCursorAtCurrentMouseLocation()
    }

    private func updateCursorAtCurrentMouseLocation() {
        guard let window else {
            restoreSystemCursorIfNeeded()
            NSCursor.crosshair.set()
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertFromScreen(CGRect(origin: screenPoint, size: .zero)).origin
        updateOverlayCursor(at: convert(windowPoint, from: nil))
    }

    private func updateOverlayCursor(at location: CGPoint) {
        guard bounds.contains(location) else {
            restoreSystemCursorIfNeeded()
            return
        }
        if visibleSelectionControls.contains(where: { $0.frame.contains(location) }) {
            restoreSystemCursorIfNeeded()
            NSCursor.arrow.set()
            return
        }
        if let handle = selectionHandle(at: location), isSelectionFinalized, !isPreselected {
            restoreSystemCursorIfNeeded()
            cursor(for: handle).set()
            return
        }
        if case .moving = dragOperation {
            restoreSystemCursorIfNeeded()
            NSCursor.closedHand.set()
            return
        }
        if let annotationCanvas, annotationCanvas.frame.contains(location) {
            restoreSystemCursorIfNeeded()
            return
        }
        if shouldUseSyntheticSelectionCursor {
            updateSyntheticSelectionCursor(at: location)
            return
        }
        restoreSystemCursorIfNeeded()
        NSCursor.crosshair.set()
    }

    private var shouldUseSyntheticSelectionCursor: Bool {
        isSelectionHoverTrackingActive
    }

    private func updateSyntheticSelectionCursor(at location: CGPoint) {
        let locationChanged = syntheticSelectionCursorLocation != location
        let wasDrawing = isDrawingSyntheticSelectionCursor

        if !didHideSystemCursorForSelection {
            NSCursor.hide()
            didHideSystemCursorForSelection = true
        }
        // During raw selection the overlay is non-activating, so AppKit and
        // the foreground app can both try to own the system cursor. Keep the
        // real cursor invisible and draw SnapInk's reticle ourselves; this
        // avoids the arrow + crosshair double-cursor artifact.
        Self.invisibleSelectionCursor.set()

        syntheticSelectionCursorLocation = location
        updateSelectionGuide(at: location)
        isDrawingSyntheticSelectionCursor = true
        if locationChanged || !wasDrawing {
            needsDisplay = true
        }
    }

    private func restoreSystemCursorIfNeeded() {
        let needsRedraw = isDrawingSyntheticSelectionCursor ||
            syntheticSelectionCursorLocation != nil ||
            selectionGuideLocation != nil
        isDrawingSyntheticSelectionCursor = false
        syntheticSelectionCursorLocation = nil
        selectionGuideLocation = nil
        if didHideSystemCursorForSelection {
            NSCursor.unhide()
            didHideSystemCursorForSelection = false
        }
        if needsRedraw {
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        updateOverlayCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Cursor rects only work for the key window.  For non-key overlay
        // windows (multi-display) or before the window becomes key, force
        // the crosshair so the user never sees an arrow.
        let location = convert(event.locationInWindow, from: nil)
        updateOverlayCursor(at: location)
        if isSelectionHoverTrackingActive {
            detectWindowUnderCursor(at: location)
            updateColorSampler(at: location)
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        restoreSystemCursorIfNeeded()
        clearColorSampler()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Keep the synthetic reticle under the real mouse location while the
        // non-activating overlay owns selection but not app activation.
        let location = convert(event.locationInWindow, from: nil)
        updateOverlayCursor(at: location)
        guard isSelectionHoverTrackingActive else {
            clearColorSampler()
            return
        }

        // iShot-style smart window detection: snap selection to the
        // window under the cursor (desktop fallback: full screen).
        detectWindowUnderCursor(at: location)
        lastPolledMouseLocation = location
        updateColorSampler(at: location)
        needsDisplay = true
    }

    private func updateColorSampler(at location: CGPoint) {
        guard isColorSamplerActive else {
            clearColorSampler()
            return
        }
        colorSamplerLocation = location
        sampleColorAtCursor()
    }

    private func clearColorSampler() {
        guard colorSamplerLocation != nil ||
              sampledColor != nil ||
              sampledScreenPosition != nil ||
              magnifierImage != nil else {
            return
        }
        colorSamplerLocation = nil
        sampledColor = nil
        sampledScreenPosition = nil
        magnifierImage = nil
        needsDisplay = true
    }

    private func updateSelectionGuide(at location: CGPoint) {
        guard isSelectionHoverTrackingActive, bounds.contains(location) else {
            clearSelectionGuide()
            return
        }
        if selectionGuideLocation != location {
            selectionGuideLocation = location
            needsDisplay = true
        }
    }

    private func clearSelectionGuide() {
        guard selectionGuideLocation != nil else { return }
        selectionGuideLocation = nil
        needsDisplay = true
    }

    /// Reads a region around the cursor from the live screen (excluding this
    /// overlay) via ``CGWindowListCreateImage``. The method is only called
    /// when the user explicitly enables the selection magnifier/color sampler.
    private func sampleColorAtCursor() {
        guard let window, let location = colorSamplerLocation else { return }

        // Convert view point → AppKit screen point → CG display point
        let windowPoint = convert(location, to: nil)
        let screenPoint = window.convertToScreen(
            CGRect(origin: windowPoint, size: .zero)
        ).origin
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenPoint.y
        let cgPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        sampledScreenPosition = cgPoint

        // Capture a small region centered on the cursor for the loupe.
        // 25 pt ≈ 50 px on a 2× Retina display → ~4.8× magnification in a
        // 120-pt box.
        let captureSize: CGFloat = 25
        let captureRect = CGRect(
            x: cgPoint.x - captureSize / 2,
            y: cgPoint.y - captureSize / 2,
            width: captureSize,
            height: captureSize
        )
        guard let cgImage = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            CGWindowID(window.windowNumber),
            []
        ) else {
            magnifierImage = nil
            sampledColor = nil
            return
        }
        magnifierImage = cgImage
        sampledColor = readCenterPixelColor(from: cgImage)
    }

    private func readCenterPixelColor(from image: CGImage) -> NSColor? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let cx = w / 2
        let cy = h / 2
        let idx = (cy * w + cx) * 4
        return NSColor(
            srgbRed:   CGFloat(pixels[idx])     / 255,
            green:     CGFloat(pixels[idx + 1]) / 255,
            blue:      CGFloat(pixels[idx + 2]) / 255,
            alpha:     1
        )
    }

    private static let chineseColorTable: [(String, Int, Int, Int)] = [
        ("白色", 255, 255, 255), ("黑色", 0, 0, 0),
        ("红色", 255, 0, 0),     ("绿色", 0, 128, 0),
        ("蓝色", 0, 0, 255),     ("黄色", 255, 255, 0),
        ("青色", 0, 255, 255),   ("紫色", 128, 0, 128),
        ("灰色", 128, 128, 128), ("橙色", 255, 165, 0),
        ("粉色", 255, 192, 203), ("棕色", 139, 69, 19),
        ("深红", 139, 0, 0),     ("深绿", 0, 100, 0),
        ("深蓝", 0, 0, 139),     ("浅蓝", 173, 216, 230),
        ("浅绿", 144, 238, 144), ("浅灰", 211, 211, 211),
        ("深灰", 69, 69, 69),    ("金黄", 255, 215, 0),
        ("银色", 192, 192, 192), ("藏青", 0, 0, 128),
        ("酒红", 128, 0, 32),    ("玫红", 255, 0, 127),
        ("天蓝", 135, 206, 235), ("米色", 245, 245, 220),
        ("卡其", 189, 183, 107), ("珊瑚", 255, 127, 80),
        ("青绿", 0, 139, 139),   ("品红", 255, 0, 255),
        ("黄绿", 154, 205, 50),  ("雪白", 255, 250, 250),
        ("墨绿", 0, 64, 0),      ("胭脂", 220, 20, 60),
    ]

    private func chineseColorName(for color: NSColor) -> String {
        let r = Int((color.redComponent   * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent  * 255).rounded())
        var best = ""
        var bestDist = Int.max
        for (name, cr, cg, cb) in Self.chineseColorTable {
            let dr = r - cr, dg = g - cg, db = b - cb
            let d = dr * dr + dg * dg + db * db
            if d < bestDist { bestDist = d; best = name }
        }
        return best
    }

    /// iShot-style smart window detection: finds the topmost window under
    /// the cursor and snaps the selection to its bounds.  Falls back to
    /// full-screen preselection when the cursor is on the desktop.
    private func detectWindowUnderCursor(at location: CGPoint) {
        guard purpose == .regular,
              !isPreparingAnnotation,
              !isSubmitting, !isRecordingConfirming,
              annotationCanvas == nil,
              dragOperation == nil,
              preselectClickStart == nil,
              bounds.width > 0, bounds.height > 0,
              let window else { return }

        // Convert view point → AppKit screen point → CG display point
        let windowPoint = convert(location, to: nil)
        let screenPoint = window.convertToScreen(
            CGRect(origin: windowPoint, size: .zero)).origin
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenPoint.y
        let cgPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)

        let ownPID = ProcessInfo.processInfo.processIdentifier

        if let windowList = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            // Windows are listed front-to-back; pick the first match.
            for info in windowList {
                guard let layer = info[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? Int,
                      pid != ownPID,
                      let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                      let x = boundsDict["X"] as? CGFloat,
                      let y = boundsDict["Y"] as? CGFloat,
                      let w = boundsDict["Width"] as? CGFloat,
                      let h = boundsDict["Height"] as? CGFloat
                else { continue }

                // Skip tiny windows (menus, popovers, etc.)
                guard w > 10, h > 10 else { continue }

                let cgRect = CGRect(x: x, y: y, width: w, height: h)
                guard cgRect.contains(cgPoint) else { continue }

                // Convert CG rect → AppKit screen rect → view rect
                let appKitOrigin = CGPoint(x: x, y: primaryHeight - y - h)
                let appKitRect = CGRect(
                    origin: appKitOrigin,
                    size: CGSize(width: w, height: h))
                let windowRect = window.convertFromScreen(appKitRect)
                let viewRect = convert(windowRect, from: nil)

                // Clip to this screen's bounds
                let clipped = viewRect.intersection(bounds)
                guard !clipped.isNull,
                      clipped.width > 10, clipped.height > 10 else { continue }

                startPoint = clipped.origin
                currentPoint = CGPoint(x: clipped.maxX, y: clipped.maxY)
                isSelectionFinalized = true
                isPreselected = true
                window.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }
        }

        // Desktop fallback: full-screen preselection
        startPoint = .zero
        currentPoint = CGPoint(x: bounds.maxX, y: bounds.maxY)
        isSelectionFinalized = true
        isPreselected = true
        window.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isPreparingAnnotation else { return }
        let location = convert(event.locationInWindow, from: nil)

        if isSelectionFinalized, !isPreselected,
           let handle = selectionHandle(at: location),
           let selection = currentSelection() {
            dragOperation = .resizing(handle)
            resizeInitialRect = selection
            hideSelectionControls()
            window?.makeFirstResponder(self)
            annotationCanvas?.needsDisplay = true
            return
        }

        if annotationCanvas != nil { return }

        if isSelectionFinalized,
           let selection = currentSelection(),
           selection.contains(location) {
            if event.clickCount >= 2 {
                if purpose == .longCapture {
                    requestLongCapture()
                } else if purpose == .recording {
                    NSSound.beep()
                } else if purpose == .delayedCapture {
                    requestDelayedCapture()
                } else {
                    submitSelection(action: .copy)
                }
                return
            }

            // Like iShot/Xnip: a click in the pre-selected full-screen
            // region enters annotation mode on mouseUp; a drag converts
            // to a fresh selection.  Don't commit to either action yet.
            if isPreselected {
                preselectClickStart = location
                window?.makeFirstResponder(self)
                updateOverlayCursor(at: location)
                return
            }

            dragOperation = .moving
            moveAnchorPoint = location
            moveInitialRect = selection
            hideSelectionControls()
            NSCursor.closedHand.set()
            return
        }

        dragOperation = .selecting
        moveAnchorPoint = nil
        moveInitialRect = nil
        isSelectionFinalized = false
        clearSelectionWatermarkPreview()
        hideSelectionControls()
        startPoint = location
        currentPoint = startPoint
        window?.invalidateCursorRects(for: self)
        updateOverlayCursor(at: location)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isPreparingAnnotation else { return }
        let location = convert(event.locationInWindow, from: nil)

        if case .resizing(let handle) = dragOperation {
            resizeSelection(handle: handle, to: location)
            updateAnnotationCanvasForCurrentSelection()
            needsDisplay = true
            return
        }

        // Convert a pre-select click into a fresh drag-selection once the
        // mouse moves beyond a small threshold (like iShot/Xnip).
        if let start = preselectClickStart {
            if abs(location.x - start.x) > 3 || abs(location.y - start.y) > 3 {
                preselectClickStart = nil
                isPreselected = false
                isSelectionFinalized = false
                hideSelectionControls()
                startPoint = start
                currentPoint = location
                dragOperation = .selecting
                moveAnchorPoint = nil
                moveInitialRect = nil
                window?.invalidateCursorRects(for: self)
                updateOverlayCursor(at: location)
            }
            updateColorSampler(at: location)
            updateOverlayCursor(at: location)
            needsDisplay = true
            return
        }

        switch dragOperation {
        case .selecting:
            guard startPoint != nil else { return }
            currentPoint = location
            updateOverlayCursor(at: location)
            updateColorSampler(at: location)
        case .moving:
            moveSelection(to: location)
        case .resizing:
            return
        case nil:
            return
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isPreparingAnnotation else { return }
        let location = convert(event.locationInWindow, from: nil)

        // A plain click (no drag) on the pre-selected full-screen region
        // enters annotation mode — show the toolbar (like iShot/Xnip).
        if preselectClickStart != nil {
            preselectClickStart = nil
            isPreselected = false
            if let selection = currentSelection() {
                positionSelectionControls(for: selection)
            }
            window?.invalidateCursorRects(for: self)
            updateCursorAtCurrentMouseLocation()
            needsDisplay = true
            return
        }

        if case .resizing(let handle) = dragOperation {
            resizeSelection(handle: handle, to: location)
            updateAnnotationCanvasForCurrentSelection()
            dragOperation = nil
            resizeInitialRect = nil
            if let selection = currentSelection() {
                updateSelectionWatermarkPreview(for: selection)
                positionSelectionControls(for: selection)
            }
            window?.invalidateCursorRects(for: self)
            if let annotationCanvas {
                window?.makeFirstResponder(annotationCanvas)
            }
            needsDisplay = true
            return
        }

        if case .moving = dragOperation {
            moveSelection(to: location)
        } else if case .selecting = dragOperation {
            currentPoint = location
        }

        dragOperation = nil
        moveAnchorPoint = nil
        moveInitialRect = nil

        guard let selection = currentSelection(), selection.width >= 2, selection.height >= 2 else {
            startPoint = nil
            currentPoint = nil
            clearSelectionWatermarkPreview()
            hideSelectionControls()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }

        isSelectionFinalized = true
        updateSelectionWatermarkPreview(for: selection)
        positionSelectionControls(for: selection)
        window?.invalidateCursorRects(for: self)
        updateCursorAtCurrentMouseLocation()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if annotationCanvas != nil {
            // The canvas is first responder while editing. If an event reaches
            // the overlay it has already been declined by the canvas, so routing
            // it back would recurse indefinitely.
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            onSelectionCancelled?()
        } else if purpose == .longCapture,
                  isSelectionFinalized,
                  event.keyCode == UInt16(kVK_Return) {
            requestLongCapture()
        } else if purpose == .delayedCapture,
                  isSelectionFinalized,
                  event.keyCode == UInt16(kVK_Return) {
            requestDelayedCapture()
        } else if purpose == .regular,
                  isSelectionFinalized,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "c" {
            submitSelection(action: .copy)
        } else if purpose == .regular,
                  isSelectionFinalized,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "s" {
            submitSelection(action: .saveToDownloads)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Set the pre-captured full-screen image as the overlay background.
    /// This creates a "freeze screen" effect: the user sees the captured
    /// content (including popovers that have since disappeared) instead
    /// of the live screen behind a transparent overlay.
    func setPreCapturedScreenImage(_ image: CGImage) {
        frozenScreenImage = image
        clearSelectionWatermarkPreview()
        needsDisplay = true
    }

    func presetSelection(_ rect: CGRect) {
        let selection = rect.intersection(bounds).integral
        guard !selection.isNull, selection.width >= 2, selection.height >= 2 else { return }
        startPoint = selection.origin
        currentPoint = CGPoint(x: selection.maxX, y: selection.maxY)
        isSelectionFinalized = true
        isPreselected = false
        updateSelectionWatermarkPreview(for: selection)
        positionSelectionControls(for: selection)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw the frozen screen image as an opaque background so the
        // overlay shows the captured content instead of the live screen
        // where transient UI may already have disappeared.
        if let frozenScreenImage,
           let ctx = NSGraphicsContext.current?.cgContext {
            ctx.draw(frozenScreenImage, in: bounds)
        }

        NSColor.black.withAlphaComponent(0.34).setFill()
        guard let selection = currentSelection() else {
            bounds.fill()
            let hint = purpose == .longCapture
                ? "拖动选择可滚动区域，Esc 取消"
                : purpose == .delayedCapture
                    ? "拖动选择延时截图区域，Esc 取消"
                    : "拖动选择截图区域，Esc 取消"
            drawHint(hint, at: NSPoint(x: bounds.midX - 110, y: bounds.midY))
            drawSelectionGuideLines()
            drawColorSamplerOverlay()
            drawSyntheticSelectionCursor()
            return
        }

        let dimmedArea = NSBezierPath(rect: bounds)
        dimmedArea.append(NSBezierPath(rect: selection))
        dimmedArea.windingRule = .evenOdd
        dimmedArea.fill()

        if let preview = selectionWatermarkPreviewImage,
           selectionWatermarkPreviewRect == selection,
           isSelectionFinalized,
           annotationCanvas == nil,
           let ctx = NSGraphicsContext.current?.cgContext {
            ctx.draw(preview, in: selection)
        }

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()

        if isSelectionFinalized, !isPreselected, annotationCanvas == nil {
            drawSelectionHandles(for: selection)
        }

        let label = "\(Int(selection.width)) x \(Int(selection.height))"
        drawHint(
            label,
            at: NSPoint(
                x: max(min(selection.minX, bounds.maxX - 120), 8),
                y: min(selection.maxY + 7, bounds.maxY - 34)
            )
        )
        drawSelectionGuideLines()
        drawColorSamplerOverlay()
        drawSyntheticSelectionCursor()
    }

    @objc private func cancelSelection() {
        onSelectionCancelled?()
    }

    @objc private func copySelection() {
        submitSelection(action: .copy)
    }

    @objc private func saveSelection() {
        submitSelection(action: .saveToDownloads)
    }

    private func requestOCR() {
        guard isSelectionFinalized, !isSubmitting else { return }

        isSubmitting = true
        actionBar.setBusy(true, message: "正在识别文字…")
        if annotationCanvas != nil {
            annotationCanvas?.cancelPendingInteraction()
            guard let selection = currentSelection(),
                  let image = croppedFrozenImage(for: selection) else {
                isSubmitting = false
                actionBar.setBusy(false)
                onAnnotationFailed?(NSError(
                    domain: "SnapInk.OCR",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取原始截图区域。"]
                ))
                return
            }
            onOCRRequested?(.image(image))
            return
        }

        guard let globalRect = currentGlobalSelectionRect() else {
            isSubmitting = false
            actionBar.setBusy(false)
            return
        }
        onOCRRequested?(.globalRect(globalRect))
    }

    private func submitSelection(action: CaptureAction) {
        guard isSelectionFinalized, !isSubmitting else { return }
        if let annotationCanvas {
            isSubmitting = true
            actionBar.setBusy(true, message: "正在生成图片…")
            do {
                guard let selection = currentSelection() else {
                    isSubmitting = false
                    actionBar.setBusy(false)
                    return
                }
                let image = try annotationCanvas.renderedImage()
                onAnnotatedFinished?(image, action, selection.size, annotatedOutputOptions ?? .noWatermark)
            } catch {
                isSubmitting = false
                actionBar.setBusy(false)
                onAnnotationFailed?(error)
            }
            return
        }

        guard let globalRect = currentGlobalSelectionRect() else { return }
        onSelectionFinished?(globalRect, action, selectionOutputOptions ?? currentOutputOptions())
    }

    private func currentOutputOptions() -> CaptureOutputOptions {
        var configuration = WatermarkPreferences.load()
        configuration.isEnabled = true
        return CaptureOutputOptions(
            watermarkConfiguration: sessionWatermarkEnabled && configuration.hasRenderableContent ? configuration : nil,
            capturedAt: Date()
        )
    }

    func enterAnnotationEditing(
        baseImage: CGImage,
        initialTool: AnnotationTool,
        outputOptions: CaptureOutputOptions = .noWatermark
    ) {
        guard annotationCanvas == nil,
              let selection = currentSelection() else { return }

        isPreparingAnnotation = false
        actionBar.setBusy(false)
        updateLiveCaptureActionAvailability(for: nil)
        // frozenScreenImage may already be set from the pre-capture;
        // overwrite with the annotation-specific base image.
        frozenScreenImage = baseImage
        guard let croppedImage = croppedFrozenImage(for: selection) else {
            onAnnotationFailed?(NSError(
                domain: "SnapInk.Annotation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法裁剪标注截图区域。"]
            ))
            return
        }
        let previewImage: CGImage
        do {
            previewImage = try previewImageForAnnotation(from: croppedImage, options: outputOptions)
        } catch {
            onAnnotationFailed?(error)
            return
        }
        annotationPreviewOptions = outputOptions
        annotatedOutputOptions = CaptureOutputOptions(
            watermarkConfiguration: nil,
            capturedAt: outputOptions.capturedAt
        )
        let canvas = AnnotationCanvasView(
            frame: selection,
            baseImage: previewImage,
            logicalOrigin: logicalOrigin(for: selection)
        )
        canvas.showsCaptureResizeHandles = true
        canvas.onDocumentChanged = { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.actionBar.setUndoEnabled(
                canvas.document.undoManager.canUndo,
                redoEnabled: canvas.document.undoManager.canRedo
            )
        }
        canvas.onSelectionChanged = { [weak self] item in
            self?.actionBar.setSelectedItem(item)
        }
        canvas.onToolShortcut = { [weak self] tool in
            self?.activateAnnotationTool(tool)
        }
        canvas.onCommit = { [weak self] action in
            self?.submitSelection(action: action)
        }
        canvas.onCancelCapture = { [weak self] in
            self?.onSelectionCancelled?()
        }
        addSubview(canvas, positioned: .below, relativeTo: actionBar)
        annotationCanvas = canvas
        activateAnnotationTool(initialTool)
        positionSelectionControls(for: selection)
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(canvas)
        needsDisplay = true
    }

    private func updateAnnotationCanvasForCurrentSelection() {
        guard let annotationCanvas,
              let selection = currentSelection(),
              let croppedImage = croppedFrozenImage(for: selection) else { return }
        let previewImage: CGImage
        do {
            previewImage = try previewImageForAnnotation(
                from: croppedImage,
                options: annotationPreviewOptions ?? .noWatermark
            )
        } catch {
            onAnnotationFailed?(error)
            return
        }
        annotationCanvas.updateCaptureArea(
            frame: selection,
            baseImage: previewImage,
            logicalOrigin: logicalOrigin(for: selection)
        )
    }

    private func previewImageForAnnotation(
        from image: CGImage,
        options: CaptureOutputOptions
    ) throws -> CGImage {
        guard let configuration = options.watermarkConfiguration else { return image }
        return try WatermarkRenderer.render(
            image: image,
            configuration: configuration,
            context: WatermarkContext(capturedAt: options.capturedAt)
        )
    }

    private func updateSelectionWatermarkPreview(for selection: CGRect) {
        let options = currentOutputOptions()
        selectionOutputOptions = options
        selectionWatermarkPreviewImage = nil
        selectionWatermarkPreviewRect = nil

        guard annotationCanvas == nil,
              isSelectionFinalized,
              let configuration = options.watermarkConfiguration,
              let croppedImage = croppedFrozenImage(for: selection) else { return }

        do {
            selectionWatermarkPreviewImage = try WatermarkRenderer.render(
                image: croppedImage,
                configuration: configuration,
                context: WatermarkContext(capturedAt: options.capturedAt)
            )
            selectionWatermarkPreviewRect = selection
        } catch {
            onAnnotationFailed?(error)
        }
    }

    private func clearSelectionWatermarkPreview() {
        selectionOutputOptions = nil
        selectionWatermarkPreviewImage = nil
        selectionWatermarkPreviewRect = nil
    }

    private func setSessionWatermarkEnabled(_ enabled: Bool) {
        sessionWatermarkEnabled = enabled
        actionBar.setWatermarkAvailable(
            WatermarkPreferences.load().hasRenderableContent,
            enabled: enabled
        )
        if let selection = currentSelection(), isSelectionFinalized {
            updateSelectionWatermarkPreview(for: selection)
            if let annotationCanvas, let croppedImage = croppedFrozenImage(for: selection) {
                do {
                    let options = currentOutputOptions()
                    let previewImage = try previewImageForAnnotation(from: croppedImage, options: options)
                    annotationPreviewOptions = options
                    annotatedOutputOptions = CaptureOutputOptions(
                        watermarkConfiguration: nil,
                        capturedAt: options.capturedAt
                    )
                    annotationCanvas.updateCaptureArea(
                        frame: selection,
                        baseImage: previewImage,
                        logicalOrigin: logicalOrigin(for: selection)
                    )
                } catch {
                    onAnnotationFailed?(error)
                }
            }
        }
        needsDisplay = true
    }

    private func logicalOrigin(for selection: CGRect) -> CGPoint {
        CGPoint(x: selection.minX, y: bounds.maxY - selection.maxY)
    }

    private func croppedFrozenImage(for selection: CGRect) -> CGImage? {
        guard let frozenScreenImage else { return nil }
        let scaleX = CGFloat(frozenScreenImage.width) / bounds.width
        let scaleY = CGFloat(frozenScreenImage.height) / bounds.height
        let pixelRect = CGRect(
            x: selection.minX * scaleX,
            y: (bounds.maxY - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral.intersection(CGRect(
            x: 0,
            y: 0,
            width: frozenScreenImage.width,
            height: frozenScreenImage.height
        ))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return frozenScreenImage.cropping(to: pixelRect)
    }

    func annotationEditingDidFail() {
        isPreparingAnnotation = false
        actionBar.setBusy(false)
        updateLiveCaptureActionAvailability(for: currentSelection())
    }

    private func requestAnnotationEditing(tool: AnnotationTool) {
        guard tool != .select,
              annotationCanvas == nil,
              !isPreparingAnnotation,
              let globalRect = currentGlobalSelectionRect() else { return }
        isPreparingAnnotation = true
        actionBar.setBusy(true)
        onEditingRequested?(globalRect, tool, selectionOutputOptions ?? currentOutputOptions())
    }

    private func activateAnnotationTool(_ tool: AnnotationTool) {
        guard let annotationCanvas else {
            if tool == .select {
                actionBar.setTool(.select, style: .defaultStyle(for: .rectangle))
            } else {
                requestAnnotationEditing(tool: tool)
            }
            return
        }
        activeAnnotationTool = tool
        let style = annotationStyles[tool] ?? .defaultStyle(for: tool)
        actionBar.setTool(tool, style: style)
        annotationCanvas.setTool(tool, style: style)
    }

    private func applyAnnotationStyle(_ style: AnnotationStyle) {
        guard let annotationCanvas else { return }
        let targetTool = annotationCanvas.document.selectedItem?.tool ?? activeAnnotationTool
        guard targetTool != .select else { return }
        annotationStyles[targetTool] = style
        AnnotationStylePreferences.save(style, for: targetTool)
        annotationCanvas.applyStyle(style)
        actionBar.setUndoEnabled(
            annotationCanvas.document.undoManager.canUndo,
            redoEnabled: annotationCanvas.document.undoManager.canRedo
        )
    }

    private func currentGlobalSelectionRect() -> CGRect? {
        guard let window, let selection = currentSelection() else { return nil }

        let windowRect = convert(selection, to: nil)
        return window.convertToScreen(windowRect).integral
    }

    private func makeActionBar() -> AnnotationToolbarView {
        let width = min(720, max(520, bounds.width - 16))
        let bar = AnnotationToolbarView(frame: NSRect(x: 0, y: 0, width: width, height: 82))
        bar.setWatermarkAvailable(
            WatermarkPreferences.load().hasRenderableContent,
            enabled: sessionWatermarkEnabled
        )
        bar.onToolSelected = { [weak self] tool in
            self?.activateAnnotationTool(tool)
        }
        bar.onStyleChanged = { [weak self] style in
            self?.applyAnnotationStyle(style)
        }
        bar.onUndo = { [weak self] in
            self?.annotationCanvas?.undo()
        }
        bar.onRedo = { [weak self] in
            self?.annotationCanvas?.redo()
        }
        bar.onCancel = { [weak self] in
            self?.annotationCanvas?.cancelPendingInteraction()
            self?.onSelectionCancelled?()
        }
        bar.onLongCapture = { [weak self] in
            self?.requestLongCapture()
        }
        bar.onGIF = { [weak self] in
            self?.showRecordingConfirmBar()
        }
        bar.onCopy = { [weak self] in
            self?.submitSelection(action: .copy)
        }
        bar.onSave = { [weak self] in
            self?.submitSelection(action: .saveToDownloads)
        }
        bar.onOCR = { [weak self] in
            self?.requestOCR()
        }
        bar.onPin = { [weak self] in
            self?.submitSelection(action: .pin)
        }
        bar.onWatermarkToggle = { [weak self] enabled in
            self?.setSessionWatermarkEnabled(enabled)
        }
        bar.onPreferredSizeChanged = { [weak self] in
            guard let self, let selection = self.currentSelection() else { return }
            self.positionSelectionControls(for: selection)
        }
        return bar
    }

    private func positionSelectionControls(for selection: CGRect) {
        let controls: NSView
        if purpose == .longCapture {
            controls = longCaptureBar
        } else if purpose == .delayedCapture {
            controls = delayedCaptureBar
        } else if purpose == .recording || isRecordingConfirming {
            controls = recordingBar
        } else {
            controls = actionBar
            updateLiveCaptureActionAvailability(for: selection)
        }
        let size = controls.frame.size
        let horizontalInset: CGFloat = 8
        let gap: CGFloat = 8
        let x = min(
            max(selection.maxX - size.width, horizontalInset),
            bounds.maxX - size.width - horizontalInset
        )

        var y = selection.minY - size.height - gap
        if y < horizontalInset {
            y = selection.maxY + gap
        }
        y = min(max(y, horizontalInset), bounds.maxY - size.height - horizontalInset)

        controls.setFrameOrigin(NSPoint(x: x, y: y))
        controls.isHidden = false
        window?.invalidateCursorRects(for: self)
        updateCursorAtCurrentMouseLocation()
    }

    private func hideSelectionControls() {
        switch purpose {
        case .regular:
            actionBar.isHidden = true
            recordingBar.isHidden = true
        case .longCapture:
            longCaptureBar.isHidden = true
        case .recording:
            recordingBar.isHidden = true
        case .delayedCapture:
            delayedCaptureBar.isHidden = true
        }
        window?.invalidateCursorRects(for: self)
        updateCursorAtCurrentMouseLocation()
    }

    /// Switch from the annotation toolbar to the shared recording format bar
    /// that reuses the current selection (no re-drawing needed).
    private func showRecordingConfirmBar() {
        guard purpose == .regular,
              allowsLiveCaptureActions,
              annotationCanvas == nil,
              isSelectionFinalized,
              !isSubmitting,
              let selection = currentSelection(),
              selection.width >= 80,
              selection.height >= 80 else {
            NSSound.beep()
            return
        }
        actionBar.isHidden = true
        isRecordingConfirming = true
        positionSelectionControls(for: selection)
        needsDisplay = true
    }

    private func requestLongCapture() {
        let needsBar = purpose == .longCapture
        guard (needsBar || (allowsLiveCaptureActions && annotationCanvas == nil)),
              isSelectionFinalized,
              !isSubmitting,
              let selection = currentSelection(),
              selection.width >= 80,
              selection.height >= 80,
              let globalRect = currentGlobalSelectionRect() else {
            if needsBar { NSSound.beep() }
            return
        }
        isSubmitting = true
        hideSelectionControls()
        onLongCaptureRequested?(globalRect)
    }

    private func updateLiveCaptureActionAvailability(for selection: CGRect?) {
        guard purpose == .regular else { return }
        let available = allowsLiveCaptureActions &&
            annotationCanvas == nil &&
            !isPreparingAnnotation &&
            !isSubmitting &&
            (selection?.width ?? 0) >= 80 &&
            (selection?.height ?? 0) >= 80
        actionBar.setLongCaptureEnabled(available)
        actionBar.setGIFEnabled(available)
    }

    private func requestDelayedCapture() {
        guard purpose == .delayedCapture,
              isSelectionFinalized,
              !isSubmitting,
              let selection = currentSelection(),
              selection.width >= 2,
              selection.height >= 2,
              let globalRect = currentGlobalSelectionRect() else {
            NSSound.beep()
            return
        }
        isSubmitting = true
        hideSelectionControls()
        onDelayedCaptureRequested?(globalRect)
    }

    private func currentSelection() -> CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        ).integral
    }

    private func moveSelection(to location: NSPoint) {
        guard let moveAnchorPoint, let moveInitialRect else { return }

        let offsetX = location.x - moveAnchorPoint.x
        let offsetY = location.y - moveAnchorPoint.y
        let maxX = max(bounds.minX, bounds.maxX - moveInitialRect.width)
        let maxY = max(bounds.minY, bounds.maxY - moveInitialRect.height)
        let origin = NSPoint(
            x: min(max(moveInitialRect.minX + offsetX, bounds.minX), maxX),
            y: min(max(moveInitialRect.minY + offsetY, bounds.minY), maxY)
        )

        startPoint = origin
        currentPoint = NSPoint(
            x: origin.x + moveInitialRect.width,
            y: origin.y + moveInitialRect.height
        )
    }

    private func selectionHandle(at point: CGPoint) -> SelectionHandle? {
        guard let selection = currentSelection() else { return nil }
        return selectionHandlePoints(for: selection).first { _, handlePoint in
            abs(point.x - handlePoint.x) <= handleHitHalfSize
                && abs(point.y - handlePoint.y) <= handleHitHalfSize
        }?.0
    }

    private func selectionHandlePoints(for selection: CGRect) -> [(SelectionHandle, CGPoint)] {
        [
            (.bottomLeft, CGPoint(x: selection.minX, y: selection.minY)),
            (.bottomRight, CGPoint(x: selection.maxX, y: selection.minY)),
            (.topLeft, CGPoint(x: selection.minX, y: selection.maxY)),
            (.topRight, CGPoint(x: selection.maxX, y: selection.maxY)),
            (.bottom, CGPoint(x: selection.midX, y: selection.minY)),
            (.left, CGPoint(x: selection.minX, y: selection.midY)),
            (.right, CGPoint(x: selection.maxX, y: selection.midY)),
            (.top, CGPoint(x: selection.midX, y: selection.maxY))
        ]
    }

    private func drawSelectionHandles(for selection: CGRect) {
        for (_, point) in selectionHandlePoints(for: selection) {
            let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1.25
            outline.stroke()
        }
    }

    private func resizeSelection(handle: SelectionHandle, to location: CGPoint) {
        guard let original = resizeInitialRect else { return }
        let minimumSize: CGFloat = 24
        let x = min(max(location.x, bounds.minX), bounds.maxX)
        let y = min(max(location.y, bounds.minY), bounds.maxY)
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft:
            minX = min(x, original.maxX - minimumSize)
            maxY = max(y, original.minY + minimumSize)
        case .top:
            maxY = max(y, original.minY + minimumSize)
        case .topRight:
            maxX = max(x, original.minX + minimumSize)
            maxY = max(y, original.minY + minimumSize)
        case .left:
            minX = min(x, original.maxX - minimumSize)
        case .right:
            maxX = max(x, original.minX + minimumSize)
        case .bottomLeft:
            minX = min(x, original.maxX - minimumSize)
            minY = min(y, original.maxY - minimumSize)
        case .bottom:
            minY = min(y, original.maxY - minimumSize)
        case .bottomRight:
            maxX = max(x, original.minX + minimumSize)
            minY = min(y, original.maxY - minimumSize)
        }

        startPoint = CGPoint(x: minX, y: minY)
        currentPoint = CGPoint(x: maxX, y: maxY)
    }

    private func drawSyntheticSelectionCursor() {
        guard isDrawingSyntheticSelectionCursor,
              let point = syntheticSelectionCursorLocation,
              bounds.contains(point),
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let armLength: CGFloat = 12
        let gap: CGFloat = 3
        let arms: [(CGPoint, CGPoint)] = [
            (
                CGPoint(x: point.x, y: point.y + gap),
                CGPoint(x: point.x, y: point.y + gap + armLength)
            ),
            (
                CGPoint(x: point.x, y: point.y - gap),
                CGPoint(x: point.x, y: point.y - gap - armLength)
            ),
            (
                CGPoint(x: point.x + gap, y: point.y),
                CGPoint(x: point.x + gap + armLength, y: point.y)
            ),
            (
                CGPoint(x: point.x - gap, y: point.y),
                CGPoint(x: point.x - gap - armLength, y: point.y)
            )
        ]

        func stroke(_ color: NSColor, width: CGFloat) {
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            for (start, end) in arms {
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            }
            context.restoreGState()
        }

        stroke(NSColor.black.withAlphaComponent(0.62), width: 3)
        stroke(.white, width: 1.25)
    }

    // MARK: - Color Sampler Drawing

    private func drawSelectionGuideLines() {
        guard isSelectionHoverTrackingActive,
              let location = selectionGuideLocation,
              bounds.contains(location) else { return }

        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()

        let hLine = NSBezierPath()
        hLine.move(to: CGPoint(x: bounds.minX, y: location.y))
        hLine.line(to: CGPoint(x: bounds.maxX, y: location.y))
        hLine.lineWidth = 1.5
        hLine.stroke()

        let vLine = NSBezierPath()
        vLine.move(to: CGPoint(x: location.x, y: bounds.minY))
        vLine.line(to: CGPoint(x: location.x, y: bounds.maxY))
        vLine.lineWidth = 1.5
        vLine.stroke()
    }

    private func drawColorSamplerOverlay() {
        guard isColorSamplerActive,
              let location = colorSamplerLocation,
              let color = sampledColor else { return }

        drawColorInfoPopup(at: location, color: color)
    }

    private func drawColorInfoPopup(at point: CGPoint, color: NSColor) {
        let r = Int((color.redComponent   * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent  * 255).rounded())
        let hex = String(format: "%02X%02X%02X", r, g, b)
        let name = chineseColorName(for: color)

        let posText: String
        if let pos = sampledScreenPosition {
            posText = "\(Int(pos.x)),\(Int(pos.y))"
        } else {
            posText = ""
        }

        // Square magnifier box (like iShot)
        let boxSize: CGFloat = 120
        let borderWidth: CGFloat = 1.5
        let pad: CGFloat = 5
        let offset: CGFloat = 10

        var bx = point.x + offset
        if bx + boxSize > bounds.maxX - 4 { bx = point.x - offset - boxSize }
        if bx < 4 { bx = 4 }

        var by = point.y + offset
        if by + boxSize > bounds.maxY - 4 { by = point.y - offset - boxSize }
        if by < 4 { by = 4 }

        let box = CGRect(x: bx, y: by, width: boxSize, height: boxSize)
        let inner = box.insetBy(dx: borderWidth, dy: borderWidth)

        // Background — light, semi-transparent
        NSColor(white: 0.22, alpha: 0.72).setFill()
        box.fill()

        // Magnified screen content (loupe)
        if let img = magnifierImage,
           let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            // Clip to the box so the image doesn't bleed outside
            ctx.clip(to: box)
            // CGImage origin is top-left; CGContext origin is bottom-left.
            // Flip Y so the captured screen appears right-side-up.
            ctx.translateBy(x: 0, y: box.maxY)
            ctx.scaleBy(x: 1, y: -1)
            // Nearest-neighbour for a crisp pixelated magnifier look
            ctx.interpolationQuality = .none
            ctx.draw(
                img,
                in: CGRect(x: box.minX, y: 0, width: box.width, height: box.height)
            )
            ctx.restoreGState()
        }

        // Grid pattern
        NSColor.white.withAlphaComponent(0.05).setStroke()
        let gridStep: CGFloat = 12
        var gx = inner.minX
        while gx <= inner.maxX {
            let gl = NSBezierPath()
            gl.move(to: CGPoint(x: gx, y: inner.minY))
            gl.line(to: CGPoint(x: gx, y: inner.maxY))
            gl.lineWidth = 0.5
            gl.stroke()
            gx += gridStep
        }
        var gy = inner.minY
        while gy <= inner.maxY {
            let gl = NSBezierPath()
            gl.move(to: CGPoint(x: inner.minX, y: gy))
            gl.line(to: CGPoint(x: inner.maxX, y: gy))
            gl.lineWidth = 0.5
            gl.stroke()
            gy += gridStep
        }

        // Blue crosshair through center
        let cx = inner.midX
        let cy = inner.midY
        NSColor.systemBlue.withAlphaComponent(0.55).setStroke()
        let ch = NSBezierPath()
        ch.move(to: CGPoint(x: inner.minX, y: cy))
        ch.line(to: CGPoint(x: inner.maxX, y: cy))
        ch.lineWidth = 1
        ch.stroke()

        let cv = NSBezierPath()
        cv.move(to: CGPoint(x: cx, y: inner.minY))
        cv.line(to: CGPoint(x: cx, y: inner.maxY))
        cv.lineWidth = 1
        cv.stroke()

        // Center hollow square — sampling point marker
        let markerSize: CGFloat = 9
        let marker = CGRect(
            x: cx - markerSize / 2,
            y: cy - markerSize / 2,
            width: markerSize,
            height: markerSize
        )
        color.withAlphaComponent(0.35).setFill()
        marker.fill()
        NSColor.systemBlue.setStroke()
        let mp = NSBezierPath(rect: marker)
        mp.lineWidth = 1.5
        mp.stroke()

        // Blue border — sharp corners
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        let bp = NSBezierPath(rect: box)
        bp.lineWidth = borderWidth
        bp.stroke()

        // Adaptive text color — black on light backgrounds, white on dark
        let luminance = 0.2126 * color.redComponent
                     + 0.7152 * color.greenComponent
                     + 0.0722 * color.blueComponent
        let textColor: NSColor = luminance > 0.6 ? .black : .white

        // Text attributes
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: textColor
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: textColor
        ]

        // Color name — top center
        let nameStr = NSAttributedString(string: name, attributes: nameAttr)
        let nameSize = nameStr.size()
        nameStr.draw(at: CGPoint(
            x: inner.midX - nameSize.width / 2,
            y: inner.maxY - nameSize.height - pad
        ))

        // Coordinates — bottom-left
        if !posText.isEmpty {
            let posStr = NSAttributedString(string: posText, attributes: valueAttr)
            posStr.draw(at: CGPoint(
                x: inner.minX + pad,
                y: inner.minY + pad
            ))
        }

        // RGB — bottom-right, upper line
        let rgbText = "\(r),\(g),\(b)"
        let rgbStr = NSAttributedString(string: rgbText, attributes: valueAttr)
        let rgbSize = rgbStr.size()
        rgbStr.draw(at: CGPoint(
            x: inner.maxX - rgbSize.width - pad,
            y: inner.minY + pad + 12
        ))

        // HEX — bottom-right, lower line (no # prefix, matching iShot)
        let hexStr = NSAttributedString(string: hex, attributes: valueAttr)
        let hexSize = hexStr.size()
        hexStr.draw(at: CGPoint(
            x: inner.maxX - hexSize.width - pad,
            y: inner.minY + pad
        ))
    }

    private func drawHint(_ text: String, at point: NSPoint) {
        let padding = CGSize(width: 10, height: 6)
        let attributed = NSAttributedString(string: text, attributes: infoAttributes)
        let textSize = attributed.size()
        let bubble = CGRect(
            x: point.x,
            y: point.y,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 6, yRadius: 6).fill()
        attributed.draw(at: NSPoint(x: bubble.minX + padding.width, y: bubble.minY + padding.height))
    }
}

enum ScreenshotWriter {
    static func copyToPasteboard(_ image: CGImage) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw makeError(code: 1, message: "无法生成剪贴板图片。")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(pngData, forType: .png) else {
            throw makeError(code: 2, message: "无法写入系统剪贴板。")
        }
    }

    static func writeImage(
        _ image: CGImage,
        to directory: URL? = nil,
        format: AppPreferences.ImageFormat? = nil
    ) throws -> URL {
        let dir = directory ?? AppPreferences.saveLocation
        let fmt = format ?? AppPreferences.imageFormat
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("SnapInk-\(formatter.string(from: Date())).\(fmt.fileExtension)")

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, fmt.utType as CFString, 1, nil) else {
            throw makeError(code: 3, message: "无法创建 \(fmt.displayName) 文件。")
        }

        if fmt == .jpg {
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw makeError(code: 4, message: "无法将截图保存到 \(dir.path)。")
        }

        return url
    }

    static func writeGIF(_ data: Data, to directory: URL? = nil) throws -> URL {
        let dir = directory ?? AppPreferences.saveLocation
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("SnapInk-\(formatter.string(from: Date())).gif")
        try data.write(to: url)
        return url
    }

    static func copyGIFToPasteboard(_ data: Data) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif")) else {
            throw makeError(code: 5, message: "无法写入系统剪贴板。")
        }
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(domain: "SnapInk", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

let snapInkApplication = NSApplication.shared
let snapInkDelegate = AppDelegate()
snapInkApplication.delegate = snapInkDelegate
withExtendedLifetime(snapInkDelegate) {
    snapInkApplication.run()
}
