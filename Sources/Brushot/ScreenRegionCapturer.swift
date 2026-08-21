import AppKit
import CoreGraphics
import ScreenCaptureKit

enum RecordingCaptureTarget: Equatable, Sendable {
    case region(globalRect: CGRect)
    case window(id: CGWindowID, globalRect: CGRect, title: String)

    var globalRect: CGRect {
        switch self {
        case .region(let rect), .window(_, let rect, _): rect
        }
    }

    var displayName: String {
        switch self {
        case .region: L.text("所选区域")
        case .window(_, _, let title): title
        }
    }
}

/// Prepares a ScreenCaptureKit filter once and reuses it for every frame in a
/// scrolling capture. Reusing the filter avoids repeatedly enumerating all
/// shareable windows while the user is actively scrolling.
@MainActor
final class ScreenRegionCapturer {
    /// `SCStreamConfiguration.backgroundColor` is an unsafe, non-retaining
    /// Core Graphics reference, so the color must outlive every capture.
    private static let windowBackgroundColor = CGColor(gray: 0, alpha: 1)

    private enum FilterMode {
        case region
        case window(id: CGWindowID, displaySourceRect: CGRect)
    }

    let logicalSize: CGSize
    let pixelScale: CGFloat

    private let display: SCDisplay
    private var contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var preparedOverlayExclusion = false
    private let filterMode: FilterMode
    /// Window IDs that should remain visible in the recording even when all
    /// other Brushot windows are excluded (e.g. the GIF annotation overlay).
    var exceptedWindowIDs: Set<CGWindowID> = []

    /// Exposed so the GIF recorder can build a long-running stream from the
    /// same filter/config (source rect, scale, exclusion of Brushot overlays)
    /// already prepared for this selection.
    var captureContentFilter: SCContentFilter { contentFilter }
    var streamConfiguration: SCStreamConfiguration { configuration }

    convenience init(globalRect: CGRect) async throws {
        try await self.init(target: .region(globalRect: globalRect))
    }

