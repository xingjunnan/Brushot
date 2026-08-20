import AppKit

enum WatermarkQuickSetupContext {
    case screenshot
    case recording
    case export

    var actionTitle: String {
        switch self {
        case .screenshot:
            L.text("应用到本次截图")
        case .recording:
            L.text("应用并开启录制水印")
        case .export:
            L.text("应用到本次导出")
        }
    }

    var editorTitle: String {
        switch self {
        case .screenshot: L.text("截图水印设置")
        case .recording: L.text("录制水印设置")
        case .export: L.text("导出水印设置")
        }
    }

    var savesAsDefaultInitially: Bool {
        switch self {
        case .screenshot, .recording, .export: false
        }
    }

    var showsSaveAsDefaultOption: Bool {
        switch self {
        case .screenshot, .recording, .export: true
        }
    }

    var subtitle: String {
        switch self {
        case .screenshot:
            L.text("添加文字或 Logo，应用到当前截图")
        case .recording:
            L.text("添加文字或 Logo，用于导出的视频或 GIF")
        case .export:
            L.text("添加文字或 Logo，用于本次导出")
        }
    }
}

@MainActor
final class WatermarkQuickSetupViewController: NSViewController, NSTextFieldDelegate {
    private let context: WatermarkQuickSetupContext
    private let initialConfiguration: WatermarkConfiguration
    private let onApply: (WatermarkConfiguration, Bool) -> Void
    private let onDismiss: () -> Void
    private let onLogoPickerVisibilityChanged: (Bool) -> Void

    private let textField = NSTextField()
    private let logoLabel = NSTextField(labelWithString: "")
    private let removeLogoButton = NSButton()
    private let validationLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton()
    private let saveAsDefaultCheckbox = NSButton(
        checkboxWithTitle: L.text("同时保存为默认水印"),
        target: nil,
        action: nil
    )
    private let previewView = WatermarkEditorPreviewView()
    private let repeatModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let positionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacityLabel = NSTextField(labelWithString: "")
    private let scaleLabel = NSTextField(labelWithString: "")
    private let marginLabel = NSTextField(labelWithString: "")
    private lazy var opacitySlider = NSSlider(
        value: Double(draftConfiguration.opacity),
        minValue: 0.1,
        maxValue: 1,
        target: self,
        action: #selector(styleChanged)
    )
    private lazy var scaleSlider = NSSlider(
        value: Double(draftConfiguration.scale),
        minValue: 0.5,
        maxValue: 2,
        target: self,
        action: #selector(styleChanged)
    )
    private let marginStepper = NSStepper()
    private let colorWell = NSColorWell()
    private var activeLogoPanel: NSOpenPanel?
    private weak var logoPickerEditorWindow: NSWindow?
    private var logoPickerEditorIgnoredMouseEvents = false
    private var logoPickerEditorAlpha: CGFloat = 1
    private var draftConfiguration: WatermarkConfiguration
    private var draftImportedLogoURL: URL?
    private var isCommitted = false

