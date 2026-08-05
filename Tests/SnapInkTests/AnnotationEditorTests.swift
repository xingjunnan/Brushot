import AppKit
import Carbon
import XCTest
@testable import SnapInk

@MainActor
final class AnnotationEditorTests: XCTestCase {
    func testToolbarCollapsesWithoutStyleControlsAndExpandsForTool() throws {
        let toolbar = AnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 650, height: 82))
        XCTAssertEqual(toolbar.frame.height, 40)
        XCTAssertLessThan(toolbar.frame.width, 680)
        let toolButtons = descendants(of: toolbar).compactMap { $0 as? NSButton }.filter {
            guard let identifier = $0.identifier?.rawValue else { return false }
            return AnnotationTool(rawValue: identifier) != nil
        }
        XCTAssertEqual(toolButtons.count, AnnotationTool.allCases.count)
        XCTAssertTrue(toolButtons.allSatisfy { $0.image != nil })
        for button in toolButtons {
            let rawValue = try XCTUnwrap(button.identifier?.rawValue)
            let tool = try XCTUnwrap(AnnotationTool(rawValue: rawValue))
            let hoverButton = try XCTUnwrap(button as? AnnotationHoverButton)
            XCTAssertNil(hoverButton.toolTip)
            XCTAssertEqual(hoverButton.hoverTitle, tool.title)
            XCTAssertEqual(hoverButton.hoverDelay, 0.05, accuracy: 0.001)
        }
        XCTAssertEqual(AnnotationHoverTooltipPresenter.fontSize, 16)

        toolbar.setTool(.rectangle, style: .defaultStyle(for: .rectangle))
        XCTAssertEqual(toolbar.frame.height, 72)

        toolbar.setTool(.select, style: .defaultStyle(for: .rectangle))
        XCTAssertEqual(toolbar.frame.height, 40)
    }

    func testMenuBarIconUsesCompactTemplateArtwork() throws {
        let image = AppDelegate().makeStatusBarIcon()
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        XCTAssertNotNil(cgImage)
    }

    func testClickingTextCreatesEditorAndCommitsTextAnnotation() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.text, style: .defaultStyle(for: .text))
        canvas.mouseDown(with: try mouseDownEvent(at: CGPoint(x: 30, y: 30)))
        canvas.performPendingSingleClickNow()

        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first)
        let initialWidth = editor.frame.width
        XCTAssertFalse(editor.drawsBackground)
        let value = "这是一段需要完整显示的文字"
        editor.insertText(value, replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, value)
        XCTAssertGreaterThan(editor.frame.width, initialWidth)
        XCTAssertEqual(editor.selectedRange().location, value.utf16.count)
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        let textContainer = try XCTUnwrap(editor.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        XCTAssertLessThanOrEqual(
            usedRect.maxX + editor.textContainerInset.width + 4,
            editor.bounds.width + 0.5
        )
        XCTAssertLessThanOrEqual(
            usedRect.maxY + editor.textContainerInset.height + 2,
            editor.bounds.height + 0.5
        )
        editor.onFinish?(true)

        XCTAssertEqual(canvas.document.items.count, 1)
        guard case .text(_, let value) = canvas.document.items[0].geometry else {
            return XCTFail("Expected text annotation")
        }
        XCTAssertEqual(value, "这是一段需要完整显示的文字")
    }

    func testToolbarPresetColorImmediatelyChangesTextStyle() throws {
        let toolbar = AnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 650, height: 72))
        toolbar.setTool(.text, style: .defaultStyle(for: .text))
        let controls = descendants(of: toolbar)
        XCTAssertTrue(controls.compactMap { $0 as? NSColorWell }.isEmpty)
        XCTAssertEqual(controls.compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("annotationColor.") == true
        }.count, 7)
        var receivedStyle: AnnotationStyle?
        toolbar.onStyleChanged = { receivedStyle = $0 }

        let blueButton = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "annotationColor.5"
        })
        blueButton.performClick(nil)

        let color = try XCTUnwrap(receivedStyle?.color)
        XCTAssertEqual(color.red, 0, accuracy: 0.001)
        XCTAssertEqual(color.green, 0.478, accuracy: 0.001)
        XCTAssertEqual(color.blue, 1, accuracy: 0.001)
    }

    func testToolbarPinButtonInvokesPinAction() throws {
        let toolbar = AnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 650, height: 72))
        var pinCount = 0
        toolbar.onPin = { pinCount += 1 }
        let pinButton = try XCTUnwrap(descendants(of: toolbar).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "pinAction"
        })
        pinButton.performClick(nil)
        XCTAssertEqual(pinCount, 1)
    }

    func testToolbarLongCaptureButtonInvokesActionAndCanBeDisabled() throws {
        let toolbar = AnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 650, height: 72))
        var invocationCount = 0
        toolbar.onLongCapture = { invocationCount += 1 }
        let button = try XCTUnwrap(descendants(of: toolbar).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "longCaptureAction"
        })
        let hoverButton = try XCTUnwrap(button as? AnnotationHoverButton)

        XCTAssertEqual(hoverButton.hoverTitle, "长截图")
        XCTAssertNotNil(button.image)
        button.performClick(nil)
        XCTAssertEqual(invocationCount, 1)

        toolbar.setLongCaptureEnabled(false)
        button.performClick(nil)
        XCTAssertEqual(invocationCount, 1)
    }

    func testRegularSelectionLongCaptureButtonUsesCurrentRegion() throws {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 80, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay
        overlay.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 40, y: 50)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 260, y: 210)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 260, y: 210)))
        var requestedRect: CGRect?
        var regularSubmitCount = 0
        overlay.onLongCaptureRequested = { requestedRect = $0 }
        overlay.onSelectionFinished = { _, _ in regularSubmitCount += 1 }

        let button = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "longCaptureAction"
        })
        button.performClick(nil)

        XCTAssertEqual(requestedRect, CGRect(x: 140, y: 130, width: 220, height: 160))
        XCTAssertEqual(regularSubmitCount, 0)
    }

    func testSelectionPinButtonSubmitsCurrentRegionForPinning() throws {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 80, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay
        overlay.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 40, y: 50)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 210, y: 190)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 210, y: 190)))
        var submittedRect: CGRect?
        var submittedPin = false
        overlay.onSelectionFinished = { rect, action in
            submittedRect = rect
            if case .pin = action { submittedPin = true }
        }
        let pinButton = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "pinAction"
        })
        pinButton.performClick(nil)
        XCTAssertTrue(submittedPin)
        XCTAssertEqual(submittedRect?.size, CGSize(width: 170, height: 140))
    }

    func testCaptureAreaCanResizeAfterEnteringAnnotationMode() throws {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        overlay.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 50, y: 50)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 200, y: 180)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 200, y: 180)))
        overlay.enterAnnotationEditing(baseImage: try makeImage(width: 400, height: 300), initialTool: .rectangle)

        let canvas = try XCTUnwrap(overlay.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        XCTAssertEqual(canvas.frame, CGRect(x: 50, y: 50, width: 150, height: 130))
        XCTAssertEqual(canvas.bounds.origin, CGPoint(x: 50, y: 120))
        let item = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 80, y: 140, width: 30, height: 20)),
            style: .defaultStyle(for: .rectangle)
        )

        overlay.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 200, y: 180)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 260, y: 220)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 260, y: 220)))

        XCTAssertEqual(canvas.frame, CGRect(x: 50, y: 50, width: 210, height: 170))
        XCTAssertEqual(canvas.bounds.origin, CGPoint(x: 50, y: 80))
        XCTAssertEqual(canvas.baseImage.width, 210)
        XCTAssertEqual(canvas.baseImage.height, 170)
        XCTAssertEqual(canvas.document.items.first?.geometry, item.geometry)
        let rendered = try canvas.renderedImage()
        XCTAssertEqual(rendered.width, 210)
        XCTAssertEqual(rendered.height, 170)
    }

    func testFinalizedCaptureAreaCanResizeBeforeEnteringAnnotationMode() throws {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 80, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay
        overlay.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 50, y: 50)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 200, y: 180)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 200, y: 180)))

        overlay.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 200, y: 180)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 260, y: 220)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 260, y: 220)))

        var submittedRect: CGRect?
        overlay.onSelectionFinished = { rect, _ in submittedRect = rect }
        let copyButton = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "copyAction"
        })
        copyButton.performClick(nil)

        XCTAssertEqual(submittedRect?.size, CGSize(width: 210, height: 170))
    }

    func testLongCaptureSelectionUsesDedicatedStartFlow() throws {
        let overlay = SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 400),
            purpose: .longCapture
        )
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 80, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay
        var requestedRect: CGRect?
        var regularSubmitCount = 0
        overlay.onLongCaptureRequested = { requestedRect = $0 }
        overlay.onSelectionFinished = { _, _ in regularSubmitCount += 1 }

        overlay.mouseDown(with: try mouseDownEvent(at: CGPoint(x: 40, y: 60)))
        overlay.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 360, y: 300)))
        overlay.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 360, y: 300)))
        overlay.keyDown(with: try keyEvent(keyCode: UInt16(kVK_Return), characters: "\r"))

        XCTAssertEqual(requestedRect, CGRect(x: 140, y: 140, width: 320, height: 240))
        XCTAssertEqual(regularSubmitCount, 0)
    }

    func testClickingSequenceCreatesAutomaticNumberAndImmediatelyEditsOptionalText() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        canvas.mouseDown(with: try mouseDownEvent(at: CGPoint(x: 40, y: 40)))
        canvas.performPendingSingleClickNow()

        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first)
        editor.insertText("检查登录\n确认结果", replacementRange: editor.selectedRange())
        editor.onFinish?(true)
        XCTAssertEqual(canvas.document.items.count, 1)
        guard case .badge(let step) = canvas.document.items[0].geometry else {
            return XCTFail("Expected sequence badge")
        }
        XCTAssertEqual(step.number, 1)
        XCTAssertEqual(step.text, "检查登录\n确认结果")

        canvas.undo()
        XCTAssertTrue(canvas.document.items.isEmpty, "初次文字输入应与步骤创建共用一次撤销")
    }

    func testUnknownKeyDoesNotForwardThroughResponderChain() throws {
        let canvas = try makeCanvas()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))
        canvas.keyDown(with: event)
    }

    func testResizingTextChangesFontSize() throws {
        let canvas = try makeCanvas()
        let item = canvas.document.add(
            tool: .text,
            geometry: .text(frame: CGRect(x: 20, y: 20, width: 80, height: 30), value: "文字"),
            style: .defaultStyle(for: .text)
        )
        canvas.setTool(.select, style: .defaultStyle(for: .rectangle))

        // NSEvent locations use the window's bottom-left origin while the
        // annotation canvas is flipped to a top-left origin.
        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 250)))
        canvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 160, y: 220)))
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 160, y: 220)))

        let resized = try XCTUnwrap(canvas.document.items.first { $0.id == item.id })
        XCTAssertGreaterThan(resized.style.fontSize, item.style.fontSize)
    }

    func testApplyingTextStyleChangesSelectedColorAndSize() throws {
        let canvas = try makeCanvas()
        let item = canvas.document.add(
            tool: .text,
            geometry: .text(frame: CGRect(x: 20, y: 20, width: 80, height: 30), value: "文字"),
            style: .defaultStyle(for: .text)
        )
        var style = item.style
        style.color = RGBAColor(red: 0.1, green: 0.3, blue: 0.9)
        style.fontSize = 36
        canvas.applyStyle(style)

        let updated = try XCTUnwrap(canvas.document.items.first { $0.id == item.id })
        XCTAssertEqual(updated.style.color, style.color)
        XCTAssertEqual(updated.style.fontSize, 36)
    }

    func testActiveDrawingToolCanMoveAndResizeExistingRectangle() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.rectangle, style: .defaultStyle(for: .rectangle))
        let item = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 20, y: 20, width: 80, height: 60)),
            style: .defaultStyle(for: .rectangle)
        )
        canvas.document.undoManager.removeAllActions()

        // Drag the top border away from its handles to move the object.
        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 35, y: 280)))
        canvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 45, y: 270)))
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 45, y: 270)))
        var updated = try XCTUnwrap(canvas.document.items.first { $0.id == item.id })
        XCTAssertEqual(updated.geometry.bounds, CGRect(x: 30, y: 30, width: 80, height: 60))
        XCTAssertEqual(canvas.currentTool, .rectangle)

        // The right-middle handle changes width without changing height.
        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 110, y: 240)))
        canvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 150, y: 240)))
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 150, y: 240)))
        updated = try XCTUnwrap(canvas.document.items.first { $0.id == item.id })
        XCTAssertEqual(updated.geometry.bounds, CGRect(x: 30, y: 30, width: 120, height: 60))

        canvas.undo()
        XCTAssertEqual(canvas.document.items.first?.geometry.bounds, CGRect(x: 30, y: 30, width: 80, height: 60))
        canvas.undo()
        XCTAssertEqual(canvas.document.items.first?.geometry.bounds, CGRect(x: 20, y: 20, width: 80, height: 60))
    }

    func testEveryDrawingToolCanMoveItsSelectedObjectWithoutSwitchingToSelect() throws {
        let baseRect = CGRect(x: 30, y: 30, width: 80, height: 60)
        let cases: [(AnnotationTool, AnnotationGeometry, CGPoint, AnnotationStyle)] = [
            (.rectangle, .rect(baseRect), CGPoint(x: 60, y: 50), filledStyle(for: .rectangle)),
            (.ellipse, .rect(baseRect), CGPoint(x: 70, y: 60), filledStyle(for: .ellipse)),
            (.line, .line(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 110, y: 90)), CGPoint(x: 70, y: 60), .defaultStyle(for: .line)),
            (.arrow, .line(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 110, y: 90)), CGPoint(x: 70, y: 60), .defaultStyle(for: .arrow)),
            (.pen, .path([CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 60), CGPoint(x: 110, y: 90)]), CGPoint(x: 70, y: 60), .defaultStyle(for: .pen)),
            (.text, .text(frame: baseRect, value: "文字"), CGPoint(x: 70, y: 60), .defaultStyle(for: .text)),
            (.sequence, .badge(StepAnnotationGeometry(badgeFrame: CGRect(x: 30, y: 30, width: 60, height: 60), number: 1, labelFrame: CGRect(x: 98, y: 40, width: 80, height: 30), text: "")), CGPoint(x: 60, y: 60), .defaultStyle(for: .sequence)),
            (.mosaic, .path([CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 60), CGPoint(x: 110, y: 90)]), CGPoint(x: 70, y: 60), .defaultStyle(for: .mosaic)),
            (.highlight, .rect(baseRect), CGPoint(x: 70, y: 60), .defaultStyle(for: .highlight))
        ]

        for (tool, geometry, hitPoint, style) in cases {
            let canvas = try makeCanvas()
            canvas.setTool(tool, style: style)
            let item = canvas.document.add(tool: tool, geometry: geometry, style: style)
            let originalBounds = item.geometry.bounds
            canvas.document.undoManager.removeAllActions()

            canvas.mouseDown(with: try mouseEvent(
                type: .leftMouseDown,
                at: windowPoint(for: hitPoint)
            ))
            canvas.mouseDragged(with: try mouseEvent(
                type: .leftMouseDragged,
                at: windowPoint(for: CGPoint(x: hitPoint.x + 12, y: hitPoint.y + 9))
            ))
            canvas.mouseUp(with: try mouseEvent(
                type: .leftMouseUp,
                at: windowPoint(for: CGPoint(x: hitPoint.x + 12, y: hitPoint.y + 9))
            ))

            let moved = try XCTUnwrap(canvas.document.items.first { $0.id == item.id }, "Tool: \(tool)")
            XCTAssertEqual(moved.geometry.bounds.minX, originalBounds.minX + 12, accuracy: 0.001, "Tool: \(tool)")
            XCTAssertEqual(moved.geometry.bounds.minY, originalBounds.minY + 9, accuracy: 0.001, "Tool: \(tool)")
            XCTAssertEqual(canvas.currentTool, tool)
        }
    }

    func testLineEndpointAndPenBoundsResizeWhileTheirToolsStayActive() throws {
        let lineCanvas = try makeCanvas()
        lineCanvas.setTool(.arrow, style: .defaultStyle(for: .arrow))
        let arrow = lineCanvas.document.add(
            tool: .arrow,
            geometry: .line(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 100, y: 80)),
            style: .defaultStyle(for: .arrow)
        )
        lineCanvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: windowPoint(for: CGPoint(x: 100, y: 80))))
        lineCanvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: windowPoint(for: CGPoint(x: 150, y: 120))))
        lineCanvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: windowPoint(for: CGPoint(x: 150, y: 120))))
        guard case .line(let start, let end) = lineCanvas.document.items.first(where: { $0.id == arrow.id })?.geometry else {
            return XCTFail("Expected arrow line geometry")
        }
        XCTAssertEqual(start, CGPoint(x: 30, y: 30))
        XCTAssertEqual(end, CGPoint(x: 150, y: 120))

        let penCanvas = try makeCanvas()
        penCanvas.setTool(.pen, style: .defaultStyle(for: .pen))
        let pen = penCanvas.document.add(
            tool: .pen,
            geometry: .path([CGPoint(x: 30, y: 30), CGPoint(x: 60, y: 50), CGPoint(x: 100, y: 80)]),
            style: .defaultStyle(for: .pen)
        )
        penCanvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: windowPoint(for: CGPoint(x: 100, y: 80))))
        penCanvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: windowPoint(for: CGPoint(x: 150, y: 130))))
        penCanvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: windowPoint(for: CGPoint(x: 150, y: 130))))
        let resizedPen = try XCTUnwrap(penCanvas.document.items.first { $0.id == pen.id })
        XCTAssertEqual(resizedPen.geometry.bounds, CGRect(x: 30, y: 30, width: 120, height: 100))
    }

    func testOptionDragForcesOverlappingAnnotationCreation() throws {
        let canvas = try makeCanvas()
        var style = AnnotationStyle.defaultStyle(for: .rectangle)
        style.fillMode = .fill
        canvas.setTool(.rectangle, style: style)
        _ = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 20, y: 20, width: 100, height: 100)),
            style: style
        )

        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: CGPoint(x: 40, y: 260),
            modifierFlags: [.option]
        ))
        canvas.mouseDragged(with: try mouseEvent(
            type: .leftMouseDragged,
            at: CGPoint(x: 90, y: 210),
            modifierFlags: [.option]
        ))
        canvas.mouseUp(with: try mouseEvent(
            type: .leftMouseUp,
            at: CGPoint(x: 90, y: 210),
            modifierFlags: [.option]
        ))

        XCTAssertEqual(canvas.document.items.count, 2)
        XCTAssertEqual(canvas.document.items.last?.geometry.bounds, CGRect(x: 40, y: 40, width: 50, height: 50))
    }

    func testSequenceSideHandleKeepsBadgeSquare() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        let item = canvas.document.add(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: CGRect(x: 40, y: 40, width: 28, height: 28),
                number: 0,
                labelFrame: CGRect(x: 75, y: 40, width: 80, height: 28),
                text: "步骤"
            )),
            style: .defaultStyle(for: .sequence)
        )

        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: CGPoint(x: 68, y: 246)))
        canvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 100, y: 246)))
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: CGPoint(x: 100, y: 246)))

        let resized = try XCTUnwrap(canvas.document.items.first { $0.id == item.id })
        guard case .badge(let step) = resized.geometry else { return XCTFail("Expected step") }
        XCTAssertEqual(step.badgeFrame.width, step.badgeFrame.height)
        XCTAssertGreaterThan(step.badgeFrame.width, 28)
        XCTAssertGreaterThan(resized.style.lineWidth, 28)
    }

    func testDoubleClickCopiesAnnotationsButTextDoubleClickEdits() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.rectangle, style: .defaultStyle(for: .rectangle))
        _ = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 20, y: 20, width: 80, height: 60)),
            style: .defaultStyle(for: .rectangle)
        )
        let text = canvas.document.add(
            tool: .text,
            geometry: .text(frame: CGRect(x: 150, y: 30, width: 100, height: 30), value: "可编辑文字"),
            style: .defaultStyle(for: .text)
        )
        var copied = 0
        canvas.onCommit = { action in
            if case .copy = action { copied += 1 }
        }

        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: CGPoint(x: 320, y: 100),
            clickCount: 2
        ))
        XCTAssertEqual(copied, 1)

        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: CGPoint(x: 180, y: 255),
            clickCount: 2
        ))
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(canvas.document.selectedID, text.id)
        XCTAssertNotNil(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first)
    }

    func testDoubleClickCancelsPendingSequenceCreationAndCopiesOnce() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        var copied = 0
        canvas.onCommit = { action in
            if case .copy = action { copied += 1 }
        }

        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: CGPoint(x: 200, y: 150),
            clickCount: 1
        ))
        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: CGPoint(x: 200, y: 150),
            clickCount: 2
        ))
        canvas.performPendingSingleClickNow()

        XCTAssertEqual(copied, 1)
        XCTAssertTrue(canvas.document.items.isEmpty)
    }

    func testPendingTextOrSequenceClickIsCancelledByToolChange() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        canvas.mouseDown(with: try mouseDownEvent(at: CGPoint(x: 80, y: 80)))
        canvas.setTool(.rectangle, style: .defaultStyle(for: .rectangle))
        canvas.performPendingSingleClickNow()

        XCTAssertTrue(canvas.document.items.isEmpty)
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.isEmpty)
    }

    func testStepLabelMovesIndependentlyAndBadgeMovesWholeGroup() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        let originalStep = StepAnnotationGeometry(
            badgeFrame: CGRect(x: 40, y: 40, width: 28, height: 28),
            number: 0,
            labelFrame: CGRect(x: 76, y: 40, width: 100, height: 30),
            text: "说明"
        )
        let item = canvas.document.add(tool: .sequence, geometry: .badge(originalStep), style: .defaultStyle(for: .sequence))
        canvas.document.undoManager.removeAllActions()

        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: windowPoint(for: CGPoint(x: 100, y: 50))))
        canvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: windowPoint(for: CGPoint(x: 120, y: 65))))
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: windowPoint(for: CGPoint(x: 120, y: 65))))
        guard case .badge(let labelMoved) = canvas.document.items.first(where: { $0.id == item.id })?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(labelMoved.badgeFrame, originalStep.badgeFrame)
        XCTAssertEqual(labelMoved.labelFrame.origin, CGPoint(x: 96, y: 55))

        canvas.undo()
        guard case .badge(let labelMoveUndone) = canvas.document.items.first(where: { $0.id == item.id })?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(labelMoveUndone.labelFrame, originalStep.labelFrame)

        canvas.redo()

        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: windowPoint(for: CGPoint(x: 54, y: 54))))
        canvas.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, at: windowPoint(for: CGPoint(x: 64, y: 64))))
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: windowPoint(for: CGPoint(x: 64, y: 64))))
        guard case .badge(let groupMoved) = canvas.document.items.first(where: { $0.id == item.id })?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(groupMoved.badgeFrame.origin, CGPoint(x: 50, y: 50))
        XCTAssertEqual(groupMoved.labelFrame.origin, CGPoint(x: 106, y: 65))
    }

    func testStepPlacedAtRightEdgeUsesLeftEditorAndEmptyCommitKeepsBadge() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        canvas.mouseDown(with: try mouseDownEvent(at: windowPoint(for: CGPoint(x: 390, y: 45))))
        canvas.performPendingSingleClickNow()

        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first)
        guard case .badge(let creatingStep) = canvas.document.items.first?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertLessThanOrEqual(editor.frame.maxX, creatingStep.badgeFrame.minX)
        XCTAssertEqual(canvas.resolvedCursorKind(at: editor.frame.origin), .iBeam)
        editor.onFinish?(true)

        guard case .badge(let committedStep) = canvas.document.items.first?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(committedStep.text, "")
        XCTAssertEqual(committedStep.number, 1)
    }

    func testStepSizeAndColorStyleUpdateWholeCombinationWithoutUndo() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        let item = canvas.document.add(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: CGRect(x: 40, y: 40, width: 28, height: 28),
                number: 0,
                labelFrame: CGRect(x: 76, y: 40, width: 80, height: 30),
                text: "说明"
            )),
            style: .defaultStyle(for: .sequence)
        )
        canvas.document.undoManager.removeAllActions()
        var style = item.style
        style.lineWidth = 56
        style.color = RGBAColor(red: 0, green: 0.478, blue: 1)
        style.opacity = 0.5
        canvas.applyStyle(style)

        let updated = try XCTUnwrap(canvas.document.items.first { $0.id == item.id })
        guard case .badge(let step) = updated.geometry else { return XCTFail("Expected step") }
        XCTAssertEqual(step.badgeFrame.size, CGSize(width: 56, height: 56))
        XCTAssertGreaterThanOrEqual(step.labelFrame.width, 160)
        XCTAssertEqual(updated.style.color, style.color)
        XCTAssertEqual(updated.style.opacity, 0.5)
        XCTAssertFalse(canvas.document.undoManager.canUndo)
    }

    func testLaterStepTextEditIsIndependentlyUndoable() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        let item = canvas.document.add(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: CGRect(x: 30, y: 30, width: 28, height: 28),
                number: 0,
                labelFrame: CGRect(x: 66, y: 30, width: 100, height: 30),
                text: "原说明"
            )),
            style: .defaultStyle(for: .sequence)
        )
        canvas.document.undoManager.removeAllActions()
        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: windowPoint(for: CGPoint(x: 90, y: 42)),
            clickCount: 2
        ))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first)
        editor.string = "新说明"
        editor.onFinish?(true)
        guard case .badge(let edited) = canvas.document.items.first(where: { $0.id == item.id })?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(edited.text, "新说明")

        canvas.undo()
        guard case .badge(let undone) = canvas.document.items.first(where: { $0.id == item.id })?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(undone.text, "原说明")
    }

    func testDoubleClickStepTextEditsInsteadOfCopying() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        let item = canvas.document.add(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: CGRect(x: 30, y: 30, width: 28, height: 28),
                number: 0,
                labelFrame: CGRect(x: 66, y: 30, width: 100, height: 30),
                text: "可编辑步骤"
            )),
            style: .defaultStyle(for: .sequence)
        )
        var copied = 0
        canvas.onCommit = { if case .copy = $0 { copied += 1 } }

        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: windowPoint(for: CGPoint(x: 100, y: 42)),
            clickCount: 2
        ))

        XCTAssertEqual(copied, 0)
        XCTAssertEqual(canvas.document.selectedID, item.id)
        XCTAssertEqual(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first?.string, "可编辑步骤")
    }

    func testEditingStepHidesPreviouslyRenderedDescriptionUntilCommit() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.sequence, style: .defaultStyle(for: .sequence))
        let item = canvas.document.add(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: CGRect(x: 30, y: 30, width: 28, height: 28),
                number: 0,
                labelFrame: CGRect(x: 66, y: 30, width: 120, height: 30),
                text: "不会叠加"
            )),
            style: .defaultStyle(for: .sequence)
        )

        canvas.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            at: windowPoint(for: CGPoint(x: 100, y: 42)),
            clickCount: 2
        ))

        let displayItem = try XCTUnwrap(canvas.itemsForDisplay(canvas.document.items).first { $0.id == item.id })
        guard case .badge(let editingStep) = displayItem.geometry else { return XCTFail("Expected step") }
        XCTAssertEqual(editingStep.text, "", "编辑器显示文字时，底层渲染必须暂时隐藏旧文字")
        XCTAssertEqual(editingStep.badgeFrame, CGRect(x: 30, y: 30, width: 28, height: 28))

        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? InlineAnnotationTextView }.first)
        editor.onFinish?(true)
        guard case .badge(let committedStep) = canvas.itemsForDisplay(canvas.document.items).first?.geometry else {
            return XCTFail("Expected step")
        }
        XCTAssertEqual(committedStep.text, "不会叠加")
    }

    func testCursorKindsFollowDrawingHoverDraggingHandlesAndOption() throws {
        let canvas = try makeCanvas()
        var style = AnnotationStyle.defaultStyle(for: .rectangle)
        style.fillMode = .fill
        canvas.setTool(.rectangle, style: style)
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 300, y: 200)), .crosshair)

        _ = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 20, y: 20, width: 80, height: 60)),
            style: style
        )
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 50, y: 50)), .openHand)
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 20, y: 20)), .resizeDiagonalDown)
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 100, y: 20)), .resizeDiagonalUp)
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 100, y: 50)), .resizeHorizontal)
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 60, y: 20)), .resizeVertical)
        XCTAssertEqual(
            canvas.resolvedCursorKind(at: CGPoint(x: 20, y: 20), modifierFlags: [.option]),
            .crosshair
        )

        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown, at: windowPoint(for: CGPoint(x: 50, y: 50))))
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 50, y: 50)), .closedHand)
        canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp, at: windowPoint(for: CGPoint(x: 50, y: 50))))

        canvas.setTool(.select, style: style)
        canvas.document.select(nil)
        XCTAssertEqual(canvas.resolvedCursorKind(at: CGPoint(x: 300, y: 200)), .arrow)
    }

    func testLineEndpointCursorFollowsLineDirection() throws {
        let canvas = try makeCanvas()
        canvas.setTool(.line, style: .defaultStyle(for: .line))
        _ = canvas.document.add(
            tool: .line,
            geometry: .line(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 100, y: 100)),
            style: .defaultStyle(for: .line)
        )
        guard case .resizeLine(let degrees) = canvas.resolvedCursorKind(at: CGPoint(x: 20, y: 20)) else {
            return XCTFail("Expected directional endpoint cursor")
        }
        XCTAssertEqual(abs(degrees), 45)
    }

    private func makeCanvas() throws -> AnnotationCanvasView {
        AnnotationCanvasView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            baseImage: try makeImage(width: 400, height: 300)
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func mouseDownEvent(at point: CGPoint) throws -> NSEvent {
        try mouseEvent(type: .leftMouseDown, at: point)
    }

    private func filledStyle(for tool: AnnotationTool) -> AnnotationStyle {
        var style = AnnotationStyle.defaultStyle(for: tool)
        style.fillMode = .fill
        return style
    }

    private func windowPoint(for canvasPoint: CGPoint) -> CGPoint {
        CGPoint(x: canvasPoint.x, y: 300 - canvasPoint.y)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        at point: CGPoint,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private func keyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
