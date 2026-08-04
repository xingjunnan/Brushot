import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Prepares a ScreenCaptureKit filter once and reuses it for every frame in a
/// scrolling capture. Reusing the filter avoids repeatedly enumerating all
/// shareable windows while the user is actively scrolling.
@MainActor
final class ScreenRegionCapturer {
    let logicalSize: CGSize
    let pixelScale: CGFloat

    private let display: SCDisplay
    private var contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var preparedOverlayExclusion = false

    init(globalRect: CGRect) async throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(globalRect) }),
              let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw Self.captureError("无法确定截图所在的显示器。")
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw Self.captureError("无法读取截图所在的显示器。")
        }

        let currentApplication = shareableContent.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: currentApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let selection = globalRect.intersection(screen.frame).integral
        guard !selection.isNull, selection.width >= 1, selection.height >= 1 else {
            throw Self.captureError("截图区域无效。")
        }
        let sourceRect = CGRect(
            x: selection.minX - screen.frame.minX,
            y: screen.frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        ).integral

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
        if #available(macOS 14.0, *) {
            streamConfiguration.captureResolution = .best
            streamConfiguration.ignoreShadowsDisplay = true
            streamConfiguration.shouldBeOpaque = true
        }

        logicalSize = selection.size
        pixelScale = scale
        self.display = display
        contentFilter = filter
        configuration = streamConfiguration
    }

    /// The first frame is captured before SnapInk's live border and preview
    /// windows exist. Once those windows are visible, rebuild the filter once
    /// so all subsequent scrolling frames exclude SnapInk itself.
    func prepareForOverlayExclusion() async {
        guard !preparedOverlayExclusion else { return }
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let processID = ProcessInfo.processInfo.processIdentifier
            if let application = shareableContent.applications.first(where: {
                $0.processID == processID
            }) {
                contentFilter = SCContentFilter(
                    display: display,
                    excludingApplications: [application],
                    exceptingWindows: []
                )
            } else {
                let ownWindows = shareableContent.windows.filter {
                    $0.owningApplication?.processID == processID
                }
                if !ownWindows.isEmpty {
                    contentFilter = SCContentFilter(display: display, excludingWindows: ownWindows)
                }
            }
        } catch {
            // The border is also drawn outside the source rectangle, so a
            // transient content-enumeration failure must not abort capture.
        }
        preparedOverlayExclusion = true
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
            domain: "SnapInk.Capture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
