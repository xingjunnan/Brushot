import AppKit
import XCTest
@testable import SnapInk

@MainActor
final class SelfTimerCaptureTests: XCTestCase {
    func testPreferencesDefaultClampAndPersist() throws {
        let suiteName = "SnapInk.SelfTimerPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SelfTimerPreferences.durationSeconds(defaults: defaults), 5)
        XCTAssertTrue(SelfTimerPreferences.playsTickSound(defaults: defaults))
        SelfTimerPreferences.setDurationSeconds(0, defaults: defaults)
        XCTAssertEqual(SelfTimerPreferences.durationSeconds(defaults: defaults), 1)
        SelfTimerPreferences.setDurationSeconds(90, defaults: defaults)
        XCTAssertEqual(SelfTimerPreferences.durationSeconds(defaults: defaults), 60)
        SelfTimerPreferences.setDurationSeconds(12, defaults: defaults)
        SelfTimerPreferences.setPlaysTickSound(false, defaults: defaults)
        XCTAssertEqual(SelfTimerPreferences.durationSeconds(defaults: defaults), 12)
        XCTAssertFalse(SelfTimerPreferences.playsTickSound(defaults: defaults))
    }

    func testCountdownCompletesOrCancelsOnlyOnce() {
        var completed = SelfTimerCountdownState(duration: 2)
        XCTAssertEqual(completed.advance(), .updated(1))
        XCTAssertEqual(completed.advance(), .completed)
        XCTAssertEqual(completed.advance(), .ignored)
        XCTAssertFalse(completed.cancel())

        var cancelled = SelfTimerCountdownState(duration: 5)
        XCTAssertTrue(cancelled.cancel())
        XCTAssertFalse(cancelled.cancel())
        XCTAssertEqual(cancelled.advance(), .ignored)
    }

    func testScreenGeometryChoosesContainingDisplayAndConvertsCoordinates() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        ]
        XCTAssertEqual(CaptureScreenGeometry.targetIndex(
            at: CGPoint(x: -500, y: 500),
            frames: frames,
            fallbackIndex: 0
        ), 1)
        XCTAssertEqual(CaptureScreenGeometry.targetIndex(
            at: CGPoint(x: 5000, y: 5000),
            frames: frames,
            fallbackIndex: 0
        ), 0)
        XCTAssertEqual(
            CaptureScreenGeometry.localRect(
                CGRect(x: -1800, y: 100, width: 400, height: 300),
                in: frames[1]
            ),
            CGRect(x: 120, y: 100, width: 400, height: 300)
        )
    }

    func testDelayedSelectionUsesDedicatedConfirmationBar() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = SelectionOverlayWindow(screen: screen, purpose: .delayedCapture)
        defer { window.close() }
        window.presetSelection(CGRect(x: 80, y: 80, width: 320, height: 220))
        let descendants = allDescendants(of: try XCTUnwrap(window.contentView))
        XCTAssertNotNil(descendants.first {
            $0.identifier?.rawValue == "startDelayedCaptureAction"
        })
        XCTAssertNil(descendants.compactMap { $0 as? NSButton }.first {
            $0.title == "全屏截图" || $0.title == "延时截图"
        })
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allDescendants(of:))
    }
}
