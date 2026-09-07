import AppKit
import XCTest
@testable import MeetingNotes

@MainActor
final class InlineMeetingTextPerformanceTests: XCTestCase {
    func testUnchangedPresentationDoesNotRewriteTextStorage() {
        let editor = makeEditor()
        let font = NSFont.systemFont(ofSize: 14)
        editor.applyPresentation(
            font: font, textColor: .labelColor, alignment: .left, lineLimit: nil
        )
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        let edits = TextStorageEditCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage,
            queue: nil
        ) { _ in edits.record() }
        defer { NotificationCenter.default.removeObserver(observer) }

        for _ in 0..<100 {
            editor.applyPresentation(
                font: font, textColor: .labelColor, alignment: .left,
                lineLimit: nil
            )
        }

        XCTAssertEqual(edits.count, 0)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 2))
    }

    func testChangedPresentationUpdatesAppearanceAndPreservesSelection() {
        let editor = makeEditor()
        editor.applyPresentation(
            font: .systemFont(ofSize: 14), textColor: .labelColor,
            alignment: .left, lineLimit: nil
        )
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        let changedFont = NSFont.boldSystemFont(ofSize: 18)

        editor.applyPresentation(
            font: changedFont, textColor: .systemRed, alignment: .center,
            lineLimit: 3
        )

        XCTAssertEqual(editor.font, changedFont)
        XCTAssertEqual(editor.textColor, .systemRed)
        XCTAssertEqual(editor.alignment, .center)
        XCTAssertEqual(editor.textContainer?.maximumNumberOfLines, 3)
        XCTAssertEqual(editor.textContainer?.lineBreakMode, .byCharWrapping)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 2))
    }

    func testUnchangedPresentationPreservesChineseComposition() {
        let editor = makeEditor()
        let font = NSFont.systemFont(ofSize: 14)
        editor.applyPresentation(
            font: font, textColor: .labelColor, alignment: .left, lineLimit: nil
        )
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedRange = editor.markedRange()
        let selection = editor.selectedRange()
        let text = editor.string

        editor.applyPresentation(
            font: font, textColor: .labelColor, alignment: .left, lineLimit: nil
        )

        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, text)
    }

    func testKnownWidthMeasuresTextOnlyOnceAndReusesCachedSize() {
        let editor = makeEditor()
        let font = NSFont.systemFont(ofSize: 14)
        var measuredWidths: [CGFloat] = []
        let measure: (NSString, NSSize, [NSAttributedString.Key: Any]) -> NSRect = {
            text, size, attributes in
            measuredWidths.append(size.width)
            return text.boundingRect(
                with: size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }

        let first = editor.measuredSize(
            availableWidth: 180, font: font, alignment: .left,
            lineLimit: nil, measure: measure
        )
        let cached = editor.measuredSize(
            availableWidth: 180, font: font, alignment: .left,
            lineLimit: nil, measure: measure
        )

        XCTAssertEqual(measuredWidths, [180])
        XCTAssertEqual(first.width, 180)
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertEqual(cached, first)
    }

    func testUnknownWidthKeepsIntrinsicWidthFallbackAndLineLimit() {
        let editor = makeEditor()
        let font = NSFont.systemFont(ofSize: 14)
        var measuredWidths: [CGFloat] = []

        let size = editor.measuredSize(
            availableWidth: nil, font: font, alignment: .left, lineLimit: 1
        ) { text, size, attributes in
            measuredWidths.append(size.width)
            return text.boundingRect(
                with: size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }

        XCTAssertEqual(measuredWidths.count, 2)
        XCTAssertEqual(measuredWidths.first, 10_000)
        XCTAssertEqual(measuredWidths.last, size.width)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertEqual(size.height, ceil(font.ascender - font.descender + font.leading))
    }

    private func makeEditor() -> InlineMeetingNativeTextView {
        let editor = InlineMeetingNativeTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 120)
        )
        editor.isRichText = false
        editor.string = "会议讨论：保留中文输入、选区，以及原有排版。"
        return editor
    }
}

private final class TextStorageEditCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}
