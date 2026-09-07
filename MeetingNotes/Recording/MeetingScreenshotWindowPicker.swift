import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct MeetingScreenshotDisplayGeometry: Equatable, Sendable {
    let cocoaFrame: CGRect
    let quartzFrame: CGRect
}

struct MeetingScreenshotWindowMetadata: Equatable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let bounds: CGRect
    var layer: Int = 0
    var isOnScreen: Bool = true
    var alpha: Double = 1
    var isShareable: Bool = true
}

struct MeetingScreenshotWindowPickerSnapshot: Sendable {
    let windowsFrontToBack: [MeetingScreenshotWindowMetadata]
    let displays: [MeetingScreenshotDisplayGeometry]
    let ownProcessID: pid_t
}

enum MeetingScreenshotWindowCoordinates {
    static func quartzPoint(
        fromCocoa point: CGPoint,
        displays: [MeetingScreenshotDisplayGeometry]
    ) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              let display = displays.first(where: {
                  isUsable($0.cocoaFrame) && isUsable($0.quartzFrame)
                      && $0.cocoaFrame.contains(point)
              }) else { return nil }

        // Pair the two coordinate systems for this display. In particular,
        // NSScreen.main and the tallest/combined screen height are not origins.
        let xScale = display.quartzFrame.width / display.cocoaFrame.width
        let yScale = display.quartzFrame.height / display.cocoaFrame.height
        return CGPoint(
            x: display.quartzFrame.minX + (point.x - display.cocoaFrame.minX) * xScale,
            y: display.quartzFrame.minY + (display.cocoaFrame.maxY - point.y) * yScale
        )
    }

    static func overlayRect(
        forQuartz rect: CGRect,
        on display: MeetingScreenshotDisplayGeometry
    ) -> CGRect? {
        guard isUsable(rect), isUsable(display.cocoaFrame),
              isUsable(display.quartzFrame) else { return nil }
        let clipped = rect.intersection(display.quartzFrame)
        guard isUsable(clipped) else { return nil }
        let xScale = display.cocoaFrame.width / display.quartzFrame.width
        let yScale = display.cocoaFrame.height / display.quartzFrame.height
        return CGRect(
            x: (clipped.minX - display.quartzFrame.minX) * xScale,
            y: (display.quartzFrame.maxY - clipped.maxY) * yScale,
            width: clipped.width * xScale,
            height: clipped.height * yScale
        )
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }
}

enum MeetingScreenshotWindowHitTest {
    static func frontmostWindow(
        at point: CGPoint,
        windowsFrontToBack: [MeetingScreenshotWindowMetadata],
        ownProcessID: pid_t,
        displayBounds: [CGRect]
    ) -> MeetingScreenshotWindowMetadata? {
        guard point.x.isFinite, point.y.isFinite,
              displayBounds.contains(where: {
                  MeetingScreenshotWindowCoordinates.isUsable($0) && $0.contains(point)
              }) else { return nil }
        return windowsFrontToBack.first {
            $0.windowID != kCGNullWindowID
                && $0.processID > 0 && $0.processID != ownProcessID
                && $0.layer == 0 && $0.isOnScreen && $0.isShareable
                && $0.alpha.isFinite && $0.alpha > 0
                && MeetingScreenshotWindowCoordinates.isUsable($0.bounds)
                && $0.bounds.contains(point)
        }
    }
}

struct MeetingScreenshotWindowSelectionIntent {
    private(set) var highlightedWindow: MeetingScreenshotWindowMetadata?

    mutating func updateHover(_ window: MeetingScreenshotWindowMetadata?) {
        highlightedWindow = window
    }

    mutating func selectionForClick(
        refreshedWindow: MeetingScreenshotWindowMetadata?
    ) -> MeetingScreenshotWindowMetadata? {
        let expectedWindow = highlightedWindow
        highlightedWindow = refreshedWindow
        // A vanished/moved window can expose another window under a stationary
        // pointer. Show that new target first; never reinterpret this click as
        // consent to capture a window that was not previously highlighted.
        guard let expectedWindow, let refreshedWindow,
              expectedWindow.windowID == refreshedWindow.windowID,
              expectedWindow.processID == refreshedWindow.processID else { return nil }
        return refreshedWindow
    }
}

enum MeetingScreenshotWindowOverlayEvent {
    case selected(MeetingScreenshotWindowMetadata)
    case cancelled
    case failure(Error)
}

@MainActor
protocol MeetingScreenshotWindowSelectionPresenting: AnyObject {
    func present(
        snapshot: MeetingScreenshotWindowPickerSnapshot,
        onEvent: @escaping @MainActor (MeetingScreenshotWindowOverlayEvent) -> Void
    ) throws
    func dismiss()
}

