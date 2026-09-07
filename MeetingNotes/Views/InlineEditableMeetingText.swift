import AppKit
import Observation
import SwiftUI

struct InlineMeetingTextMeasurementKey: Equatable {
    let text: String
    let availableWidth: CGFloat?
    let fontName: String
    let fontPointSize: CGFloat
    let alignment: NSTextAlignment
    let lineLimit: Int?
}

struct InlineMeetingTextMeasurementCache {
    private var cachedKey: InlineMeetingTextMeasurementKey?
    private var cachedSize: CGSize?
    private(set) var computationCount = 0

    mutating func resolve(
        key: InlineMeetingTextMeasurementKey,
        compute: () -> CGSize
    ) -> CGSize {
        if cachedKey == key, let cachedSize {
            return cachedSize
        }
        let size = compute()
        cachedKey = key
        cachedSize = size
        computationCount += 1
        return size
    }
}

@MainActor
@Observable
final class InlineMeetingTextLocalBuffer {
    private(set) var value: String

    init(initialValue: String) {
        value = initialValue
    }

    func updateFromNative(
        _ newValue: String,
        propagate: (String) -> Void
    ) {
        if value != newValue {
            value = newValue
        }
        propagate(newValue)
    }

    func reconcile(externalValue: String) {
        guard value != externalValue else { return }
        value = externalValue
    }
}

