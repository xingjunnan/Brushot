import AppKit

enum WatermarkQuickSetupContext {
    case screenshot
    case recording

    var actionTitle: String {
        switch self {
        case .screenshot:
            L.text("应用到本次截图")
        case .recording:
            L.text("应用并开启录制水印")
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
        preferredContentSize = CGSize(width: 390, height: 230)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L.text("设置水印"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        textField.stringValue = draftConfiguration.text
        textField.placeholderString = L.text("例如：Brushot {datetime}")
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.text")

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
        chooseLogoButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.chooseLogo")
        let removeLogoButton = NSButton(
            title: L.text("移除"),
            target: self,
            action: #selector(removeLogo)
        )
        removeLogoButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.removeLogo")

        let logoControls = NSStackView(views: [logoLabel, chooseLogoButton, removeLogoButton])
        logoControls.orientation = .horizontal
        logoControls.alignment = .centerY
        logoControls.spacing = 8

        validationLabel.stringValue = L.text("文字和 Logo 至少填写一项")
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.validation")

        let helper = NSTextField(labelWithString: L.text("位置、透明度和大小沿用水印设置"))
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor

        let cancelButton = NSButton(
            title: L.text("取消"),
            target: self,
            action: #selector(cancel)
        )
        cancelButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.cancel")
        applyButton.title = context.actionTitle
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        applyButton.contentTintColor = .controlAccentColor
        applyButton.identifier = NSUserInterfaceItemIdentifier("watermarkQuick.apply")

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [
            title,
            makeRow(label: L.text("文字"), content: textField),
            makeRow(label: "Logo", content: logoControls),
            validationLabel,
            helper,
            buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 245),
            logoControls.widthAnchor.constraint(greaterThanOrEqualToConstant: 245),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            helper.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    private func makeRow(label: String, content: NSView) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        let row = NSStackView(views: [labelField, content])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
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
        validationLabel.stringValue = error ?? L.text("文字和 Logo 至少填写一项")
        validationLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
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
