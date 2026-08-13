import AppKit
import XCTest
@testable import Brushot

@MainActor
final class AnnotationModelTests: XCTestCase {
    func testDrawingToolInventoryAndShortcutsAreUnique() {
        XCTAssertEqual(AnnotationTool.drawingTools.count, 9)
        XCTAssertEqual(Set(AnnotationTool.allCases.map(\.shortcut)).count, AnnotationTool.allCases.count)
    }

    func testGeometryTranslationAndScaling() {
        let geometry = AnnotationGeometry.path([
            CGPoint(x: 10, y: 20),
            CGPoint(x: 30, y: 40)
        ])
        let translated = geometry.translated(by: CGPoint(x: 5, y: -5))
        XCTAssertEqual(translated.bounds, CGRect(x: 15, y: 15, width: 20, height: 20))

        let scaled = translated.scaled(
            from: translated.bounds,
            to: CGRect(x: 0, y: 0, width: 40, height: 60)
        )
        XCTAssertEqual(scaled.bounds, CGRect(x: 0, y: 0, width: 40, height: 60))
    }

    func testHitTestingUsesShapeSemanticsAndLineTolerance() {
        var style = AnnotationStyle.defaultStyle(for: .rectangle)
        style.fillMode = .stroke
        let rectangle = AnnotationItem(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 10, y: 10, width: 80, height: 50)),
            style: style
        )
        XCTAssertTrue(AnnotationHitTesting.contains(CGPoint(x: 11, y: 30), item: rectangle))
        XCTAssertFalse(AnnotationHitTesting.contains(CGPoint(x: 50, y: 30), item: rectangle))

        let line = AnnotationItem(
            tool: .line,
            geometry: .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90)),
            style: .defaultStyle(for: .line)
        )
        XCTAssertTrue(AnnotationHitTesting.contains(CGPoint(x: 50, y: 52), item: line))
        XCTAssertFalse(AnnotationHitTesting.contains(CGPoint(x: 50, y: 70), item: line))
    }

    func testDocumentUndoRedoAndRedoBranchInvalidation() {
        let document = AnnotationDocument()
        let first = document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 5, y: 5, width: 20, height: 20)),
            style: .defaultStyle(for: .rectangle)
        )
        _ = document.add(
            tool: .ellipse,
            geometry: .rect(CGRect(x: 30, y: 30, width: 20, height: 20)),
            style: .defaultStyle(for: .ellipse)
        )
        XCTAssertEqual(document.items.count, 2)

        document.undo()
        XCTAssertEqual(document.items.map(\.id), [first.id])
        XCTAssertTrue(document.undoManager.canRedo)

        _ = document.add(
            tool: .line,
            geometry: .line(start: .zero, end: CGPoint(x: 20, y: 20)),
            style: .defaultStyle(for: .line)
        )
        XCTAssertEqual(document.items.count, 2)
        XCTAssertFalse(document.undoManager.canRedo)

        document.undo()
        XCTAssertEqual(document.items.count, 1)
        document.redo()
        XCTAssertEqual(document.items.count, 2)
    }

    func testLiveMoveCommitsAsSingleUndoStep() {
        let document = AnnotationDocument()
        var item = document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 5, y: 5, width: 20, height: 20)),
            style: .defaultStyle(for: .rectangle)
        )
        document.undoManager.removeAllActions()
        let original = document.state

        item.geometry = item.geometry.translated(by: CGPoint(x: 10, y: 0))
        document.updateLive(item)
        item.geometry = item.geometry.translated(by: CGPoint(x: 10, y: 0))
        document.updateLive(item)
        document.commitLiveChange(from: original, actionName: "移动标注")

        XCTAssertEqual(document.items[0].geometry.bounds.minX, 25)
        document.undo()
        XCTAssertEqual(document.items[0].geometry.bounds.minX, 5)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testStyleChangesDoNotCreateUndoStepsOrGetOverwrittenByGeometryUndo() {
        let document = AnnotationDocument()
        var item = document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 5, y: 5, width: 20, height: 20)),
            style: .defaultStyle(for: .rectangle)
        )
        document.undoManager.removeAllActions()
        let original = document.state

        item.geometry = item.geometry.translated(by: CGPoint(x: 15, y: 0))
        document.updateLive(item)
        document.commitLiveChange(from: original, actionName: "移动标注")

        var restyled = item.style
        restyled.color = RGBAColor(red: 0, green: 0.478, blue: 1)
        restyled.lineWidth = 9
        document.updateStyle(restyled, for: item.id)
        document.undo()

        XCTAssertEqual(document.items[0].geometry, original.items[0].geometry)
        XCTAssertEqual(document.items[0].style, restyled)
        XCTAssertFalse(document.undoManager.canUndo)

        document.redo()
        XCTAssertEqual(document.items[0].geometry, item.geometry)
        XCTAssertEqual(document.items[0].style, restyled)
    }

    func testStyleChangeAfterAddingDoesNotBlockUndoingTheAddedItem() {
        let document = AnnotationDocument()
        let item = document.add(
            tool: .ellipse,
            geometry: .rect(CGRect(x: 10, y: 10, width: 30, height: 30)),
            style: .defaultStyle(for: .ellipse)
        )
        var style = item.style
        style.opacity = 0.4
        document.updateStyle(style, for: item.id)

        document.undo()
        XCTAssertTrue(document.items.isEmpty)
        document.redo()
        XCTAssertEqual(document.items.first?.style, style)
    }

    func testSequenceNumbersAreNotRenumberedOrReused() {
        let document = AnnotationDocument()
        let style = AnnotationStyle.defaultStyle(for: .sequence)
        _ = document.add(tool: .sequence, geometry: .rect(CGRect(x: 0, y: 0, width: 28, height: 28)), style: style)
        let second = document.add(tool: .sequence, geometry: .rect(CGRect(x: 30, y: 0, width: 28, height: 28)), style: style)
        document.select(second.id)
        document.deleteSelected()
        let third = document.add(tool: .sequence, geometry: .rect(CGRect(x: 60, y: 0, width: 28, height: 28)), style: style)

        guard case .badge(let step) = third.geometry else {
            return XCTFail("Expected badge geometry")
        }
        XCTAssertEqual(step.number, 3)
    }

    func testStepGeometryMovesAndScalesBadgeAndTextAsOneObject() {
        let geometry = AnnotationGeometry.badge(StepAnnotationGeometry(
            badgeFrame: CGRect(x: 10, y: 10, width: 30, height: 30),
            number: 2,
            labelFrame: CGRect(x: 48, y: 10, width: 80, height: 30),
            text: "第二步"
        ))
        let translated = geometry.translated(by: CGPoint(x: 5, y: 7))
        XCTAssertEqual(translated.bounds, CGRect(x: 15, y: 17, width: 118, height: 30))
        let scaled = geometry.scaled(from: geometry.bounds, to: CGRect(x: 0, y: 0, width: 236, height: 60))
        guard case .badge(let step) = scaled else { return XCTFail("Expected step") }
        XCTAssertEqual(step.number, 2)
        XCTAssertEqual(step.badgeFrame.size, CGSize(width: 60, height: 60))
        XCTAssertEqual(step.labelFrame.size, CGSize(width: 160, height: 60))
    }

    func testStylePreferencesRoundTripAndInvalidFallback() throws {
        let suiteName = "BrushotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var style = AnnotationStyle.defaultStyle(for: .arrow)
        style.opacity = 0.42
        style.lineWidth = 7
        style.arrowHeads = .both
        AnnotationStylePreferences.save(style, for: .arrow, defaults: defaults)
        XCTAssertEqual(AnnotationStylePreferences.load(for: .arrow, defaults: defaults), style)

        style.lineWidth = -10
        let invalidData = try JSONEncoder().encode(style)
        defaults.set(invalidData, forKey: "annotation.style.arrow")
        XCTAssertEqual(
            AnnotationStylePreferences.load(for: .arrow, defaults: defaults),
            .defaultStyle(for: .arrow)
        )
    }
}