final class InlineMeetingNativeTextView: NSTextView {
    weak var replacementTarget: AnyObject?
    var replacementAction: Selector?
    var onStringChange: ((String) -> Void)?
    var measurementCache = InlineMeetingTextMeasurementCache()
    private weak var observedUndoManager: UndoManager?
    private var textBeforeUndoOrRedo: String?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateUndoManagerObservation()
    }

    private func updateUndoManagerObservation() {
        let manager = window == nil ? nil : undoManager
        guard manager !== observedUndoManager else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
        ]
        for name in names {
            center.removeObserver(
                self, name: name, object: observedUndoManager
            )
        }
        observedUndoManager = manager
        textBeforeUndoOrRedo = nil
        guard let manager else { return }
        for name in [
            Notification.Name.NSUndoManagerWillUndoChange,
            Notification.Name.NSUndoManagerWillRedoChange,
        ] {
            center.addObserver(
                self, selector: #selector(nativeUndoOrRedoWillStart(_:)),
                name: name, object: manager
            )
        }
        for name in [
            Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange,
        ] {
            center.addObserver(
                self, selector: #selector(nativeUndoOrRedoDidComplete(_:)),
                name: name, object: manager
            )
        }
    }

    @objc private func nativeUndoOrRedoWillStart(_ notification: Notification) {
        guard window != nil,
              let manager = notification.object as? UndoManager,
              manager === observedUndoManager,
              manager === undoManager else { return }
        textBeforeUndoOrRedo = string
    }

    @objc private func nativeUndoOrRedoDidComplete(_ notification: Notification) {
        guard window != nil,
              let manager = notification.object as? UndoManager,
              manager === observedUndoManager,
              manager === undoManager else { return }
        let previous = textBeforeUndoOrRedo
        textBeforeUndoOrRedo = nil
        guard let previous, previous != string else { return }
        // Native undo can mutate text storage without calling didChangeText().
        // Reconcile synchronously, before a SwiftUI refresh can replay old text.
        // Other editors sharing the window's manager must not publish stale text.
        onStringChange?(string)
        invalidateIntrinsicContentSize()
    }

    @discardableResult
    func applyPresentation(
        font: NSFont,
        textColor: NSColor,
        alignment: NSTextAlignment,
        lineLimit: Int?
    ) -> Bool {
        var layoutChanged = false
        if self.font != font {
            self.font = font
            layoutChanged = true
        }
        if self.textColor != textColor {
            self.textColor = textColor
        }
        if self.alignment != alignment {
            self.alignment = alignment
            layoutChanged = true
        }
        if textContainer?.maximumNumberOfLines != (lineLimit ?? 0) {
            textContainer?.maximumNumberOfLines = lineLimit ?? 0
            layoutChanged = true
        }
        if textContainer?.lineBreakMode != .byCharWrapping {
            textContainer?.lineBreakMode = .byCharWrapping
            layoutChanged = true
        }
        return layoutChanged
    }

    func measuredSize(
        availableWidth: CGFloat?,
        font: NSFont,
        alignment: NSTextAlignment,
        lineLimit: Int?,
        measure: (NSString, NSSize, [NSAttributedString.Key: Any]) -> NSRect = {
            text, size, attributes in
            text.boundingRect(
                with: size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }
    ) -> CGSize {
        let measurementText = string.isEmpty ? " " : string
        let key = InlineMeetingTextMeasurementKey(
            text: measurementText,
            availableWidth: availableWidth,
            fontName: font.fontName,
            fontPointSize: font.pointSize,
            alignment: alignment,
            lineLimit: lineLimit
        )
        return measurementCache.resolve(key: key) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = alignment
            paragraphStyle.lineBreakMode = .byCharWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ]
            let measuredWidth: CGFloat
            if let availableWidth {
                measuredWidth = availableWidth
            } else {
                let unconstrained = measure(
                    measurementText as NSString,
                    NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
                    attributes
                )
                measuredWidth = ceil(unconstrained.width)
            }
            let lineHeight = ceil(
                font.ascender - font.descender + font.leading
            )
            guard measuredWidth > 0 else {
                return CGSize(width: 0, height: lineHeight)
            }
            let measured = measure(
                measurementText as NSString,
                NSSize(width: measuredWidth, height: CGFloat.greatestFiniteMagnitude),
                attributes
            )
            var measuredHeight = max(ceil(measured.height), lineHeight)
            if let lineLimit {
                measuredHeight = min(
                    measuredHeight,
                    lineHeight * CGFloat(lineLimit)
                )
            }
            return CGSize(width: measuredWidth, height: measuredHeight)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // Also handles managers supplied lazily by a window or text delegate.
        updateUndoManagerObservation()
        onStringChange?(string)
        invalidateIntrinsicContentSize()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        _ = window?.makeFirstResponder(self)
        guard let replacementTarget,
              let replacementAction else {
            return super.menu(for: event)
        }
        return augmentedContextMenu(
            sourceMenu: super.menu(for: event) ?? NSTextView.defaultMenu,
            replacementTarget: replacementTarget,
            replacementAction: replacementAction
        )
    }

    func augmentedContextMenu(
        sourceMenu: NSMenu?,
        replacementTarget: AnyObject,
        replacementAction: Selector
    ) -> NSMenu {
        let menu = (sourceMenu?.copy() as? NSMenu) ?? NSMenu()
        bindNativeEditingCommands(in: menu)
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        let replacement = NSMenuItem(
            title: "替换本会议相同文字…",
            action: replacementAction,
            keyEquivalent: ""
        )
        replacement.target = replacementTarget
        menu.addItem(replacement)
        return menu
    }

    private func bindNativeEditingCommands(in menu: NSMenu) {
        let directEditorActions = [
            #selector(NSText.cut(_:)),
            #selector(NSText.copy(_:)),
            #selector(NSText.paste(_:)),
            #selector(NSTextView.pasteAsPlainText(_:)),
            #selector(NSText.delete(_:)),
            #selector(NSText.selectAll(_:)),
        ]
        for item in menu.items {
            if let action = item.action,
               directEditorActions.contains(action) {
                item.target = self
            }
            if let submenu = item.submenu {
                bindNativeEditingCommands(in: submenu)
            }
        }
    }
}

/// Preserves SwiftUI's original `Text` sizing and wrapping while placing a
/// transparent native editor over exactly the same bounds.
struct InlineEditableMeetingText: View {
    @Binding var text: String

    var font: Font.TextStyle = .body
    var fontWeight: Font.Weight?
    var foregroundColor: Color = .primary
    var alignment: TextAlignment = .leading
    var lineLimit: Int?
    let accessibilityIdentifier: String
    var onFlush: () -> Void = {}
    var onRequestExactReplacement: ((String) -> Void)?

