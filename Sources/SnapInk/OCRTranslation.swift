import AppKit
import SwiftUI
@preconcurrency import Translation

typealias OCRTranslationHandler = @MainActor (String) async throws -> String

@MainActor
enum OCRTranslationProvider {
    case system
    case unavailable
    case custom(OCRTranslationHandler)
}

@available(macOS 15.0, *)
@MainActor
final class SystemOCRTranslator: ObservableObject {
    fileprivate struct RequestSnapshot: Sendable {
        let id: UUID
        let text: String
    }

    private struct PendingRequest {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    @Published fileprivate var configuration: TranslationSession.Configuration?
    private var pendingRequest: PendingRequest?

    func makeHostView() -> NSView {
        NSHostingView(rootView: SystemOCRTranslationHost(translator: self))
    }

    func translate(_ text: String) async throws -> String {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancelPendingRequest()
                pendingRequest = PendingRequest(
                    id: requestID,
                    text: text,
                    continuation: continuation
                )

                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: "zh-Hans")
                    )
                } else {
                    configuration?.invalidate()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: requestID)
            }
        }
    }

    fileprivate func requestSnapshot() -> RequestSnapshot? {
        pendingRequest.map { RequestSnapshot(id: $0.id, text: $0.text) }
    }

    private func cancelPendingRequest() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        request.continuation.resume(throwing: CancellationError())
    }

    private func cancelRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        cancelPendingRequest()
    }

    fileprivate func finishRequest(id: UUID, result: Result<String, Error>) {
        guard let request = pendingRequest, request.id == id else { return }
        pendingRequest = nil
        request.continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
private struct SystemOCRTranslationHost: View {
    @ObservedObject var translator: SystemOCRTranslator

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(translator.configuration) { session in
                guard let request = translator.requestSnapshot() else { return }
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(request.text)
                    translator.finishRequest(
                        id: request.id,
                        result: .success(response.targetText)
                    )
                } catch {
                    translator.finishRequest(id: request.id, result: .failure(error))
                }
            }
    }
}

@MainActor
struct OCRTranslationIntegration {
    let handler: OCRTranslationHandler?
    let hostView: NSView?

    static func make(for provider: OCRTranslationProvider) -> OCRTranslationIntegration {
        switch provider {
        case .unavailable:
            return OCRTranslationIntegration(handler: nil, hostView: nil)
        case .custom(let handler):
            return OCRTranslationIntegration(handler: handler, hostView: nil)
        case .system:
            if #available(macOS 15.0, *) {
                let translator = SystemOCRTranslator()
                return OCRTranslationIntegration(
                    handler: { text in try await translator.translate(text) },
                    hostView: translator.makeHostView()
                )
            }
            return OCRTranslationIntegration(handler: nil, hostView: nil)
        }
    }
}