    init(
        context: WatermarkQuickSetupContext,
        configuration: WatermarkConfiguration,
        onApply: @escaping (WatermarkConfiguration, Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onLogoPickerVisibilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.context = context
        self.initialConfiguration = configuration
        self.draftConfiguration = configuration
        self.onApply = onApply
        self.onDismiss = onDismiss
        self.onLogoPickerVisibilityChanged = onLogoPickerVisibilityChanged
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 520, height: 614)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: context.editorTitle)
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitle = NSTextField(labelWithString: context.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        previewView.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.preview")
        previewView.configuration = draftConfiguration
        previewView.heightAnchor.constraint(equalToConstant: 150).isActive = true

        textField.stringValue = draftConfiguration.text
        textField.placeholderString = L.text("例如：Brushot {datetime}")
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.text")
        textField.font = .systemFont(ofSize: 13)
        textField.toolTip = L.format("最多 %d 个字符", WatermarkConfiguration.maxTextLength)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        logoLabel.stringValue = logoDisplayName
        logoLabel.font = .systemFont(ofSize: 12)
        logoLabel.textColor = .secondaryLabelColor
        logoLabel.lineBreakMode = .byTruncatingMiddle
        logoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chooseLogoButton = NSButton(
            title: L.text("选择…"),
            target: self,
            action: #selector(chooseLogo)
        )
        chooseLogoButton.bezelStyle = .rounded
        chooseLogoButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.chooseLogo")
        removeLogoButton.title = L.text("移除")
        removeLogoButton.target = self
        removeLogoButton.action = #selector(removeLogo)
        removeLogoButton.bezelStyle = .rounded
        removeLogoButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.removeLogo")

        let logoIcon = NSImageView()
        logoIcon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        logoIcon.contentTintColor = .secondaryLabelColor
        logoIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        logoIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let logoControls = NSStackView(views: [logoIcon, logoLabel, chooseLogoButton, removeLogoButton])
        logoControls.orientation = .horizontal
        logoControls.alignment = .centerY
        logoControls.spacing = 8

        WatermarkConfiguration.RepeatMode.allCases.forEach { repeatMode in
            repeatModePopUp.addItem(withTitle: repeatMode.title)
            repeatModePopUp.lastItem?.representedObject = repeatMode.rawValue
        }
        repeatModePopUp.selectItem(withTitle: draftConfiguration.repeatMode.title)
        repeatModePopUp.target = self
        repeatModePopUp.action = #selector(styleChanged)
        repeatModePopUp.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.repeatMode")

        WatermarkConfiguration.Position.allCases.forEach { position in
            positionPopUp.addItem(withTitle: position.title)
            positionPopUp.lastItem?.representedObject = position.rawValue
        }
        positionPopUp.selectItem(withTitle: draftConfiguration.position.title)
        positionPopUp.target = self
        positionPopUp.action = #selector(styleChanged)
        positionPopUp.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.position")

        [opacitySlider, scaleSlider].forEach {
            $0.widthAnchor.constraint(equalToConstant: 170).isActive = true
            $0.isContinuous = true
        }
        opacitySlider.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.opacity")
        scaleSlider.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.scale")
        configureValueLabel(opacityLabel, width: 44)
        configureValueLabel(scaleLabel, width: 44)
        configureValueLabel(marginLabel, width: 54)

        marginStepper.minValue = 0
        marginStepper.maxValue = 80
        marginStepper.increment = 2
        marginStepper.doubleValue = Double(draftConfiguration.margin)
        marginStepper.target = self
        marginStepper.action = #selector(styleChanged)
        marginStepper.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.margin")

        colorWell.color = draftConfiguration.textColor
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.textColor")
        colorWell.widthAnchor.constraint(equalToConstant: 54).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell.setContentHuggingPriority(.required, for: .horizontal)

        validationLabel.stringValue = L.text("调整会立即显示在上方预览中")
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.validation")

        saveAsDefaultCheckbox.state = context.savesAsDefaultInitially ? .on : .off
        saveAsDefaultCheckbox.isHidden = !context.showsSaveAsDefaultOption
        saveAsDefaultCheckbox.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.saveAsDefault")

        let cancelButton = NSButton(
            title: L.text("取消"),
            target: self,
            action: #selector(cancel)
        )
        cancelButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.cancel")
        cancelButton.bezelStyle = .rounded
        applyButton.title = context.actionTitle
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        applyButton.contentTintColor = .controlAccentColor
        applyButton.bezelStyle = .rounded
        applyButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.apply")

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let form = NSGridView(views: [
            [makeFormLabel(L.text("文字")), textField],
            [makeFormLabel("Logo"), logoControls],
            [makeFormLabel(L.text("重复方式")), repeatModePopUp],
            [makeFormLabel(L.text("位置")), positionPopUp],
            [makeFormLabel(L.text("透明度")), makeControlRow([opacitySlider, opacityLabel])],
            [makeFormLabel(L.text("大小")), makeControlRow([scaleSlider, scaleLabel])],
            [makeFormLabel(L.text("边距")), makeControlRow([marginLabel, marginStepper])],
            [makeFormLabel(L.text("文字颜色")), makeControlRow([colorWell, NSView()])]
        ])
        form.columnSpacing = 12
        form.rowSpacing = 10
        form.column(at: 0).width = 72
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [
            header,
            previewView,
            form,
            validationLabel,
            saveAsDefaultCheckbox,
            separator,
            buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saveAsDefaultCheckbox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = content
        updateValidationState()
    }

    func controlTextDidChange(_ obj: Notification) {
        textField.stringValue = WatermarkConfiguration.limitedText(textField.stringValue)
        draftConfiguration.text = textField.stringValue
        updateValidationState()
    }

    func discardUncommittedChanges() {
        activeLogoPanel?.cancel(nil)
        activeLogoPanel = nil
        restoreEditorWindowAfterLogoPicker()
        onLogoPickerVisibilityChanged(false)
        guard !isCommitted, let draftImportedLogoURL else { return }
        WatermarkPreferences.removeLogoFileIfManaged(draftImportedLogoURL)
        self.draftImportedLogoURL = nil
    }

    private func makeFormLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func makeControlRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func configureValueLabel(_ label: NSTextField, width: CGFloat) {
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private var logoDisplayName: String {
        guard draftConfiguration.logoURL != nil else { return L.text("未选择") }
        return draftConfiguration.logoDisplayName
            ?? draftConfiguration.logoURL?.lastPathComponent
            ?? L.text("已选择")
    }

    private var hasDraftContent: Bool {
        !textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draftConfiguration.logoURL != nil
    }

    private func updateValidationState(error: String? = nil) {
        applyButton.isEnabled = hasDraftContent
        validationLabel.stringValue = error
            ?? (hasDraftContent
                ? L.format(
                    "调整会立即显示在上方预览中 · %d/%d",
                    textField.stringValue.count,
                    WatermarkConfiguration.maxTextLength
                )
                : L.text("文字和 Logo 至少填写一项"))
        validationLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
        removeLogoButton.isHidden = draftConfiguration.logoURL == nil
        updateDraftStyle()
        previewView.configuration = draftConfiguration
    }

    private func updateDraftStyle() {
        textField.stringValue = WatermarkConfiguration.limitedText(textField.stringValue)
        draftConfiguration.text = textField.stringValue
        if let rawValue = repeatModePopUp.selectedItem?.representedObject as? String,
           let repeatMode = WatermarkConfiguration.RepeatMode(rawValue: rawValue) {
            draftConfiguration.repeatMode = repeatMode
        }
        if let rawValue = positionPopUp.selectedItem?.representedObject as? String,
           let position = WatermarkConfiguration.Position(rawValue: rawValue) {
            draftConfiguration.position = position
        }
        draftConfiguration.opacity = CGFloat(opacitySlider.doubleValue)
        draftConfiguration.scale = CGFloat(scaleSlider.doubleValue)
        draftConfiguration.margin = CGFloat(marginStepper.doubleValue)
        draftConfiguration.textColor = colorWell.color
        positionPopUp.isEnabled = draftConfiguration.repeatMode == .single
        opacityLabel.stringValue = "\(Int(draftConfiguration.opacity * 100))%"
        scaleLabel.stringValue = "\(Int(draftConfiguration.scale * 100))%"
        marginLabel.stringValue = "\(Int(draftConfiguration.margin)) pt"
    }

    @objc private func styleChanged() {
        updateValidationState()
    }

    @objc private func chooseLogo() {
        guard activeLogoPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.level = WatermarkLogoPickerPresentation.level(above: view.window?.level)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        activeLogoPanel = panel
        suspendEditorWindowForLogoPicker()
        onLogoPickerVisibilityChanged(true)
        NSCursor.arrow.set()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            self.activeLogoPanel = nil
            self.restoreEditorWindowAfterLogoPicker()
            self.onLogoPickerVisibilityChanged(false)
            guard response == .OK, let sourceURL = panel?.url else { return }
            self.importLogo(from: sourceURL)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func suspendEditorWindowForLogoPicker() {
        guard let editorWindow = view.window else { return }
        logoPickerEditorWindow = editorWindow
        logoPickerEditorIgnoredMouseEvents = editorWindow.ignoresMouseEvents
        logoPickerEditorAlpha = editorWindow.alphaValue
        editorWindow.ignoresMouseEvents = true
        editorWindow.alphaValue = 0
    }

    private func restoreEditorWindowAfterLogoPicker() {
        guard let editorWindow = logoPickerEditorWindow else { return }
        editorWindow.ignoresMouseEvents = logoPickerEditorIgnoredMouseEvents
        editorWindow.alphaValue = logoPickerEditorAlpha
        editorWindow.makeKeyAndOrderFront(nil)
        logoPickerEditorWindow = nil
    }

    private func importLogo(from sourceURL: URL) {
        do {
            let importedURL = try WatermarkPreferences.importLogo(from: sourceURL)
            if let previousDraftURL = draftImportedLogoURL {
                WatermarkPreferences.removeLogoFileIfManaged(previousDraftURL)
            }
            draftImportedLogoURL = importedURL
            draftConfiguration.logoURL = importedURL
            draftConfiguration.logoDisplayName = sourceURL.lastPathComponent
            logoLabel.stringValue = logoDisplayName
            updateValidationState()
        } catch {
            updateValidationState(error: error.localizedDescription)
        }
    }

    @objc private func removeLogo() {
        if let draftImportedLogoURL {
            WatermarkPreferences.removeLogoFileIfManaged(draftImportedLogoURL)
            self.draftImportedLogoURL = nil
        }
        draftConfiguration.logoURL = nil
        draftConfiguration.logoDisplayName = nil
        logoLabel.stringValue = L.text("未选择")
        updateValidationState()
    }

    @objc private func cancel() {
        discardUncommittedChanges()
        onDismiss()
    }

    @objc private func apply() {
        guard hasDraftContent else {
            updateValidationState(error: L.text("文字和 Logo 至少填写一项"))
            return
        }
        updateDraftStyle()
        isCommitted = true
        let saveAsDefault = saveAsDefaultCheckbox.state == .on
        if saveAsDefault, initialConfiguration.logoURL != draftConfiguration.logoURL {
            WatermarkPreferences.removeLogoFileIfManaged(initialConfiguration.logoURL)
        }
        onApply(draftConfiguration, saveAsDefault)
        onDismiss()
    }
}

@MainActor
final class WatermarkEditorPreviewView: NSView {
    var configuration = WatermarkConfiguration.default {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        shape.fill()

        let width = max(2, Int(bounds.width * 2))
        let height = max(2, Int(bounds.height * 2))
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        let colors = [
            NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.27, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.40, alpha: 1).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors,
            locations: [0, 1]
        ) {
            bitmap.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
        }
        guard let base = bitmap.makeImage() else { return }
        var previewConfiguration = configuration
        previewConfiguration.isEnabled = true
        let output = (try? WatermarkRenderer.render(
            image: base,
            configuration: previewConfiguration
        )) ?? base
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        shape.addClip()
        context.interpolationQuality = .high
        context.draw(output, in: bounds)
        context.restoreGState()
    }
}

@MainActor
final class WatermarkQuickSetupPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let controller: WatermarkQuickSetupViewController
    private let onClose: () -> Void
    var behavior: NSPopover.Behavior { popover.behavior }

    init(
        context: WatermarkQuickSetupContext,
        configuration: WatermarkConfiguration,
        onApply: @escaping (WatermarkConfiguration, Bool) -> Void,
        onClose: @escaping () -> Void,
        onLogoPickerVisibilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onClose = onClose
        var dismiss: (() -> Void)!
        controller = WatermarkQuickSetupViewController(
            context: context,
            configuration: configuration,
            onApply: onApply,
            onDismiss: { dismiss?() },
            onLogoPickerVisibilityChanged: onLogoPickerVisibilityChanged
        )
        super.init()
        dismiss = { [weak self] in self?.popover.performClose(nil) }
        // The editor must stay alive while an NSOpenPanel or NSColorPanel is in
        // front. It closes only through Apply, Cancel, or its owning workflow.
        popover.behavior = .applicationDefined
        popover.contentSize = controller.preferredContentSize
        popover.contentViewController = controller
        popover.delegate = self
    }

    func show(relativeTo view: NSView) {
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        controller.discardUncommittedChanges()
        onClose()
    }
}

enum WatermarkLogoPickerPresentation {
    static func level(above hostLevel: NSWindow.Level?) -> NSWindow.Level {
        NSWindow.Level(rawValue: max(
            NSWindow.Level.screenSaver.rawValue + 2,
            (hostLevel?.rawValue ?? NSWindow.Level.floating.rawValue) + 1
        ))
    }
}