@MainActor
protocol MeetingScreenshotWindowSelecting {
    func selectWindow() async throws -> MeetingScreenshotWindowSelection?
}

@MainActor
final class MeetingScreenshotDirectWindowPicker: MeetingScreenshotWindowSelecting {
    typealias SnapshotLoader = @MainActor () async throws
        -> MeetingScreenshotWindowPickerSnapshot
    typealias SelectionResolver = @MainActor (MeetingScreenshotWindowMetadata) async throws
        -> MeetingScreenshotWindowSelection?
    typealias OverlayFactory = @MainActor () -> any MeetingScreenshotWindowSelectionPresenting

    private final class Request {
        let gate = MeetingScreenshotSelectionGate()
        var overlay: (any MeetingScreenshotWindowSelectionPresenting)?
        var preparation: Task<Void, Never>?
        var resolution: Task<Void, Never>?
        var isResolving = false
    }

    private let loadSnapshot: SnapshotLoader
    private let resolveSelection: SelectionResolver
    private let makeOverlay: OverlayFactory
    private var activeRequest: Request?

    convenience init() {
        self.init(
            loadSnapshot: { try await MeetingScreenshotWindowMetadataReader.snapshot() },
            resolveSelection: { try await MeetingScreenshotWindowMetadataReader.resolve($0) },
            makeOverlay: { MeetingScreenshotWindowOverlay() }
        )
    }

    init(
        loadSnapshot: @escaping SnapshotLoader,
        resolveSelection: @escaping SelectionResolver,
        makeOverlay: @escaping OverlayFactory
    ) {
        self.loadSnapshot = loadSnapshot
        self.resolveSelection = resolveSelection
        self.makeOverlay = makeOverlay
    }

    func selectWindow() async throws -> MeetingScreenshotWindowSelection? {
        try Task.checkCancellation()
        guard activeRequest == nil else {
            throw MeetingScreenshotCaptureError.captureFailed
        }
        let request = Request()
        let gate = request.gate
        activeRequest = request
        defer {
            request.preparation?.cancel()
            request.preparation = nil
            request.resolution?.cancel()
            request.resolution = nil
            dismissOverlay(for: request)
            if activeRequest === request { activeRequest = nil }
        }

        return try await withTaskCancellationHandler {
            request.preparation = Task { [weak self] in
                await self?.prepare(request)
            }
            let selection = try await gate.wait()
            try Task.checkCancellation()
            return selection
        } onCancel: {
            // This resumes independently of metadata/resolver cooperation.
            // MainActor defer removes this request's UI before returning.
            gate.finish(.failure(CancellationError()))
        }
    }

    private func prepare(_ request: Request) async {
        do {
            try Task.checkCancellation()
            guard isCurrent(request) else { return }
            let snapshot = try await loadSnapshot()
            try Task.checkCancellation()
            guard isCurrent(request) else { return }
            guard !snapshot.displays.isEmpty else {
                throw MeetingScreenshotCaptureError.noDisplayAvailable
            }
            let overlay = makeOverlay()
            request.overlay = overlay
            try overlay.present(snapshot: snapshot) { [weak self, weak request] event in
                guard let self, let request else { return }
                self.receive(event, for: request)
            }
        } catch {
            finish(.failure(error), for: request)
        }
    }

    private func receive(_ event: MeetingScreenshotWindowOverlayEvent, for request: Request) {
        guard isCurrent(request), !request.isResolving else { return }
        switch event {
        case let .selected(window):
            request.isResolving = true
            dismissOverlay(for: request)
            request.resolution = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard self.isCurrent(request) else { return }
                    let selection = try await self.resolveSelection(window)
                    try Task.checkCancellation()
                    guard self.isCurrent(request) else { return }
                    guard let selection else {
                        throw MeetingScreenshotCaptureError.captureFailed
                    }
                    self.finish(.selected(selection), for: request)
                } catch {
                    self.finish(.failure(error), for: request)
                }
            }
        case .cancelled:
            finish(.cancelled, for: request)
        case let .failure(error):
            finish(.failure(error), for: request)
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        activeRequest === request && request.gate.isPending
    }

    private func finish(_ result: MeetingScreenshotSelectionGate.TerminalResult, for request: Request) {
        guard activeRequest === request else { return }
        dismissOverlay(for: request)
        request.gate.finish(result)
    }

    private func dismissOverlay(for request: Request) {
        let overlay = request.overlay
        request.overlay = nil
        overlay?.dismiss()
    }
}

