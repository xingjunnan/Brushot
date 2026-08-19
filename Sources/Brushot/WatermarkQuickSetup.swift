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
    private let onApply: (WatermarkConfiguration) -> Void
    private let onDismiss: () -> Void

    private let textField = NSTextField()
    private let logoLabel = NSTextField(labelWithString: "")
    private let removeLogoButton = NSButton()
    private let validationLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton()
    private var draftConfiguration: WatermarkConfiguration
    private var draftImportedLogoURL: URL?
    private var isCommitted = false

    init(
        context: WatermarkQuickSetupContext,
        configuration: WatermarkConfiguration,
        onApply: @escaping (WatermarkConfiguration) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.context = context
        self.initialConfiguration = configuration
        self.draftConfiguration = configuration
        self.onApply = onApply
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 410, height: 232)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L.text("设置水印"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitle = NSTextField(labelWithString: context.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        textField.stringValue = draftConfiguration.text
        textField.placeholderString = L.text("例如：Brushot {datetime}")
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.text")
        textField.font = .systemFont(ofSize: 13)
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

        validationLabel.stringValue = L.text("请添加文字或 Logo；位置、透明度和大小沿用水印设置")
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.validation")

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
            [makeFormLabel("Logo"), logoControls]
        ])
        form.columnSpacing = 12
        form.rowSpacing = 10
        form.column(at: 0).width = 48
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [header, form, validationLabel, separator, buttons])
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
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = content
        updateValidationState()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateValidationState()
    }

    func discardUncommittedChanges() {
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
            ?? L.text("请添加文字或 Logo；位置、透明度和大小沿用水印设置")
        validationLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
        removeLogoButton.isHidden = draftConfiguration.logoURL == nil
    }

    @objc private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        if let level = view.window?.level {
            panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
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
        draftConfiguration.text = textField.stringValue
        isCommitted = true
        if initialConfiguration.logoURL != draftConfiguration.logoURL {
            WatermarkPreferences.removeLogoFileIfManaged(initialConfiguration.logoURL)
        }
        onApply(draftConfiguration)
        onDismiss()
    }
}

@MainActor
final class WatermarkQuickSetupPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let controller: WatermarkQuickSetupViewController
    private let onClose: () -> Void

    init(
        context: WatermarkQuickSetupContext,
        configuration: WatermarkConfiguration,
        onApply: @escaping (WatermarkConfiguration) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        var dismiss: (() -> Void)!
        controller = WatermarkQuickSetupViewController(
            context: context,
            configuration: configuration,
            onApply: onApply,
            onDismiss: { dismiss?() }
        )
        super.init()
        dismiss = { [weak self] in self?.popover.performClose(nil) }
        popover.behavior = .transient
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
