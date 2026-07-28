import SwiftUI

struct TranscriptDisplayEntry: Identifiable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerID: String?
    let source: TranscriptAudioSource
}

struct TranscriptSpeakerBadge: Equatable, Sendable {
    let label: String
    let paletteIndex: Int
    let isLocalUser: Bool
}

enum TranscriptSpeakerDisplayPolicy {
    private static let paletteCount = 6

    static func badge(
        speakerID: String?,
        source: TranscriptAudioSource
    ) -> TranscriptSpeakerBadge? {
        guard let speakerID else { return nil }

        switch (speakerID, source) {
        case ("me", .microphone):
            return TranscriptSpeakerBadge(
                label: "我",
                paletteIndex: 0,
                isLocalUser: true
            )
        case ("remote", .system):
            return TranscriptSpeakerBadge(
                label: "远端",
                paletteIndex: 0,
                isLocalUser: false
            )
        case (_, .system):
            return numberedBadge(
                speakerID: speakerID,
                prefix: "remote",
                labelPrefix: "远端"
            )
        case (_, .room):
            return numberedBadge(
                speakerID: speakerID,
                prefix: "room",
                labelPrefix: "说话人"
            )
        case (_, .microphone), (_, .mixed):
            return nil
        }
    }

    private static func numberedBadge(
        speakerID: String,
        prefix: String,
        labelPrefix: String
    ) -> TranscriptSpeakerBadge? {
        let expectedPrefix = "\(prefix)-"
        guard speakerID.hasPrefix(expectedPrefix),
              let number = Int(speakerID.dropFirst(expectedPrefix.count)),
              number > 0 else {
            return nil
        }
        return TranscriptSpeakerBadge(
            label: "\(labelPrefix) \(number)",
            paletteIndex: (number - 1) % paletteCount,
            isLocalUser: false
        )
    }
}

enum TranscriptDisplayPolicy {
    static func entries(
        from transcripts: [TranscriptRecord]
    ) -> [TranscriptDisplayEntry] {
        transcripts
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }
            .compactMap { transcript in
                guard let text = TranscriptTextSanitizer.nonEmpty(
                    transcript.text
                ) else {
                    return nil
                }
                return TranscriptDisplayEntry(
                    id: transcript.id,
                    startTime: transcript.startTime,
                    endTime: transcript.endTime,
                    text: text,
                    speakerID: transcript.speakerID,
                    source: transcript.source
                )
            }
    }
}

struct TranscriptView: View {
    let transcripts: [TranscriptRecord]
    let bookmarks: [BookmarkRecord]

    private var visibleTranscripts: [TranscriptDisplayEntry] {
        TranscriptDisplayPolicy.entries(from: transcripts)
    }

    var body: some View {
        if visibleTranscripts.isEmpty {
            Label("暂无转录", systemImage: "text.bubble")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleTranscripts) { transcript in
                    let highlighted = isHighlighted(transcript)
                    let speakerBadge = TranscriptSpeakerDisplayPolicy.badge(
                        speakerID: transcript.speakerID,
                        source: transcript.source
                    )

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(MeetingDisplayFormat.timecode(transcript.startTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        if let speakerBadge {
                            speakerBadgeView(speakerBadge)
                        }
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
                        "\(MeetingDisplayFormat.timecode(transcript.startTime))\(speakerBadge.map { "，\($0.label)" } ?? "")，\(transcript.text)\(highlighted ? "，书签附近" : "")"
                    )
                }
            }
        }
    }

    private func isHighlighted(_ transcript: TranscriptDisplayEntry) -> Bool {
        bookmarks.contains {
            BookmarkWindow(bookmarkTime: $0.timestamp).intersects(
                transcriptStart: transcript.startTime,
                transcriptEnd: transcript.endTime
            )
        }
    }

    private func speakerBadgeView(_ badge: TranscriptSpeakerBadge) -> some View {
        let color = badge.isLocalUser
            ? Color.accentColor
            : speakerPalette[badge.paletteIndex % speakerPalette.count]
        return Text(badge.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var speakerPalette: [Color] {
        [.purple, .teal, .indigo, .pink, .orange, .mint]
    }
}
