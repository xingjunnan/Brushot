import AppKit
import CoreGraphics
import Vision

struct OCRResult: Equatable, Sendable {
    let lines: [String]

    var text: String {
        lines.joined(separator: "\n")
    }

    init(lines: [String]) throws {
        let normalizedLines = lines.compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard !normalizedLines.isEmpty else {
            throw OCRRecognitionError.noText
        }
        self.lines = normalizedLines
    }
}

enum OCRRecognitionError: LocalizedError, Equatable {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText:
            return L.text("当前区域未识别到文字。")
        }
    }
}

protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> OCRResult
}

final class VisionTextRecognizer: TextRecognizing, @unchecked Sendable {
    static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    private let queue = DispatchQueue(
        label: "com.snapink.ocr",
        qos: .userInitiated
    )

    func recognizeText(in image: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try Self.recognizeSynchronously(in: image))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func supportedPreferredLanguages(from supportedLanguages: [String]) -> [String] {
        let supported = Set(supportedLanguages)
        return preferredLanguages.filter(supported.contains)
    }

    private static func recognizeSynchronously(in image: CGImage) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        let languages = supportedPreferredLanguages(from: try request.supportedRecognitionLanguages())
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = request.results?.compactMap {
            $0.topCandidates(1).first?.string
        } ?? []
        return try OCRResult(lines: lines)
    }
}

@MainActor
final class OCRResultWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let textView = NSTextView()
    private let copyButton = NSButton(title: L.text("复制"), target: nil, action: nil)
    private let translatedTextView = NSTextView()
    private let translateButton = NSButton(title: L.text("翻译成中文"), target: nil, action: nil)
    private let copyTranslationButton = NSButton(title: L.text("复制译文"), target: nil, action: nil)
    private let translationHandler: OCRTranslationHandler?
    private let translationHostView: NSView?
    private var translationTask: Task<Void, Never>?
    private var translationGeneration = 0

    var translatedText: String {
        get { translatedTextView.string }
        set {
            translatedTextView.string = newValue
            translatedTextView.setSelectedRange(NSRange(location: 0, length: 0))
            copyTranslationButton.isEnabled = !newValue.isEmpty
        }
    }

    var text: String {
        get { textView.string }
        set {
            invalidateTranslation()
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    init(text: String, translationProvider: OCRTranslationProvider = .system) {
        let integration = OCRTranslationIntegration.make(for: translationProvider)
        translationHandler = integration.handler
        translationHostView = integration.hostView
        let translationEnabled = integration.handler != nil
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: translationEnabled ? 640 : 560,
                height: translationEnabled ? 360 : 380
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.text("OCR 文字识别")
        window.minSize = translationEnabled
            ? NSSize(width: 560, height: 320)
            : NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        configureContent()
        self.text = text
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        self.text = text
    }

    @discardableResult
    func copyText(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(textView.string, forType: .string)
    }

    @discardableResult
    func copyTranslatedText(to pasteboard: NSPasteboard = .general) -> Bool {
        guard !translatedTextView.string.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(translatedTextView.string, forType: .string)
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === textView else { return }
        invalidateTranslation()
    }

    func windowWillClose(_ notification: Notification) {
        invalidateTranslation()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let sourceScrollView = makeTextScrollView(for: textView)
        textView.delegate = self

        let closeButton = NSButton(title: L.text("关闭"), target: self, action: #selector(closeAction))
        closeButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyAction)
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.identifier = NSUserInterfaceItemIdentifier("copyOCRAction")

        var buttons = [closeButton]
        if translationHandler != nil {
            copyButton.title = L.text("复制原文")
            copyButton.keyEquivalent = ""
            translateButton.target = self
            translateButton.action = #selector(translateAction)
            translateButton.bezelStyle = .rounded
            translateButton.identifier = NSUserInterfaceItemIdentifier("translateOCRAction")

            copyTranslationButton.target = self
            copyTranslationButton.action = #selector(copyTranslationAction)
            copyTranslationButton.bezelStyle = .rounded
            copyTranslationButton.identifier = NSUserInterfaceItemIdentifier("copyTranslationAction")
            copyTranslationButton.isEnabled = false
            buttons.append(contentsOf: [translateButton, copyButton, copyTranslationButton])
        } else {
            buttons.append(copyButton)
        }

        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let editorArea: NSView
        if translationHandler != nil {
            translatedTextView.identifier = NSUserInterfaceItemIdentifier("translatedText")
            let translationScrollView = makeTextScrollView(for: translatedTextView)
            let sourceGroup = makeLabeledEditor(title: L.text("OCR 原文"), scrollView: sourceScrollView)
            let translationGroup = makeLabeledEditor(title: L.text("中文译文"), scrollView: translationScrollView)
            let editorStack = NSStackView(views: [sourceGroup, translationGroup])
            editorStack.orientation = .horizontal
            editorStack.alignment = .top
            editorStack.distribution = .fillEqually
            editorStack.spacing = 14
            editorStack.translatesAutoresizingMaskIntoConstraints = false
            sourceGroup.heightAnchor.constraint(equalTo: editorStack.heightAnchor).isActive = true
            translationGroup.heightAnchor.constraint(equalTo: editorStack.heightAnchor).isActive = true
            editorArea = editorStack

            if let translationHostView {
                translationHostView.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(translationHostView)
                NSLayoutConstraint.activate([
                    translationHostView.widthAnchor.constraint(equalToConstant: 1),
                    translationHostView.heightAnchor.constraint(equalToConstant: 1),
                    translationHostView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    translationHostView.topAnchor.constraint(equalTo: contentView.topAnchor)
                ])
            }
        } else {
            editorArea = sourceScrollView
        }

        contentView.addSubview(editorArea)
        contentView.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            editorArea.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            editorArea.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            editorArea.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            editorArea.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
    }

    private func makeTextScrollView(for editor: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        scrollView.documentView = editor
        return scrollView
    }

    private func makeLabeledEditor(title: String, scrollView: NSScrollView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [label, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func invalidateTranslation() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translatedText = ""
        setTranslationBusy(false)
    }

    private func setTranslationBusy(_ busy: Bool) {
        translateButton.isEnabled = !busy
        translateButton.title = busy ? L.text("正在翻译…") : L.text("翻译成中文")
    }

    private func showTranslationFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.text("翻译失败")
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }

    @objc private func copyAction() {
        guard copyText() else {
            NSSound.beep()
            return
        }
        FeedbackSound.playCopyCompleted()
    }

    @objc private func copyTranslationAction() {
        guard copyTranslatedText() else {
            NSSound.beep()
            return
        }
        FeedbackSound.playCopyCompleted()
    }

    @objc private func translateAction() {
        guard let translationHandler else { return }
        let sourceText = textView.string
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }

        translationGeneration += 1
        let generation = translationGeneration
        translationTask?.cancel()
        translatedText = ""
        setTranslationBusy(true)
        translationTask = Task { [weak self] in
            do {
                let result = try await translationHandler(sourceText)
                guard let self,
                      !Task.isCancelled,
                      generation == self.translationGeneration else { return }
                self.translationTask = nil
                self.translatedText = result
                self.setTranslationBusy(false)
            } catch is CancellationError {
                guard let self, generation == self.translationGeneration else { return }
                self.translationTask = nil
                self.setTranslationBusy(false)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      generation == self.translationGeneration else { return }
                self.translationTask = nil
                self.setTranslationBusy(false)
                self.showTranslationFailure(error.localizedDescription)
            }
        }
    }

    @objc private func closeAction() {
        close()
    }
}
