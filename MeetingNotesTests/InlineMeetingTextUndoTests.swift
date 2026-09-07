import AppKit
import SwiftUI
import XCTest
@testable import MeetingNotes

@MainActor
final class InlineMeetingTextUndoTests: XCTestCase {
    func testRefreshingAnotherNativeEditorKeepsManualUndoAndRedo() throws {
        let fixture = try HiddenInlineUndoFixture()
        defer { fixture.dispose() }
        let neighbor = InlineMeetingNativeTextView(frame: .zero)
        neighbor.allowsUndo = true
        neighbor.string = "实时新句子"
        let container = NSView(frame: fixture.window.contentLayoutRect)
        fixture.window.contentView = container
        container.addSubview(fixture.host)
        container.addSubview(neighbor)
        fixture.deletePrefix()
        let deleted = fixture.state.value
        let manager = try XCTUnwrap(fixture.editor.undoManager)
        XCTAssertTrue(neighbor.undoManager === manager)
        XCTAssertTrue(manager.canUndo)

        neighbor.string = "实时新句子 继续追加的句子"
        XCTAssertTrue(manager.canUndo, "Live text refresh must not erase manual undo")
        manager.undo()
        XCTAssertEqual(fixture.state.value, fixture.original)
        neighbor.string += " 又有新转录"
        XCTAssertTrue(manager.canRedo, "Live text refresh must not erase manual redo")
        manager.redo()
        XCTAssertEqual(fixture.state.value, deleted)
    }

    func testDetachedEditorDoesNotPublishOldWindowUndoOrRedo() throws {
        let fixture = try HiddenInlineUndoFixture()
        defer { fixture.dispose() }
        fixture.deletePrefix()
        let deleted = fixture.state.value
        let manager = try XCTUnwrap(fixture.editor.undoManager)
        fixture.window.contentView = nil
        XCTAssertNil(fixture.editor.window)

        manager.undo()
        manager.redo()

        XCTAssertEqual(fixture.state.value, deleted)
        XCTAssertEqual(fixture.state.changes, [deleted])
    }

    func testMovingEditorRebindsUndoObservationToNewWindow() throws {
        let fixture = try HiddenInlineUndoFixture()
        let secondWindow = NSWindow(
            contentRect: fixture.window.frame, styleMask: [.titled],
            backing: .buffered, defer: true
        )
        defer {
            secondWindow.undoManager?.removeAllActions()
            secondWindow.contentView = nil
            fixture.dispose()
        }
        fixture.deletePrefix()
        let oldManager = try XCTUnwrap(fixture.editor.undoManager)
        oldManager.removeAllActions()
        fixture.window.contentView = nil
        secondWindow.contentView = fixture.host
        fixture.host.layoutSubtreeIfNeeded()
        let newManager = try XCTUnwrap(fixture.editor.undoManager)
        XCTAssertFalse(newManager === oldManager)
        let before = fixture.state.value
        fixture.replace(NSRange(location: 0, length: 0), with: "新窗口")
        let changed = fixture.state.value

        newManager.undo()
        XCTAssertEqual(fixture.state.value, before)
        newManager.redo()
        XCTAssertEqual(fixture.state.value, changed)
        XCTAssertFalse(secondWindow.isVisible)
        XCTAssertFalse(secondWindow.isKeyWindow)
    }

