import SwiftUI

struct MeetingDocumentModeSliderDragUpdate: Equatable {
    let selection: MeetingDocumentKind
    let dragOffset: CGFloat
}

enum MeetingDocumentModeSliderDragPolicy {
    static func update(
        startingSelection: MeetingDocumentKind,
        locationX: CGFloat,
        width: CGFloat
    ) -> MeetingDocumentModeSliderDragUpdate {
        guard width > 0, width.isFinite, locationX.isFinite else {
            return MeetingDocumentModeSliderDragUpdate(
                selection: startingSelection,
                dragOffset: 0
            )
        }

        let segmentWidth = width / 2
        let midpoint = segmentWidth
        let selection: MeetingDocumentKind
        if locationX < midpoint {
            selection = .summary
        } else if locationX > midpoint {
            selection = .detailedMinutes
        } else {
            selection = startingSelection
        }

        let selectedCenter = selection == .summary
            ? segmentWidth / 2
            : segmentWidth * 1.5
        let rawOffset = locationX - selectedCenter
        let limit = segmentWidth * 0.48
        let dragOffset = switch selection {
        case .summary:
            min(limit, max(0, rawOffset))
        case .detailedMinutes:
            max(-limit, min(0, rawOffset))
        }
        return MeetingDocumentModeSliderDragUpdate(
            selection: selection,
            dragOffset: dragOffset
        )
    }
}

struct MeetingDocumentModeSlider: View {
    @Binding var selection: MeetingDocumentKind
    let isDisabled: Bool

    @Namespace private var selectedBackground
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartingSelection: MeetingDocumentKind?

    private let animation = Animation.spring(
        response: 0.28,
        dampingFraction: 0.84
    )

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                option(
                    title: "重点总结",
                    kind: .summary,
                    identifier: "meeting.documents.mode.summary"
                )
                option(
                    title: "完整纪要",
                    kind: .detailedMinutes,
                    identifier: "meeting.documents.mode.detailed"
                )
            }
            .padding(3)
            .background(.quaternary.opacity(0.55), in: Capsule())
            .contentShape(Capsule())
            .simultaneousGesture(dragGesture(width: geometry.size.width))
        }
        .frame(height: 40)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.documents.mode")
    }

    private func option(
        title: String,
        kind: MeetingDocumentKind,
        identifier: String
    ) -> some View {
        Button {
            select(kind)
        } label: {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(selection == kind ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selection == kind {
                        Capsule()
                            .fill(.background.opacity(0.92))
                            .shadow(
                                color: .black.opacity(0.12),
                                radius: 5,
                                y: 2
                            )
                            .matchedGeometryEffect(
                                id: "meeting-document-selection",
                                in: selectedBackground
                            )
                            .offset(x: dragOffset)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selection == kind ? .isSelected : [])
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !isDisabled else { return }
                let startingSelection: MeetingDocumentKind
                if let dragStartingSelection {
                    startingSelection = dragStartingSelection
                } else {
                    startingSelection = selection
                    dragStartingSelection = selection
                }
                let update = MeetingDocumentModeSliderDragPolicy.update(
                    startingSelection: startingSelection,
                    locationX: value.location.x,
                    width: width
                )
                withAnimation(animation) {
                    selection = update.selection
                    dragOffset = update.dragOffset
                }
            }
            .onEnded { _ in
                withAnimation(animation) {
                    dragOffset = 0
                }
                dragStartingSelection = nil
            }
    }

    private func select(_ kind: MeetingDocumentKind) {
        guard !isDisabled, selection != kind else { return }
        withAnimation(animation) {
            selection = kind
            dragOffset = 0
        }
    }
}
