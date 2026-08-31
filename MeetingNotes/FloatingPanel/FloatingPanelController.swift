import AppKit
import SwiftUI

struct FloatingPanelSizePolicy: Equatable, Sendable {
    static let compact = NSSize(width: 374, height: 54)
    static let noteEditor = NSSize(width: 374, height: 100)

    static func size(noteEditorPresented: Bool) -> NSSize {
        noteEditorPresented ? noteEditor : compact
    }

    static func frame(
        from currentFrame: NSRect,
        noteEditorPresented: Bool
    ) -> NSRect {
        let nextSize = size(noteEditorPresented: noteEditorPresented)
        return NSRect(
            x: currentFrame.midX - nextSize.width / 2,
            y: currentFrame.minY,
            width: nextSize.width,
            height: nextSize.height
        )
    }
}

struct FloatingPanelPositionStore {
    private enum Key {
        static let hasPosition = "floatingPanel.hasPosition"
        static let originX = "floatingPanel.originX"
        static let originY = "floatingPanel.originY"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ origin: CGPoint) {
        defaults.set(origin.x, forKey: Key.originX)
        defaults.set(origin.y, forKey: Key.originY)
        defaults.set(true, forKey: Key.hasPosition)
    }

    func load() -> CGPoint? {
        guard defaults.bool(forKey: Key.hasPosition) else {
            return nil
        }

        return CGPoint(
            x: defaults.double(forKey: Key.originX),
            y: defaults.double(forKey: Key.originY)
        )
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel

    private let positionStore: FloatingPanelPositionStore
    private let action: (FloatingControl) -> Void
    private let animationDuration: TimeInterval
    private let reduceMotion: () -> Bool
    private let recordingPresentationStore:
        RecordingSessionPresentationStore
    private let annotationViewModel: RecordingAnnotationViewModel
    private var hostingView: NSHostingView<FloatingRecorderView>!
    private var isPaused = false
    private var visibilityGeneration = 0

    init(
        defaults: UserDefaults = .standard,
        animationDuration: TimeInterval = 0.16,
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        recordingPresentationStore: RecordingSessionPresentationStore,
        annotationViewModel: RecordingAnnotationViewModel,
        action: @escaping (FloatingControl) -> Void
    ) {
        positionStore = FloatingPanelPositionStore(defaults: defaults)
        self.action = action
        self.animationDuration = animationDuration
        self.reduceMotion = reduceMotion
        self.recordingPresentationStore = recordingPresentationStore
        self.annotationViewModel = annotationViewModel
        panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: FloatingPanelSizePolicy.compact
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        hostingView = NSHostingView(rootView: makeRootView())
        configurePanel()
        restorePosition()
        panel.delegate = self
        panel.contentView = hostingView
    }

    func show() {
        annotationViewModel.refreshForCurrentSession()
        setNoteEditorPresented(
            annotationViewModel.isNoteEditorPresented
        )
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let shouldAnimate = shouldAnimateVisibility
        if !panel.isVisible {
            panel.alphaValue = shouldAnimate ? 0 : 1
        }
        panel.orderFrontRegardless()
        guard shouldAnimate else {
            panel.alphaValue = 1
            return
        }
        animateAlpha(to: 1, generation: generation, hideAfter: false)
    }

    func hide() {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard panel.isVisible else {
            panel.alphaValue = 1
            return
        }
        guard shouldAnimateVisibility else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        animateAlpha(to: 0, generation: generation, hideAfter: true)
    }

    func setPaused(_ isPaused: Bool) {
        guard self.isPaused != isPaused else { return }
        self.isPaused = isPaused
        hostingView.rootView = makeRootView()
    }

    func setNoteEditorPresented(_ isPresented: Bool) {
        let nextFrame = FloatingPanelSizePolicy.frame(
            from: panel.frame,
            noteEditorPresented: isPresented
        )
        guard panel.frame != nextFrame else { return }
        panel.setFrame(nextFrame, display: panel.isVisible)
    }

    func windowDidMove(_ notification: Notification) {
        positionStore.save(panel.frame.origin)
    }

    private func configurePanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
    }

    private func makeRootView() -> FloatingRecorderView {
        FloatingRecorderView(
            isPaused: isPaused,
            recordingPresentationStore: recordingPresentationStore,
            annotationViewModel: annotationViewModel,
            action: action,
            noteEditorPresentationChanged: { [weak self] isPresented in
                self?.setNoteEditorPresented(isPresented)
            }
        )
    }

    private func restorePosition() {
        if let savedOrigin = positionStore.load() {
            panel.setFrameOrigin(savedOrigin)
            return
        }

        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panel.frame.width / 2
        let y = visibleFrame.minY + 48
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private var shouldAnimateVisibility: Bool {
        animationDuration > 0 && !reduceMotion()
    }

    private func animateAlpha(
        to alpha: CGFloat,
        generation: Int,
        hideAfter: Bool
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.visibilityGeneration == generation else {
                    return
                }
                if hideAfter {
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                }
            }
        }
    }
}
