import SwiftUI

struct TranscriptView: View {
    let transcripts: [TranscriptRecord]
    let bookmarks: [BookmarkRecord]

    private var sortedTranscripts: [TranscriptRecord] {
        transcripts.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
    }

    var body: some View {
        if sortedTranscripts.isEmpty {
            Label("暂无转录", systemImage: "text.bubble")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sortedTranscripts, id: \.id) { transcript in
                    let highlighted = isHighlighted(transcript)

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(MeetingDisplayFormat.timecode(transcript.startTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(transcript.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(9)
                    .background(
                        highlighted
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(MeetingDisplayFormat.timecode(transcript.startTime))，\(transcript.text)\(highlighted ? "，书签附近" : "")"
                    )
                }
            }
        }
    }

    private func isHighlighted(_ transcript: TranscriptRecord) -> Bool {
        bookmarks.contains {
            BookmarkWindow(bookmarkTime: $0.timestamp).intersects(
                transcriptStart: transcript.startTime,
                transcriptEnd: transcript.endTime
            )
        }
    }
}