    var body: some View {
        InlineEditableMeetingTextContent(
            externalText: $text,
            font: font,
            fontWeight: fontWeight,
            foregroundColor: foregroundColor,
            alignment: alignment,
            lineLimit: lineLimit,
            accessibilityIdentifier: accessibilityIdentifier,
            onFlush: onFlush,
            onRequestExactReplacement: onRequestExactReplacement
        )
    }

    static func layoutWidth(
        proposal: CGFloat?,
        fittingWidth: CGFloat
    ) -> CGFloat {
        InlineEditableMeetingNativeView.layoutWidth(
            proposal: proposal,
            fittingWidth: fittingWidth
        )
    }

    static func measurementWidth(
        proposal: CGFloat?,
        currentWidth: CGFloat,
        fittingWidth: CGFloat
    ) -> CGFloat {
        InlineEditableMeetingNativeView.measurementWidth(
            proposal: proposal,
            currentWidth: currentWidth,
            fittingWidth: fittingWidth
        )
    }
}

private struct InlineEditableMeetingTextContent: View {
    @Binding var externalText: String
    @State private var buffer: InlineMeetingTextLocalBuffer

    let font: Font.TextStyle
    let fontWeight: Font.Weight?
    let foregroundColor: Color
    let alignment: TextAlignment
    let lineLimit: Int?
    let accessibilityIdentifier: String
    let onFlush: () -> Void
    let onRequestExactReplacement: ((String) -> Void)?

    init(
        externalText: Binding<String>,
        font: Font.TextStyle,
        fontWeight: Font.Weight?,
        foregroundColor: Color,
        alignment: TextAlignment,
        lineLimit: Int?,
        accessibilityIdentifier: String,
        onFlush: @escaping () -> Void,
        onRequestExactReplacement: ((String) -> Void)?
    ) {
        _externalText = externalText
        _buffer = State(
            initialValue: InlineMeetingTextLocalBuffer(
                initialValue: externalText.wrappedValue
            )
        )
        self.font = font
        self.fontWeight = fontWeight
        self.foregroundColor = foregroundColor
        self.alignment = alignment
        self.lineLimit = lineLimit
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onFlush = onFlush
        self.onRequestExactReplacement = onRequestExactReplacement
    }

    var body: some View {
        Text(buffer.value.isEmpty ? " " : buffer.value)
            .font(.system(font, weight: fontWeight ?? .regular))
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(alignment)
            .lineLimit(lineLimit)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                InlineEditableMeetingNativeView(
                    text: Binding(
                        get: { buffer.value },
                        set: { newValue in
                            buffer.updateFromNative(newValue) {
                                externalText = $0
                            }
                        }
                    ),
                    font: font,
                    fontWeight: fontWeight,
                    foregroundColor: foregroundColor,
                    alignment: alignment,
                    lineLimit: lineLimit,
                    accessibilityIdentifier: accessibilityIdentifier,
                    onFlush: onFlush,
                    onRequestExactReplacement:
                        onRequestExactReplacement
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: externalText) { _, newValue in
                buffer.reconcile(externalValue: newValue)
            }
    }
}

/// A native text control that leaves surface, spacing and decoration to the
/// existing meeting presentation. The value shown in place is always editable;
/// there is no separate editing mode or visible editing affordance.
private struct InlineEditableMeetingNativeView: NSViewRepresentable {
    @Binding var text: String

    var font: Font.TextStyle = .body
    var fontWeight: Font.Weight?
    var foregroundColor: Color = .primary
    var alignment: TextAlignment = .leading
    var lineLimit: Int?
    let accessibilityIdentifier: String
    var onFlush: () -> Void = {}
    var onRequestExactReplacement: ((String) -> Void)?

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private var lineLimit: Int?
        private var onFlush: () -> Void
        private var onRequestExactReplacement: ((String) -> Void)?
        weak var textView: InlineMeetingNativeTextView?

        init(parent: InlineEditableMeetingNativeView) {
            text = parent.$text
            lineLimit = parent.lineLimit
            onFlush = parent.onFlush
            onRequestExactReplacement = parent.onRequestExactReplacement
        }

        func update(parent: InlineEditableMeetingNativeView) {
            text = parent.$text
            lineLimit = parent.lineLimit
            onFlush = parent.onFlush
            onRequestExactReplacement = parent.onRequestExactReplacement
        }

