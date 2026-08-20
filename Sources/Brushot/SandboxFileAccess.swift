import Foundation

/// Handles persistent access to locations selected through an open/save panel.
///
/// A sandbox extension granted by `NSOpenPanel` only lasts for the current
/// process. Persisting the path is therefore insufficient: after the next
/// launch the app must resolve a security-scoped bookmark and retain access to
/// the resolved URL for as long as it may perform automatic exports there.
enum SandboxFileAccess {
    struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    private final class RetainedScopes: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: Set<URL> = []

        func retainAccess(to url: URL) {
            let standardizedURL = url.standardizedFileURL
            lock.lock()
            defer { lock.unlock() }
            guard !urls.contains(standardizedURL) else { return }

            // A non-sandboxed development build commonly returns false here;
            // that build already has filesystem access and needs no token.
            if standardizedURL.startAccessingSecurityScopedResource() {
                urls.insert(standardizedURL)
            }
        }
    }

    private static let retainedScopes = RetainedScopes()

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        retainAccess(to: url)
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    static func retainAccess(to url: URL) {
        retainedScopes.retainAccess(to: url)
    }
}
