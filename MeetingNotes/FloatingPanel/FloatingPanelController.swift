import AppKit
import SwiftUI

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
    private var isPaused = false

    init(
        defaults: UserDefaults = .standard,
        action: @escaping (FloatingControl) -> Void
    ) {
        positionStore = FloatingPanelPositionStore(defaults: defaults)
        self.action = action
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 194, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        restorePosition()
        panel.delegate = self
        refreshContent()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setPaused(_ isPaused: Bool) {
        guard self.isPaused != isPaused else { return }
        self.isPaused = isPaused
        refreshContent()
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

    private func refreshContent() {
        panel.contentView = NSHostingView(
            rootView: FloatingRecorderView(
                isPaused: isPaused,
                action: action
            )
        )
    }
}
