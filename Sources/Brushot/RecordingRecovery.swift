import Foundation

enum RecordingRecoveryStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brushot", isDirectory: true)
            .appendingPathComponent("RecordingRecovery", isDirectory: true)
    }

    static func makeURL(prefix: String, extension pathExtension: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent("Brushot-\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    static func recoverableFiles(now: Date = Date()) -> [URL] {
        recoverableFiles(in: directory, now: now)
    }

    static func recoverableFiles(in directory: URL, now: Date = Date()) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let expiration = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var recoverable: [(URL, Date)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (values?.fileSize ?? 0) > 0 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < expiration {
                try? FileManager.default.removeItem(at: file)
            } else if ["mov", "mp4", "gif"].contains(file.pathExtension.lowercased()) {
                recoverable.append((file, modified))
            }
        }
        return recoverable.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func migrateLegacyTemporaryFiles() {
        let temporary = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("Brushot-Recording-")
            || file.lastPathComponent.hasPrefix("Brushot-Export-") {
            let destination = makeURL(prefix: "Recovered", extension: file.pathExtension)
            try? FileManager.default.moveItem(at: file, to: destination)
        }
    }
}