    func testUndoObserversDoNotKeepDetachedNativeEditorAlive() throws {
        // AppKit can defer releasing even a plain, detached NSTextView. Use a
        // control and wait for actual deallocation, not immediate scope exit.
        weak var controlEditor: NSTextView?
        try autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            let editor = NSTextView(frame: window.contentLayoutRect)
            editor.allowsUndo = true
            editor.isRichText = false
            window.contentView = editor
            editor.string = "释放检查"
            try XCTUnwrap(editor.undoManager).removeAllActions()
            controlEditor = editor
            window.contentView = nil
            window.close()
        }
        weak var releasedEditor: InlineMeetingNativeTextView?
        var retainedManager: UndoManager?
        try autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            let editor = InlineMeetingNativeTextView(frame: window.contentLayoutRect)
            editor.allowsUndo = true
            editor.isRichText = false
            window.contentView = editor
            editor.string = "释放检查"
            retainedManager = try XCTUnwrap(editor.undoManager)
            retainedManager?.removeAllActions()
            releasedEditor = editor
            window.contentView = nil
            XCTAssertFalse(window.isVisible)
            window.close()
        }

        let deadline = Date(timeIntervalSinceNow: 2)
        while (controlEditor != nil || releasedEditor != nil), Date() < deadline {
            autoreleasepool {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        XCTAssertNil(controlEditor, "Control: plain AppKit editor under identical teardown")
        XCTAssertNotNil(retainedManager)
        XCTAssertNil(releasedEditor)
    }

    func testSharedWindowUndoPublishesOnlyTheEditorWhoseTextChanged() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        let first = InlineMeetingNativeTextView(frame: container.bounds)
        let second = InlineMeetingNativeTextView(frame: container.bounds)
        for editor in [first, second] {
            editor.isRichText = false
            editor.allowsUndo = true
            editor.string = "原文"
            container.addSubview(editor)
        }
        let manager = try XCTUnwrap(window.undoManager)
        defer {
            manager.removeAllActions()
            window.contentView = nil
        }
        manager.groupsByEvent = false
        var firstChanges: [String] = []
        var secondChanges: [String] = []
        first.onStringChange = { firstChanges.append($0) }
        second.onStringChange = { secondChanges.append($0) }
        manager.beginUndoGrouping()
        second.insertText("新增转录", replacementRange: NSRange(location: 0, length: 2))
        second.breakUndoCoalescing()
        manager.endUndoGrouping()
        manager.removeAllActions()
        manager.beginUndoGrouping()
        first.insertText("修改", replacementRange: NSRange(location: 0, length: 2))
        first.breakUndoCoalescing()
        manager.endUndoGrouping()

        manager.undo()

        XCTAssertEqual(firstChanges, ["修改", "原文"])
        XCTAssertEqual(secondChanges, ["新增转录"])
        XCTAssertEqual(second.string, "新增转录")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testNativeUndoUpdatesBindingBeforeRepresentableRefresh() throws {
        let fixture = try HiddenInlineUndoFixture()
        defer { fixture.dispose() }
        fixture.deletePrefix()

        XCTAssertTrue(fixture.editor.tryToPerform(
            NSSelectorFromString("undo:"), with: nil
        ))

        XCTAssertEqual(fixture.editor.string, fixture.original)
        XCTAssertEqual(fixture.state.value, fixture.original)
        fixture.refreshPresentation()
        XCTAssertEqual(fixture.editor.string, fixture.original)
        XCTAssertTrue(fixture.findEditor() === fixture.editor)
    }

    func testNativeUndoRestoresCompletelyDeletedEditorContents() throws {
        let fixture = try HiddenInlineUndoFixture()
        defer { fixture.dispose() }
        fixture.replace(NSRange(
            location: 0, length: (fixture.original as NSString).length
        ), with: "")
        XCTAssertEqual(fixture.state.value, "")

        XCTAssertTrue(fixture.editor.tryToPerform(
            NSSelectorFromString("undo:"), with: nil
        ))
        fixture.refreshPresentation()

        XCTAssertEqual(fixture.editor.string, fixture.original)
        XCTAssertEqual(fixture.state.value, fixture.original)
    }

    func testNativeRedoPublishesRestoredDeletionExactlyOnce() throws {
        let fixture = try HiddenInlineUndoFixture()
        defer { fixture.dispose() }
        fixture.deletePrefix()
        let deleted = fixture.state.value

        XCTAssertTrue(fixture.editor.tryToPerform(
            NSSelectorFromString("undo:"), with: nil
        ))
        XCTAssertTrue(fixture.editor.tryToPerform(
            NSSelectorFromString("redo:"), with: nil
        ))
        fixture.refreshPresentation()

        XCTAssertEqual(fixture.editor.string, deleted)
        XCTAssertEqual(fixture.state.value, deleted)
        XCTAssertEqual(fixture.state.changes, [deleted, fixture.original, deleted])
    }

    func testUndoAndRedoResultsReachExistingLocalAutosaver() async throws {
        let fixture = try HiddenInlineUndoFixture()
        defer { fixture.dispose() }
        // Control persistence with flush(), not a wall-clock wait.
        let autosaver = MeetingEditAutosaver(delay: { _ in
            throw CancellationError()
        })
        defer { autosaver.cancel() }
        var saved = fixture.original
        fixture.state.onChange = { snapshot in
            autosaver.schedule { saved = snapshot }
        }
        fixture.deletePrefix()
        let deleted = fixture.state.value
        await autosaver.flush()
        XCTAssertEqual(saved, deleted)

        fixture.editor.undoManager?.undo()
        await autosaver.flush()
        XCTAssertEqual(saved, fixture.original)
        fixture.refreshPresentation()
        XCTAssertEqual(fixture.editor.string, fixture.original)

        fixture.editor.undoManager?.redo()
        await autosaver.flush()
        XCTAssertEqual(saved, deleted)
        XCTAssertEqual(fixture.state.value, deleted)
        XCTAssertEqual(autosaver.state, .saved)
    }
}

@MainActor
private final class InlineUndoTestState {
    var value: String
    var changes: [String] = []
    var onChange: ((String) -> Void)?

    init(value: String) { self.value = value }

    var binding: Binding<String> {
        Binding(
            get: { self.value },
            set: { value in
                self.value = value
                self.changes.append(value)
                self.onChange?(value)
            }
        )
    }
}

/// Exercises the production representable without showing/activating a window,
/// accessing the desktop or pasteboard, or synthesizing keyboard/mouse events.
@MainActor
private final class HiddenInlineUndoFixture {
    let original = "撤销诊断：保留中文、标点，以及会议文字。"
    let state: InlineUndoTestState
    let host: NSHostingView<InlineEditableMeetingText>
    let window: NSWindow
    let editor: InlineMeetingNativeTextView

    init() throws {
        let state = InlineUndoTestState(value: original)
        self.state = state
        host = NSHostingView(rootView: InlineEditableMeetingText(
            text: state.binding, accessibilityIdentifier: "test.inlineUndo"
        ))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        editor = try XCTUnwrap(Self.findEditor(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertNotNil(editor.undoManager)
    }

    func deletePrefix() {
        replace(NSRange(location: 0, length: 2), with: "")
    }

    func replace(_ range: NSRange, with text: String) {
        editor.insertText(text, replacementRange: range)
        editor.breakUndoCoalescing()
        host.layoutSubtreeIfNeeded()
    }

    func refreshPresentation() {
        host.rootView = InlineEditableMeetingText(
            text: state.binding, foregroundColor: .secondary,
            accessibilityIdentifier: "test.inlineUndo"
        )
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func findEditor() -> InlineMeetingNativeTextView? {
        Self.findEditor(in: host)
    }

    func dispose() {
        _ = window.makeFirstResponder(nil)
        window.undoManager?.removeAllActions()
        window.contentView = nil
        state.onChange = nil
        XCTAssertFalse(window.isVisible)
    }

    private static func findEditor(in view: NSView) -> InlineMeetingNativeTextView? {
        if let editor = view as? InlineMeetingNativeTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }
}
