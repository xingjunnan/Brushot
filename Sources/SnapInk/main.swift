import AppKit
import Carbon
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import ServiceManagement

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
    case gifCapture = 6

    var title: String {
        switch self {
        case .capture: "区域截图"
        case .longCapture: "长截图"
        case .gifCapture: "GIF 录制"
        case .pinClipboard: "从剪贴板贴图"
        case .pinLibrary: "贴图库…"
        case .togglePins: "隐藏全部贴图"
        }
    }

    var preferencePrefix: String {
        switch self {
        case .capture: "captureShortcut"
        case .longCapture: "longCaptureShortcut"
        case .gifCapture: "gifCaptureShortcut"
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
        case .gifCapture:
            KeyboardShortcut(
                keyCode: UInt32(kVK_ANSI_G),
                modifiers: UInt32(optionKey),
                keyLabel: "G"
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
    private var pinVisibilityMenuItem: NSMenuItem!
    private let pinManager = PinManager.shared
    private var shortcuts = ShortcutPreferences.loadAll()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        installHotKeyHandler()
        registerInitialHotKeys()
        AppPreferences.syncLaunchAtLogin()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

        let longCapture = makeShortcutMenuItem(
            action: .longCapture,
            title: "长截图",
            selector: #selector(captureLongScreenshot)
        )
        menu.addItem(longCapture)

        let gifCapture = makeShortcutMenuItem(
            action: .gifCapture,
            title: "GIF 录制",
            selector: #selector(captureGIF)
        )
        menu.addItem(gifCapture)

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
        case .gifCapture: captureGIF()
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

    @objc private func captureGIF() {
        captureController.beginGIFCapture()
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
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

        // --- 快捷键 ---
        let shortcutRows = ShortcutAction.allCases.compactMap { action -> NSView? in
            guard let recorderButton = recorderButtons[action] else { return nil }
            recorderButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                recorderButton.widthAnchor.constraint(equalToConstant: 160),
                recorderButton.heightAnchor.constraint(equalToConstant: 28)
            ])
            return makeRow(label: action.title, trailingViews: [recorderButton])
        }
        let shortcutSection = makeSection(title: "快捷键", views: shortcutRows)

        // --- Note ---
        let note = NSTextField(labelWithString: "快捷键必须包含 ⌘、⌃ 或 ⌥；重复或已被系统占用的组合不会保存。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // --- Assemble ---
        let outerStack = NSStackView(views: [generalSection, imageSection, shortcutSection, note])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 28
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
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
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        views.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
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
        labelField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return row
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

    private func stopRecording(except activeButton: ShortcutRecorderButton?) {
        for button in recorderButtons.values where button !== activeButton {
            button.stopRecording()
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

enum OCRSource {
    case globalRect(CGRect)
    case image(CGImage)
}

@MainActor
final class CaptureController {
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var isRequestingScreenCapturePermission = false
    private var isPreparingLongCapture = false
    private var longCaptureSession: LongCaptureSessionController?
    private var longCapturePreview: LongCapturePreviewWindowController?
    private var gifSession: GIFSessionController?
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
        requestScreenCapturePermission { [weak self] in
            self?.presentSelectionOverlays()
        }
    }

    func beginLongCapture() {
        guard longCaptureSession == nil, !isPreparingLongCapture else {
            NSSound.beep()
            return
        }
        requestScreenCapturePermission { [weak self] in
            self?.presentLongCaptureOverlays()
        }
    }

    func beginGIFCapture() {
        guard gifSession == nil else {
            NSSound.beep()
            return
        }
        requestScreenCapturePermission { [weak self] in
            self?.presentGIFCaptureOverlays()
        }
    }

    private func requestScreenCapturePermission(
        then action: @escaping @MainActor () -> Void
    ) {
        guard !isRequestingScreenCapturePermission else {
            return
        }

        if CGPreflightScreenCaptureAccess() {
            action()
            return
        }

        // On recent macOS releases CGRequestScreenCaptureAccess() can return
        // denial without displaying a prompt or registering the app in System
        // Settings. Asking ScreenCaptureKit for the available content performs
        // the real capture authorization request and reliably creates the TCC
        // entry for this installed app.
        isRequestingScreenCapturePermission = true
        Task { [weak self] in
            guard let self else { return }
            defer { isRequestingScreenCapturePermission = false }

            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                action()
            } catch {
                showPermissionAlert(error: error)
            }
        }
    }

    private func presentSelectionOverlays() {
        closeOverlays()

        let screens = NSScreen.screens
        overlayWindows = screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen)
            window.onSelectionFinished = { [weak self] rect, action in
                self?.finishCapture(globalRect: rect, action: action)
            }
            window.onSelectionCancelled = { [weak self] in
                self?.closeOverlays()
            }
            window.onEditingRequested = { [weak self, weak window] rect, tool in
                guard let self, let window else { return }
                self.beginAnnotationEditing(globalRect: rect, tool: tool, window: window)
            }
            window.onAnnotatedFinished = { [weak self] image, action, displaySize in
                self?.finishAnnotatedCapture(image: image, action: action, displaySize: displaySize)
            }
            window.onAnnotationFailed = { [weak self] error in
                self?.showFailureAlert(message: error.localizedDescription)
            }
            window.onOCRRequested = { [weak self] source in
                self?.finishOCR(source: source)
            }
            window.onLongCaptureRequested = { [weak self] rect in
                self?.startLongCapture(globalRect: rect)
            }
            window.onGIFCaptureRequested = { [weak self] rect in
                self?.startGIFCapture(globalRect: rect)
            }
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.forEach { $0.makeKeyAndOrderFront(nil) }
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
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    private func presentGIFCaptureOverlays() {
        closeOverlays()
        overlayWindows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen, purpose: .gifCapture)
            window.onSelectionCancelled = { [weak self] in
                self?.closeOverlays()
            }
            window.onGIFCaptureRequested = { [weak self] rect in
                self?.startGIFCapture(globalRect: rect)
            }
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.forEach { $0.makeKeyAndOrderFront(nil) }
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

    private func startGIFCapture(globalRect: CGRect) {
        guard gifSession == nil else { return }
        closeOverlays()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(90))
                let capturer = try await ScreenRegionCapturer(globalRect: globalRect)
                let session = GIFSessionController(
                    selectionRect: globalRect,
                    capturer: capturer,
                    fps: 15,
                    maxDuration: 30,
                    maxWidth: 720,
                    onFinish: { [weak self] data in
                        guard let self else { return }
                        self.gifSession = nil
                        self.finishGIFCapture(data: data)
                    },
                    onCancel: { [weak self] in
                        self?.gifSession = nil
                    },
                    onError: { [weak self] error in
                        self?.gifSession = nil
                        self?.showFailureAlert(message: error.localizedDescription)
                    }
                )
                gifSession = session
                session.start()
                await capturer.prepareForOverlayExclusion()
            } catch {
                showFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func finishGIFCapture(data: Data) {
        do {
            let url = try ScreenshotWriter.writeGIF(data)
            NSSound(named: "Glass")?.play()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showFailureAlert(message: error.localizedDescription)
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

    private func finishCapture(globalRect: CGRect, action: CaptureAction) {
        closeOverlays()

        guard globalRect.width >= 2, globalRect.height >= 2 else { return }

        // Give WindowServer one frame to remove the selection overlays.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.capture(globalRect: globalRect, action: action)
        }
    }

    private func capture(globalRect: CGRect, action: CaptureAction) {
        Task { [weak self] in
            guard let self else { return }

            do {
                let cgImage = try await makeScreenshot(globalRect: globalRect)
                try output(cgImage, action: action, pinDisplaySize: globalRect.size)
            } catch {
                showFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func beginAnnotationEditing(
        globalRect: CGRect,
        tool: AnnotationTool,
        window: SelectionOverlayWindow
    ) {
        Task { [weak self, weak window] in
            guard let self, let window else { return }
            do {
                // Freeze the whole display so the selection can still be
                // enlarged or reduced after annotation mode has started.
                let image = try await makeScreenshot(globalRect: window.frame)
                window.enterAnnotationEditing(baseImage: image, initialTool: tool)
            } catch {
                window.annotationEditingDidFail()
                showFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func finishAnnotatedCapture(image: CGImage, action: CaptureAction, displaySize: CGSize) {
        closeOverlays()
        do {
            try output(image, action: action, pinDisplaySize: displaySize)
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
                    try await Task.sleep(for: .milliseconds(50))
                    image = try await makeScreenshot(globalRect: rect)
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
        pinDisplaySize: CGSize? = nil
    ) throws {
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

    private func makeScreenshot(globalRect: CGRect) async throws -> CGImage {
        let capturer = try await ScreenRegionCapturer(globalRect: globalRect)
        return try await capturer.capture()
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
            window.onGIFCaptureRequested = nil
            window.orderOut(nil)
        }

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
    case gifCapture
}

final class SelectionOverlayWindow: NSWindow {
    var onSelectionFinished: ((CGRect, CaptureAction) -> Void)?
    var onSelectionCancelled: (() -> Void)?
    var onEditingRequested: ((CGRect, AnnotationTool) -> Void)?
    var onAnnotatedFinished: ((CGImage, CaptureAction, CGSize) -> Void)?
    var onAnnotationFailed: ((Error) -> Void)?
    var onOCRRequested: ((OCRSource) -> Void)?
    var onLongCaptureRequested: ((CGRect) -> Void)?
    var onGIFCaptureRequested: ((CGRect) -> Void)?

    private var overlayView: SelectionOverlayView? {
        contentView as? SelectionOverlayView
    }

    init(screen: NSScreen, purpose: SelectionPurpose = .regular) {
        let view = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            purpose: purpose
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
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

        view.onSelectionFinished = { [weak self] rect, action in
            self?.onSelectionFinished?(rect, action)
        }
        view.onSelectionCancelled = { [weak self] in
            self?.onSelectionCancelled?()
        }
        view.onEditingRequested = { [weak self] rect, tool in
            self?.onEditingRequested?(rect, tool)
        }
        view.onAnnotatedFinished = { [weak self] image, action, displaySize in
            self?.onAnnotatedFinished?(image, action, displaySize)
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
        view.onGIFCaptureRequested = { [weak self] rect in
            self?.onGIFCaptureRequested?(rect)
        }
    }

    func enterAnnotationEditing(baseImage: CGImage, initialTool: AnnotationTool) {
        overlayView?.enterAnnotationEditing(baseImage: baseImage, initialTool: initialTool)
    }

    func annotationEditingDidFail() {
        overlayView?.annotationEditingDidFail()
    }

    override var canBecomeKey: Bool { true }
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

    var onSelectionFinished: ((CGRect, CaptureAction) -> Void)?
    var onSelectionCancelled: (() -> Void)?
    var onEditingRequested: ((CGRect, AnnotationTool) -> Void)?
    var onAnnotatedFinished: ((CGImage, CaptureAction, CGSize) -> Void)?
    var onAnnotationFailed: ((Error) -> Void)?
    var onOCRRequested: ((OCRSource) -> Void)?
    var onLongCaptureRequested: ((CGRect) -> Void)?
    var onGIFCaptureRequested: ((CGRect) -> Void)?

    private let purpose: SelectionPurpose
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var dragOperation: DragOperation?
    private var moveAnchorPoint: NSPoint?
    private var moveInitialRect: CGRect?
    private var resizeInitialRect: CGRect?
    private var isSelectionFinalized = false
    private var isPreselected = false
    private var preselectClickStart: CGPoint?
    private var isGIFConfirming = false
    private var isPreparingAnnotation = false
    private var isSubmitting = false
    private var annotationCanvas: AnnotationCanvasView?
    private var frozenScreenImage: CGImage?
    private var activeAnnotationTool: AnnotationTool = .select
    private var annotationStyles: [AnnotationTool: AnnotationStyle] = Dictionary(
        uniqueKeysWithValues: AnnotationTool.drawingTools.map {
            ($0, AnnotationStylePreferences.load(for: $0))
        }
    )
    private lazy var actionBar = makeActionBar()
    private lazy var longCaptureBar: LongCaptureStartBar = {
        let hint: String
        let title: String
        switch purpose {
        case .gifCapture:
            hint = "框选录制区域 · 最长 30 秒"
            title = "录制 GIF"
        default:
            hint = "框内内容需全部能够上下滚动"
            title = "开始长截图"
        }
        let bar = LongCaptureStartBar(frame: CGRect(x: 0, y: 0, width: 430, height: 48), hint: hint, startTitle: title)
        bar.onStart = { [weak self] in self?.requestLongCapture() }
        bar.onCancel = { [weak self] in self?.onSelectionCancelled?() }
        return bar
    }()
    private lazy var gifConfirmBar: LongCaptureStartBar = {
        let bar = LongCaptureStartBar(
            frame: CGRect(x: 0, y: 0, width: 430, height: 48),
            hint: "点击「录制 GIF」开始 · 最长 30 秒",
            startTitle: "录制 GIF"
        )
        bar.onStart = { [weak self] in
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
            self.onGIFCaptureRequested?(globalRect)
        }
        bar.onCancel = { [weak self] in
            guard let self else { return }
            self.isGIFConfirming = false
            self.gifConfirmBar.isHidden = true
            if let selection = self.currentSelection() {
                self.positionSelectionControls(for: selection)
            }
        }
        return bar
    }()
    private let infoAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white
    ]
    private let handleHitHalfSize: CGFloat = 10

    init(frame frameRect: NSRect, purpose: SelectionPurpose = .regular) {
        self.purpose = purpose
        super.init(frame: frameRect)
        switch purpose {
        case .regular:
            addSubview(actionBar)
            actionBar.isHidden = true
            addSubview(gifConfirmBar)
            gifConfirmBar.isHidden = true
            preselectFullScreenIfNeeded()
        case .longCapture, .gifCapture:
            addSubview(longCaptureBar)
            longCaptureBar.isHidden = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isSelectionFinalized, selectionHandle(at: point) != nil {
            return self
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if isSelectionFinalized, let selection = currentSelection() {
            // A preselected full-screen region is not draggable; keep the
            // crosshair so the user can immediately drag out a new selection.
            if !isPreselected {
                addCursorRect(selection, cursor: .openHand)
            }
            for (handle, point) in selectionHandlePoints(for: selection) {
                let cursor: NSCursor
                switch handle {
                case .left, .right:
                    cursor = .resizeLeftRight
                case .top, .bottom:
                    cursor = .resizeUpDown
                case .topLeft, .bottomRight:
                    cursor = AnnotationCursorFactory.cursor(for: .resizeDiagonalDown)
                case .topRight, .bottomLeft:
                    cursor = AnnotationCursorFactory.cursor(for: .resizeDiagonalUp)
                }
                addCursorRect(
                    CGRect(
                        x: point.x - handleHitHalfSize,
                        y: point.y - handleHitHalfSize,
                        width: handleHitHalfSize * 2,
                        height: handleHitHalfSize * 2
                    ),
                    cursor: cursor
                )
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        preselectFullScreenIfNeeded()
        window?.invalidateCursorRects(for: self)
    }

    /// On launch the regular capture overlay preselects the whole screen so
    /// the user can confirm immediately (like iShot/Xnip) or drag to refine.
    /// Long-capture/GIF overlays still start empty because their region must
    /// be chosen deliberately.
    private func preselectFullScreenIfNeeded() {
        guard purpose == .regular,
              !isSelectionFinalized,
              startPoint == nil,
              bounds.width > 0,
              bounds.height > 0 else { return }
        startPoint = .zero
        currentPoint = CGPoint(x: bounds.maxX, y: bounds.maxY)
        isSelectionFinalized = true
        isPreselected = true
        // Don't show the toolbar yet — like iShot/Xnip, the user clicks
        // once to enter annotation mode or drags to draw a new region.
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isPreparingAnnotation else { return }
        let location = convert(event.locationInWindow, from: nil)

        if isSelectionFinalized,
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
                if purpose == .longCapture || purpose == .gifCapture {
                    requestLongCapture()
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
        hideSelectionControls()
        startPoint = location
        currentPoint = startPoint
        window?.invalidateCursorRects(for: self)
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
            }
            needsDisplay = true
            return
        }

        switch dragOperation {
        case .selecting:
            guard startPoint != nil else { return }
            currentPoint = location
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
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }

        if case .resizing(let handle) = dragOperation {
            resizeSelection(handle: handle, to: location)
            updateAnnotationCanvasForCurrentSelection()
            dragOperation = nil
            resizeInitialRect = nil
            if let selection = currentSelection() {
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
            hideSelectionControls()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }

        isSelectionFinalized = true
        positionSelectionControls(for: selection)
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.34).setFill()
        guard let selection = currentSelection() else {
            bounds.fill()
            let hint = purpose == .longCapture
                ? "拖动选择可滚动区域，Esc 取消"
                : "拖动选择截图区域，Esc 取消"
            drawHint(hint, at: NSPoint(x: bounds.midX - 110, y: bounds.midY))
            return
        }

        let dimmedArea = NSBezierPath(rect: bounds)
        dimmedArea.append(NSBezierPath(rect: selection))
        dimmedArea.windingRule = .evenOdd
        dimmedArea.fill()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()

        if isSelectionFinalized, annotationCanvas == nil {
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
                onAnnotatedFinished?(image, action, selection.size)
            } catch {
                isSubmitting = false
                actionBar.setBusy(false)
                onAnnotationFailed?(error)
            }
            return
        }

        guard let globalRect = currentGlobalSelectionRect() else { return }
        onSelectionFinished?(globalRect, action)
    }

    func enterAnnotationEditing(baseImage: CGImage, initialTool: AnnotationTool) {
        guard annotationCanvas == nil,
              let selection = currentSelection() else { return }

        isPreparingAnnotation = false
        actionBar.setBusy(false)
        actionBar.setLongCaptureEnabled(false)
        actionBar.setGIFEnabled(false)
        frozenScreenImage = baseImage
        guard let croppedImage = croppedFrozenImage(for: selection) else {
            onAnnotationFailed?(NSError(
                domain: "SnapInk.Annotation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法裁剪标注截图区域。"]
            ))
            return
        }
        let canvas = AnnotationCanvasView(
            frame: selection,
            baseImage: croppedImage,
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
        annotationCanvas.updateCaptureArea(
            frame: selection,
            baseImage: croppedImage,
            logicalOrigin: logicalOrigin(for: selection)
        )
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
        actionBar.setLongCaptureEnabled(true)
        actionBar.setGIFEnabled(true)
    }

    private func requestAnnotationEditing(tool: AnnotationTool) {
        guard tool != .select,
              annotationCanvas == nil,
              !isPreparingAnnotation,
              let globalRect = currentGlobalSelectionRect() else { return }
        isPreparingAnnotation = true
        actionBar.setBusy(true)
        onEditingRequested?(globalRect, tool)
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
        let width = min(650, max(520, bounds.width - 16))
        let bar = AnnotationToolbarView(frame: NSRect(x: 0, y: 0, width: width, height: 82))
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
            self?.showGIFConfirmBar()
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
        bar.onPreferredSizeChanged = { [weak self] in
            guard let self, let selection = self.currentSelection() else { return }
            self.positionSelectionControls(for: selection)
        }
        return bar
    }

    private func positionSelectionControls(for selection: CGRect) {
        let controls: NSView
        if purpose == .longCapture || purpose == .gifCapture {
            controls = longCaptureBar
        } else if isGIFConfirming {
            controls = gifConfirmBar
        } else {
            controls = actionBar
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
    }

    private func hideSelectionControls() {
        switch purpose {
        case .regular:
            actionBar.isHidden = true
            gifConfirmBar.isHidden = true
        case .longCapture, .gifCapture:
            longCaptureBar.isHidden = true
        }
    }

    /// Switch from the annotation toolbar to a "录制 GIF" confirm bar
    /// that reuses the current selection (no re-drawing needed).
    private func showGIFConfirmBar() {
        guard purpose == .regular,
              isSelectionFinalized,
              !isSubmitting,
              let selection = currentSelection(),
              selection.width >= 80,
              selection.height >= 80 else {
            NSSound.beep()
            return
        }
        actionBar.isHidden = true
        isGIFConfirming = true
        positionSelectionControls(for: selection)
        needsDisplay = true
    }

    private func requestLongCapture() {
        let needsBar = (purpose == .longCapture || purpose == .gifCapture)
        guard (needsBar || annotationCanvas == nil),
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
        if purpose == .gifCapture {
            onGIFCaptureRequested?(globalRect)
        } else {
            onLongCaptureRequested?(globalRect)
        }
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