@MainActor
private enum MeetingScreenshotWindowMetadataReader {
    static func snapshot() async throws -> MeetingScreenshotWindowPickerSnapshot {
        // Called only after the user's screenshot action. ScreenCaptureKit
        // retains its normal system-controlled screen-recording authorization.
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        let displays = NSScreen.screens.compactMap { screen -> MeetingScreenshotDisplayGeometry? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            let quartzFrame = CGDisplayBounds(number.uint32Value)
            guard MeetingScreenshotWindowCoordinates.isUsable(screen.frame),
                  MeetingScreenshotWindowCoordinates.isUsable(quartzFrame) else { return nil }
            return MeetingScreenshotDisplayGeometry(cocoaFrame: screen.frame, quartzFrame: quartzFrame)
        }
        guard !displays.isEmpty else { throw MeetingScreenshotCaptureError.noDisplayAvailable }
        return MeetingScreenshotWindowPickerSnapshot(
            windowsFrontToBack: try orderedWindows(
                shareableWindowIDs: Set(content.windows.map(\.windowID))
            ),
            displays: displays,
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }

    static func orderedWindows(
        shareableWindowIDs: Set<CGWindowID>
    ) throws -> [MeetingScreenshotWindowMetadata] {
        // Quartz returns these dictionaries front-to-back. Do not derive
        // stacking from SCShareableContent.windows, titles, IDs, or app order.
        guard let dictionaries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { throw MeetingScreenshotCaptureError.captureFailed }
        return dictionaries.compactMap { dictionary in
            guard let number = dictionary[kCGWindowNumber as String] as? NSNumber,
                  let owner = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = dictionary[kCGWindowLayer as String] as? NSNumber,
                  let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return MeetingScreenshotWindowMetadata(
                windowID: number.uint32Value,
                processID: owner.int32Value,
                bounds: rect,
                layer: layer.intValue,
                isOnScreen: (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
                isShareable: shareableWindowIDs.contains(number.uint32Value)
            )
        }
    }

    static func resolve(
        _ selected: MeetingScreenshotWindowMetadata
    ) async throws -> MeetingScreenshotWindowSelection? {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        guard selected.processID != ProcessInfo.processInfo.processIdentifier,
              let window = content.windows.first(where: {
                  $0.windowID == selected.windowID
                      && $0.owningApplication?.processID == selected.processID
                      && $0.isOnScreen && $0.windowLayer == 0
                      && MeetingScreenshotWindowCoordinates.isUsable($0.frame)
              }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return MeetingScreenshotWindowSelection(
            contentRect: filter.contentRect,
            pointPixelScale: CGFloat(filter.pointPixelScale),
            contentFilter: filter
        )
    }
}

@MainActor
private final class MeetingScreenshotWindowOverlay: MeetingScreenshotWindowSelectionPresenting {
    private struct Surface {
        let panel: MeetingScreenshotSelectionPanel
        let view: MeetingScreenshotSelectionView
        let display: MeetingScreenshotDisplayGeometry
    }

    private var surfaces: [Surface] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var onEvent: (@MainActor (MeetingScreenshotWindowOverlayEvent) -> Void)?
    private var snapshot: MeetingScreenshotWindowPickerSnapshot?
    private var windowsFrontToBack: [MeetingScreenshotWindowMetadata] = []
    private var shareableWindowIDs: Set<CGWindowID> = []
    private var lastMetadataRefresh: TimeInterval = 0
    private var selectionIntent = MeetingScreenshotWindowSelectionIntent()

    func present(
        snapshot: MeetingScreenshotWindowPickerSnapshot,
        onEvent: @escaping @MainActor (MeetingScreenshotWindowOverlayEvent) -> Void
    ) throws {
        guard surfaces.isEmpty, !snapshot.displays.isEmpty else {
            throw MeetingScreenshotCaptureError.noDisplayAvailable
        }
        self.snapshot = snapshot
        self.onEvent = onEvent
        selectionIntent = MeetingScreenshotWindowSelectionIntent()
        windowsFrontToBack = snapshot.windowsFrontToBack
        shareableWindowIDs = Set(snapshot.windowsFrontToBack.filter(\.isShareable).map(\.windowID))
        lastMetadataRefresh = ProcessInfo.processInfo.systemUptime

        for display in snapshot.displays {
            let panel = MeetingScreenshotSelectionPanel(
                contentRect: display.cocoaFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.sharingType = .none
            let view = MeetingScreenshotSelectionView(frame: CGRect(origin: .zero, size: display.cocoaFrame.size))
            view.onPointer = { [weak self] point, clicked in self?.updatePointer(point, clicked: clicked) }
            view.onCancel = { [weak self] in self?.onEvent?(.cancelled) }
            panel.contentView = view
            panel.makeFirstResponder(view)
            surfaces.append(Surface(panel: panel, view: view, display: display))
        }

        observe(NSApplication.didChangeScreenParametersNotification, on: .default)
        observe(NSApplication.didResignActiveNotification, on: .default)
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: NSWorkspace.shared.notificationCenter)
        for surface in surfaces { surface.panel.orderFrontRegardless() }
        // This is a one-time location read, not a global event monitor/tap.
        let pointer = NSEvent.mouseLocation
        let keySurface = surfaces.first { $0.display.cocoaFrame.contains(pointer) } ?? surfaces.first
        keySurface?.panel.makeKey()
        updatePointer(pointer, clicked: false)
    }

    func dismiss() {
        onEvent = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        for surface in surfaces {
            surface.view.onPointer = nil
            surface.view.onCancel = nil
            surface.panel.orderOut(nil)
            surface.panel.close()
        }
        surfaces.removeAll()
        snapshot = nil
        windowsFrontToBack.removeAll()
        shareableWindowIDs.removeAll()
        selectionIntent = MeetingScreenshotWindowSelectionIntent()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onEvent?(.cancelled) }
        }
        observers.append((center, observer))
    }

    private func updatePointer(_ cocoaPoint: CGPoint, clicked: Bool) {
        guard let snapshot, onEvent != nil else { return }
        // Refresh metadata at most ten times per second while hovering, and
        // always on the selecting click. No pixels, thumbnails, or stream.
        let now = ProcessInfo.processInfo.systemUptime
        if clicked || now - lastMetadataRefresh >= 0.1 {
            do {
                windowsFrontToBack = try MeetingScreenshotWindowMetadataReader.orderedWindows(
                    shareableWindowIDs: shareableWindowIDs
                )
                lastMetadataRefresh = now
            } catch {
                onEvent?(.failure(error))
                return
            }
        }
        let window = MeetingScreenshotWindowCoordinates.quartzPoint(
            fromCocoa: cocoaPoint, displays: snapshot.displays
        ).flatMap {
            MeetingScreenshotWindowHitTest.frontmostWindow(
                at: $0, windowsFrontToBack: windowsFrontToBack,
                ownProcessID: snapshot.ownProcessID,
                displayBounds: snapshot.displays.map(\.quartzFrame)
            )
        }
        let selectedWindow: MeetingScreenshotWindowMetadata?
        if clicked {
            selectedWindow = selectionIntent.selectionForClick(refreshedWindow: window)
        } else {
            selectionIntent.updateHover(window)
            selectedWindow = nil
        }
        for surface in surfaces {
            surface.view.targetRect = selectionIntent.highlightedWindow.flatMap {
                MeetingScreenshotWindowCoordinates.overlayRect(forQuartz: $0.bounds, on: surface.display)
            }
        }
        if let selectedWindow { onEvent?(.selected(selectedWindow)) }
    }
}

@MainActor
private final class MeetingScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MeetingScreenshotSelectionView: NSView {
    var onPointer: ((CGPoint, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var targetRect: CGRect? {
        didSet {
            guard targetRect != oldValue else { return }
            hint.stringValue = targetRect == nil
                ? "移动到窗口上，点击截取 · Esc 取消"
                : "点击截取此窗口 · Esc 取消"
            needsDisplay = true
        }
    }

    private let hint = NSTextField(labelWithString: "移动到窗口上，点击截取 · Esc 取消")
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.masksToBounds = true
        material.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .labelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hint)
        addSubview(material)
        NSLayoutConstraint.activate([
            material.centerXAnchor.constraint(equalTo: centerXAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 48),
            material.widthAnchor.constraint(greaterThanOrEqualToConstant: 290),
            material.heightAnchor.constraint(equalToConstant: 40),
            hint.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            hint.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            hint.centerYAnchor.constraint(equalTo: material.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        pointerTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseMoved(with event: NSEvent) { sendPointer(event, clicked: false) }
    override func mouseEntered(with event: NSEvent) { sendPointer(event, clicked: false) }
    override func mouseDown(with event: NSEvent) { sendPointer(event, clicked: true) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    private func sendPointer(_ event: NSEvent, clicked: Bool) {
        guard let window else { return }
        window.makeKey()
        onPointer?(window.convertPoint(toScreen: event.locationInWindow), clicked)
    }

    override func draw(_ dirtyRect: NSRect) {
        // WindowServer skips fully transparent pixels before NSView.hitTest.
        // Keep the highlighted interior almost clear, but not click-through.
        // Copy replaces old shading when the target moves or is redrawn.
        NSColor.black.withAlphaComponent(0.02).setFill()
        bounds.fill(using: .copy)
        let shade = NSBezierPath(rect: bounds)
        if let targetRect {
            shade.append(NSBezierPath(roundedRect: targetRect, xRadius: 8, yRadius: 8))
            shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.16).setFill()
        shade.fill()
        if let targetRect {
            let border = NSBezierPath(roundedRect: targetRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.setStroke()
            border.lineWidth = 3
            border.stroke()
        }
    }
}
