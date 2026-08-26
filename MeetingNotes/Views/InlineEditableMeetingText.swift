import AppKit
import SwiftUI

final class InlineMeetingNativeTextView: NSTextView {
    weak var replacementTarget: AnyObject?
    var replacementAction: Selector?
    var onStringChange: ((String) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
    }

    override func didChangeText() {
        super.didChangeText()
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
        Text(text.isEmpty ? " " : text)
            .font(.system(font, weight: fontWeight ?? .regular))
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(alignment)
            .lineLimit(lineLimit)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                InlineEditableMeetingNativeView(
                    text: $text,
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
        if textView.string != text {
            textView.string = text
        }
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        configureReplacementMenu(
            on: textView,
            coordinator: context.coordinator
        )
        applyPresentation(to: textView)
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: InlineMeetingNativeTextView,
        context: Context
    ) -> CGSize? {
        _ = context
        let measurementText = textView.string.isEmpty ? " " : textView.string
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = nativeAlignment
        paragraphStyle.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: nativeFont,
            .paragraphStyle: paragraphStyle,
        ]
        let unconstrained = (measurementText as NSString).boundingRect(
            with: NSSize(
                width: 10_000,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let fittingSize = CGSize(
            width: ceil(unconstrained.width),
            height: ceil(unconstrained.height)
        )
        let measuredWidth = Self.measurementWidth(
            proposal: proposal.width,
            currentWidth: textView.bounds.width,
            fittingWidth: fittingSize.width
        )
        let lineHeight = ceil(
            nativeFont.ascender
                - nativeFont.descender
                + nativeFont.leading
        )
        guard measuredWidth > 0 else {
            return CGSize(width: 0, height: lineHeight)
        }
        let measured = (measurementText as NSString).boundingRect(
            with: NSSize(
                width: measuredWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        var measuredHeight = max(ceil(measured.height), lineHeight)
        if let lineLimit {
            measuredHeight = min(
                measuredHeight,
                lineHeight * CGFloat(lineLimit)
            )
        }
        return CGSize(
            width: measuredWidth,
            height: measuredHeight
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

    private func applyPresentation(to textView: NSTextView) {
        textView.font = nativeFont
        textView.textColor = NSColor(foregroundColor)
        textView.alignment = nativeAlignment
        textView.textContainer?.maximumNumberOfLines = lineLimit ?? 0
        textView.textContainer?.lineBreakMode = .byCharWrapping
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
