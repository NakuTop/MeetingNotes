import AppKit
import SwiftUI

struct MeetingNoteTimelineEventView: View {
    let item: MeetingNoteDisplayItem
    @Binding var text: String
    var onFlush: (() -> Void)?
    var onRequestExactReplacement: ((String) -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(MeetingDisplayFormat.timecode(item.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Image(systemName: "square.and.pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            InlineEditableMeetingText(
                text: $text,
                accessibilityIdentifier: "meeting.timeline.note.\(item.id)",
                onFlush: { onFlush?() },
                onRequestExactReplacement: onRequestExactReplacement
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if let onDelete {
                Button("删除笔记", role: .destructive) {
                    onDelete()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(MeetingDisplayFormat.timecode(item.timestamp))，笔记，\(text)"
        )
    }
}

struct MeetingScreenshotTimelineEventView: View {
    let item: MeetingScreenshotDisplayItem
    let resolveURL: () async -> URL?
    let onOpen: (URL) -> Void
    var onDelete: (() -> Void)?

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(MeetingDisplayFormat.timecode(item.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 7)
            Image(systemName: "camera.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Button {
                Task {
                    if let url = await resolveURL() {
                        onOpen(url)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    thumbnailView
                    VStack(alignment: .leading, spacing: 3) {
                        Text("截图")
                            .font(.callout.weight(.medium))
                        Text("\(item.pixelWidth) x \(item.pixelHeight)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.timeline.screenshot.\(item.id)")
            .accessibilityLabel(
                "\(MeetingDisplayFormat.timecode(item.timestamp))，截图"
            )
        }
        .padding(9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if let onDelete {
                Button("删除截图", role: .destructive) {
                    onDelete()
                }
            }
        }
        .task(id: item.id) {
            guard let url = await resolveURL(), !Task.isCancelled else {
                return
            }
            thumbnail = NSImage(contentsOf: url)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 116, height: 68)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 116, height: 68)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