        func receiveTextChange(_ value: String) {
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            _ = notification
            synchronizeText()
            onFlush()
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
            else {
                return false
            }
            if lineLimit == 1 {
                synchronizeText()
                onFlush()
                textView.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        @objc func requestExactReplacement(_ sender: Any?) {
            _ = sender
            synchronizeText()
            onFlush()
            if let textView {
                onRequestExactReplacement?(textView.string)
            }
        }

        private func synchronizeText() {
            guard let textView else { return }
            let value = textView.string
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(
        context: Context
    ) -> InlineMeetingNativeTextView {
        let textView = InlineMeetingNativeTextView(frame: .zero)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.onStringChange = { [weak coordinator = context.coordinator]
            value in
            coordinator?.receiveTextChange(value)
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.allowsUndo = true
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        configureReplacementMenu(
            on: textView,
            coordinator: context.coordinator
        )
        applyPresentation(to: textView)
        textView.string = text
        return textView
    }

    func updateNSView(
        _ textView: InlineMeetingNativeTextView,
        context: Context
    ) {
        context.coordinator.update(parent: self)
        context.coordinator.textView = textView
        textView.onStringChange = { [weak coordinator = context.coordinator]
            value in
            coordinator?.receiveTextChange(value)
        }
        let textChanged = textView.string != text
        if textChanged {
            textView.string = text
        }
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        configureReplacementMenu(
            on: textView,
            coordinator: context.coordinator
        )
        let presentationChanged = applyPresentation(to: textView)
        if textChanged || presentationChanged {
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: InlineMeetingNativeTextView,
        context: Context
    ) -> CGSize? {
        _ = context
        let availableWidth = Self.availableMeasurementWidth(
            proposal: proposal.width,
            currentWidth: textView.bounds.width
        )
        return textView.measuredSize(
            availableWidth: availableWidth,
            font: nativeFont,
            alignment: nativeAlignment,
            lineLimit: lineLimit
        )
    }

    static func layoutWidth(
        proposal: CGFloat?,
        fittingWidth: CGFloat
    ) -> CGFloat {
        guard let proposal, proposal.isFinite else { return fittingWidth }
        return max(proposal, 0)
    }

    static func measurementWidth(
        proposal: CGFloat?,
        currentWidth: CGFloat,
        fittingWidth: CGFloat
    ) -> CGFloat {
        if let proposal, proposal.isFinite {
            return max(proposal, 0)
        }
        if currentWidth.isFinite, currentWidth > 0 {
            return currentWidth
        }
        return fittingWidth
    }

    private static func availableMeasurementWidth(
        proposal: CGFloat?,
        currentWidth: CGFloat
    ) -> CGFloat? {
        if let proposal, proposal.isFinite {
            return max(proposal, 0)
        }
        if currentWidth.isFinite, currentWidth > 0 {
            return currentWidth
        }
        return nil
    }

    @discardableResult
    private func applyPresentation(to textView: InlineMeetingNativeTextView) -> Bool {
        textView.applyPresentation(
            font: nativeFont,
            textColor: NSColor(foregroundColor),
            alignment: nativeAlignment,
            lineLimit: lineLimit
        )
    }

    private func configureReplacementMenu(
        on textView: InlineMeetingNativeTextView,
        coordinator: Coordinator
    ) {
        guard onRequestExactReplacement != nil else {
            textView.replacementTarget = nil
            textView.replacementAction = nil
            return
        }
        textView.replacementTarget = coordinator
        textView.replacementAction =
            #selector(Coordinator.requestExactReplacement(_:))
    }

    private var nativeFont: NSFont {
        let textStyle: NSFont.TextStyle = switch font {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .caption: .caption1
        case .caption2: .caption2
        case .footnote: .footnote
        default: .body
        }
        let preferred = NSFont.preferredFont(forTextStyle: textStyle)
        guard let fontWeight else { return preferred }
        return NSFont.systemFont(
            ofSize: preferred.pointSize,
            weight: nativeWeight(fontWeight)
        )
    }

    private func nativeWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    private var nativeAlignment: NSTextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .right
        default: .left
        }
    }
}
