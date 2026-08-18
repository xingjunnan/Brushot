import Foundation

struct RecordingEditPlan: Equatable, Sendable {
    var duration: TimeInterval
    var trimStart: TimeInterval
    var trimEnd: TimeInterval
    var deletedRanges: [ClosedRange<TimeInterval>]

    init(
        duration: TimeInterval,
        trimStart: TimeInterval = 0,
        trimEnd: TimeInterval? = nil,
        deletedRanges: [ClosedRange<TimeInterval>] = []
    ) {
        self.duration = max(0, duration)
        self.trimStart = trimStart
        self.trimEnd = trimEnd ?? duration
        self.deletedRanges = deletedRanges
        normalize()
    }

    var hasEdits: Bool {
        trimStart > 0.001 || trimEnd < duration - 0.001 || !deletedRanges.isEmpty
    }

    var outputDuration: TimeInterval {
        retainedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    var retainedRanges: [ClosedRange<TimeInterval>] {
        guard trimEnd - trimStart > 0.001 else { return [] }
        var result: [ClosedRange<TimeInterval>] = []
        var cursor = trimStart
        for deleted in normalizedDeletedRanges {
            if deleted.lowerBound > cursor + 0.001 { result.append(cursor...deleted.lowerBound) }
            cursor = max(cursor, deleted.upperBound)
        }
        if trimEnd > cursor + 0.001 { result.append(cursor...trimEnd) }
        return result
    }

    mutating func setTrimStart(_ value: TimeInterval) {
        trimStart = min(max(0, value), trimEnd - 0.05)
        normalize()
    }

    mutating func setTrimEnd(_ value: TimeInterval) {
        trimEnd = max(trimStart + 0.05, min(duration, value))
        normalize()
    }

    mutating func addDeletedRange(from start: TimeInterval, to end: TimeInterval) {
        let lower = max(trimStart, min(start, end))
        let upper = min(trimEnd, max(start, end))
        guard upper - lower >= 0.05 else { return }
        deletedRanges.append(lower...upper)
        normalize()
    }

    mutating func removeLastDeletedRange() {
        _ = deletedRanges.popLast()
        normalize()
    }

    mutating func clearDeletedRanges() { deletedRanges.removeAll() }

    mutating func normalize() {
        duration = max(0, duration)
        trimStart = min(max(0, trimStart), duration)
        trimEnd = min(duration, max(trimStart, trimEnd))
        deletedRanges = normalizedDeletedRanges
    }

    private var normalizedDeletedRanges: [ClosedRange<TimeInterval>] {
        let clipped = deletedRanges.compactMap { range -> ClosedRange<TimeInterval>? in
            let lower = max(trimStart, min(trimEnd, range.lowerBound))
            let upper = max(trimStart, min(trimEnd, range.upperBound))
            return upper - lower >= 0.001 ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = clipped.first else { return [] }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in clipped.dropFirst() {
            if range.lowerBound <= current.upperBound + 0.001 {
                current = current.lowerBound...max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }
}

struct RecordingGIFOptions: Equatable, Sendable {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var maxWidth: Int
    var framesPerSecond: Double

    init(startTime: TimeInterval, endTime: TimeInterval, maxWidth: Int = 720, framesPerSecond: Double = 15) {
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.maxWidth = max(160, maxWidth)
        self.framesPerSecond = min(30, max(1, framesPerSecond))
    }
}
