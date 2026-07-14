import SwiftUI

struct BookmarkListView: View {
    let bookmarks: [BookmarkRecord]

    private var sortedBookmarks: [BookmarkRecord] {
        bookmarks.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        if sortedBookmarks.isEmpty {
            Label("暂无书签", systemImage: "bookmark")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            FlowLayout(spacing: 8) {
                ForEach(sortedBookmarks, id: \.id) { bookmark in
                    Label(
                        MeetingDisplayFormat.timecode(bookmark.timestamp),
                        systemImage: "bookmark.fill"
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.tint.opacity(0.1), in: Capsule())
                    .accessibilityLabel(
                        "书签 \(MeetingDisplayFormat.timecode(bookmark.timestamp))"
                    )
                    .accessibilityIdentifier("meeting.bookmark")
                }
            }
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(
            proposal: proposal,
            subviews: subviews,
            place: false
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        _ = layout(
            proposal: ProposedViewSize(
                width: bounds.width,
                height: proposal.height
            ),
            subviews: subviews,
            origin: bounds.origin,
            place: true
        )
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews,
        origin: CGPoint = .zero,
        place: Bool
    ) -> (size: CGSize, placements: [(CGPoint, ProposedViewSize)]) {
        let availableWidth = proposal.width ?? .infinity
        var point = origin
        var rowHeight: CGFloat = 0
        var maxX = origin.x
        var placements: [(CGPoint, ProposedViewSize)] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > origin.x,
               point.x + size.width > origin.x + availableWidth {
                point.x = origin.x
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            let childProposal = ProposedViewSize(size)
            placements.append((point, childProposal))
            if place {
                subview.place(at: point, proposal: childProposal)
            }
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, point.x - spacing)
        }

        return (
            CGSize(
                width: max(0, maxX - origin.x),
                height: max(0, point.y - origin.y + rowHeight)
            ),
            placements
        )
    }
}