    init(target: RecordingCaptureTarget) async throws {
        let globalRect = target.globalRect
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(globalRect) }),
              let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw Self.captureError(L.text("无法确定截图所在的显示器。"))
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw Self.captureError(L.text("无法读取截图所在的显示器。"))
        }

        let displaySourceRect = CGRect(
            x: globalRect.intersection(screen.frame).minX - screen.frame.minX,
            y: screen.frame.maxY - globalRect.intersection(screen.frame).maxY,
            width: globalRect.intersection(screen.frame).width,
            height: globalRect.intersection(screen.frame).height
        ).integral
        let filter: SCContentFilter
        let mode: FilterMode
        var windowCaptureSize: CGSize?
        switch target {
        case .region:
            let currentApplication = shareableContent.applications.first {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: currentApplication.map { [$0] } ?? [],
                exceptingWindows: []
            )
            mode = .region
        case .window(let id, _, _):
            guard let selectedWindow = shareableContent.windows.first(where: { $0.windowID == id }) else {
                throw Self.captureError(L.text("所选窗口已关闭，请重新选择。"))
            }
            filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
            windowCaptureSize = selectedWindow.frame.size
            mode = .window(id: id, displaySourceRect: displaySourceRect)
        }

        let selection = globalRect.intersection(screen.frame).integral
        guard !selection.isNull, selection.width >= 1, selection.height >= 1 else {
            throw Self.captureError(L.text("截图区域无效。"))
        }
        let captureSize = windowCaptureSize ?? selection.size
        let sourceRect: CGRect
        if case .window = target {
            sourceRect = CGRect(origin: .zero, size: captureSize).integral
        } else {
            sourceRect = CGRect(
                x: selection.minX - screen.frame.minX,
                y: screen.frame.maxY - selection.maxY,
                width: selection.width,
                height: selection.height
            ).integral
        }

        let scale: CGFloat
        if #available(macOS 14.0, *) {
            scale = CGFloat(filter.pointPixelScale)
        } else {
            scale = screen.backingScaleFactor
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = sourceRect
        streamConfiguration.width = max(1, Int((sourceRect.width * scale).rounded()))
        streamConfiguration.height = max(1, Int((sourceRect.height * scale).rounded()))
        streamConfiguration.showsCursor = false
        streamConfiguration.queueDepth = 1
        if case .window = target {
            // A display filter is used after the annotation overlay appears.
            // Fill the parts of that display crop not covered by the selected
            // window with black instead of ScreenCaptureKit's opaque white.
            streamConfiguration.backgroundColor = Self.windowBackgroundColor
        }
        if #available(macOS 14.0, *) {
            streamConfiguration.captureResolution = .best
            if case .window = target {
                streamConfiguration.ignoreShadowsSingleWindow = true
                // `shouldBeOpaque` always backs transparency with white. The
                // explicit opaque black background above already guarantees an
                // opaque video frame without introducing a white canvas.
                streamConfiguration.shouldBeOpaque = false
            } else {
                streamConfiguration.ignoreShadowsDisplay = true
                streamConfiguration.shouldBeOpaque = true
            }
        }

        logicalSize = captureSize
        pixelScale = scale
        self.display = display
        contentFilter = filter
        configuration = streamConfiguration
        filterMode = mode
    }

    /// The first frame is captured before Brushot's live border and preview
    /// windows exist. Once those windows are visible, rebuild the filter once
    /// so all subsequent scrolling frames exclude Brushot itself.
    func prepareForOverlayExclusion() async {
        try? await prepareForRecordingOverlay()
    }

    /// Rebuilds the source filter after the transparent annotation window is
    /// visible. Region capture excludes the rest of Brushot while keeping that
    /// one window; window capture explicitly composites it with the
    /// selected source so live drawings remain in the encoded frames.
    func prepareForRecordingOverlay() async throws {
        guard !preparedOverlayExclusion else { return }
        do {
            let shareableContent = try await shareableContentWaitingForExceptedWindows()
            let processID = ProcessInfo.processInfo.processIdentifier
            let annotationWindows = shareableContent.windows.filter {
                exceptedWindowIDs.contains($0.windowID)
            }
            switch filterMode {
            case .region:
                if let application = shareableContent.applications.first(where: {
                    $0.processID == processID
                }) {
                    contentFilter = SCContentFilter(
                        display: display,
                        excludingApplications: [application],
                        exceptingWindows: annotationWindows
                    )
                } else {
                    let ownWindows = shareableContent.windows.filter {
                        $0.owningApplication?.processID == processID
                            && !exceptedWindowIDs.contains($0.windowID)
                    }
                    if !ownWindows.isEmpty {
                        contentFilter = SCContentFilter(display: display, excludingWindows: ownWindows)
                    }
                }
            case .window(let id, let displaySourceRect):
                guard let selectedWindow = shareableContent.windows.first(where: { $0.windowID == id }) else {
                    throw Self.captureError(L.text("所选窗口已关闭，请重新选择。"))
                }
                contentFilter = SCContentFilter(
                    display: display,
                    including: [selectedWindow] + annotationWindows
                )
                configuration.sourceRect = displaySourceRect
            }
        } catch {
            throw error
        }
        preparedOverlayExclusion = true
    }

    /// ScreenCaptureKit can briefly lag behind AppKit after a new transparent
    /// overlay is ordered front. Wait until every requested overlay has become
    /// shareable before building the final recording filter; otherwise the
    /// recording starts successfully but live drawings never reach the video.
    private func shareableContentWaitingForExceptedWindows() async throws -> SCShareableContent {
        for attempt in 0..<10 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let availableWindowIDs = Set(content.windows.map(\.windowID))
            if exceptedWindowIDs.isSubset(of: availableWindowIDs) {
                return content
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(60))
            }
        }
        throw Self.captureError(L.text("无法准备录制标注层，请重试。"))
    }

    func capture() async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            )
        }
        return try await StreamScreenshotCapturer.capture(
            contentFilter: contentFilter,
            configuration: configuration
        )
    }

    private static func captureError(_ message: String) -> NSError {
        NSError(
            domain: "Brushot.Capture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
