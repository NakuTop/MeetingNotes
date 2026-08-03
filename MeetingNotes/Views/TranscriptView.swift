import SwiftUI

struct TranscriptDisplayEntry: Identifiable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerID: String?
    let source: TranscriptAudioSource
}

struct TranscriptDisplayTurn: Identifiable, Equatable {
    let transcriptIDs: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerID: String?
    let source: TranscriptAudioSource
    let isHighlighted: Bool

    var id: UUID {
        transcriptIDs[0]
    }
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
        source: TranscriptAudioSource,
        customNames: [String: String] = [:]
    ) -> TranscriptSpeakerBadge? {
        guard let label = TranscriptSpeakerLabelPolicy.label(
            speakerID: speakerID,
            source: source,
            customNames: customNames
        ) else { return nil }
        return TranscriptSpeakerBadge(
            label: label,
            paletteIndex: paletteIndex(speakerID: speakerID),
            isLocalUser: source == .microphone
        )
    }

    private static func paletteIndex(speakerID: String?) -> Int {
        guard let numberText = speakerID?.split(separator: "-").last,
              let number = Int(numberText),
              number > 0 else { return 0 }
        return (number - 1) % paletteCount
    }
}

enum TranscriptDisplayPolicy {
    private static let maximumTurnGap: TimeInterval = 5

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

    static func turns(
        from transcripts: [TranscriptRecord],
        bookmarks: [BookmarkRecord]
    ) -> [TranscriptDisplayTurn] {
        entries(from: transcripts).reduce(into: []) { turns, entry in
            let highlighted = isHighlighted(entry, bookmarks: bookmarks)
            if let previous = turns.last,
               shouldGroup(
                previous,
                with: entry,
                highlighted: highlighted
               ) {
                turns[turns.count - 1] = TranscriptDisplayTurn(
                    transcriptIDs: previous.transcriptIDs + [entry.id],
                    startTime: previous.startTime,
                    endTime: max(previous.endTime, entry.endTime),
                    text: [previous.text, entry.text].joined(separator: " "),
                    speakerID: previous.speakerID,
                    source: previous.source,
                    isHighlighted: previous.isHighlighted
                )
            } else {
                turns.append(
                    TranscriptDisplayTurn(
                        transcriptIDs: [entry.id],
                        startTime: entry.startTime,
                        endTime: entry.endTime,
                        text: entry.text,
                        speakerID: entry.speakerID,
                        source: entry.source,
                        isHighlighted: highlighted
                    )
                )
            }
        }
    }

    private static func shouldGroup(
        _ turn: TranscriptDisplayTurn,
        with entry: TranscriptDisplayEntry,
        highlighted: Bool
    ) -> Bool {
        guard let speakerID = turn.speakerID,
              speakerID == entry.speakerID else {
            return false
        }
        return turn.source == entry.source
            && entry.startTime <= turn.endTime + maximumTurnGap
            && turn.isHighlighted == highlighted
    }

    private static func isHighlighted(
        _ entry: TranscriptDisplayEntry,
        bookmarks: [BookmarkRecord]
    ) -> Bool {
        bookmarks.contains {
            BookmarkWindow(bookmarkTime: $0.timestamp).intersects(
                transcriptStart: entry.startTime,
                transcriptEnd: entry.endTime
            )
        }
    }
}

struct TranscriptView: View {
    let transcripts: [TranscriptRecord]
    let bookmarks: [BookmarkRecord]
    var customSpeakerNames: [String: String] = [:]
    var frequentSpeakerNames: [String] = []
    var speakerNameErrorMessage: String?
    var onBeginSpeakerEditing: (() -> Void)?
    var onRenameSpeaker: ((String, String) -> Bool)?
    var onClearSpeakerName: ((String) -> Bool)?

    @State private var editingSpeaker: TranscriptSpeakerEditingTarget?

    private var visibleTurns: [TranscriptDisplayTurn] {
        TranscriptDisplayPolicy.turns(
            from: transcripts,
            bookmarks: bookmarks
        )
    }

    private var speakerOptions: [TranscriptSpeakerOption] {
        var seen: Set<String> = []
        return visibleTurns.compactMap { turn in
            guard let speakerID = turn.speakerID,
                  seen.insert(speakerID).inserted,
                  let badge = TranscriptSpeakerDisplayPolicy.badge(
                    speakerID: speakerID,
                    source: turn.source,
                    customNames: customSpeakerNames
                  ) else {
                return nil
            }
            return TranscriptSpeakerOption(
                speakerID: speakerID,
                badge: badge
            )
        }
    }

    var body: some View {
        if visibleTurns.isEmpty {
            Label("暂无转录", systemImage: "text.bubble")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !speakerOptions.isEmpty {
                    speakerSelector
                        .padding(.bottom, 4)
                }

                ForEach(visibleTurns) { turn in
                    let speakerBadge = TranscriptSpeakerDisplayPolicy.badge(
                        speakerID: turn.speakerID,
                        source: turn.source,
                        customNames: customSpeakerNames
                    )

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(MeetingDisplayFormat.timecode(turn.startTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        if let speakerBadge,
                           let speakerID = turn.speakerID {
                            speakerButton(
                                speakerID: speakerID,
                                badge: speakerBadge,
                                accessibilityIdentifier:
                                    "meeting.transcripts.turnSpeaker.\(speakerID)"
                            )
                        }
                        Text(turn.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(9)
                    .background(
                        turn.isHighlighted
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "meeting.transcripts.turn.\(Int((turn.startTime * 1_000).rounded()))"
                    )
                    .accessibilityLabel(
                        "\(MeetingDisplayFormat.timecode(turn.startTime))\(speakerBadge.map { "，\($0.label)" } ?? "")，\(turn.text)\(turn.isHighlighted ? "，书签附近" : "")"
                    )
                }
            }
            .popover(item: $editingSpeaker, arrowEdge: .top) { target in
                SpeakerNameEditor(
                    currentName: target.currentName,
                    frequentNames: frequentSpeakerNames,
                    canRestoreDefault: target.hasCustomName,
                    errorMessage: speakerNameErrorMessage,
                    onSave: { newName in
                        if onRenameSpeaker?(target.speakerID, newName) == true {
                            editingSpeaker = nil
                        }
                    },
                    onRestoreDefault: {
                        if onClearSpeakerName?(target.speakerID) == true {
                            editingSpeaker = nil
                        }
                    },
                    onCancel: {
                        editingSpeaker = nil
                    }
                )
            }
        }
    }

    private var speakerSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("说话人")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(speakerOptions) { option in
                        speakerButton(
                            speakerID: option.speakerID,
                            badge: option.badge,
                            accessibilityIdentifier:
                                "meeting.transcripts.speaker.\(option.speakerID)"
                        )
                    }
                }
            }
        }
    }

    private func speakerButton(
        speakerID: String,
        badge: TranscriptSpeakerBadge,
        accessibilityIdentifier: String
    ) -> some View {
        Button {
            beginEditing(
                speakerID: speakerID,
                badge: badge
            )
        } label: {
            speakerBadgeView(badge)
        }
        .buttonStyle(.plain)
        .disabled(onRenameSpeaker == nil)
        .help("修改“\(badge.label)”的名称")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func beginEditing(
        speakerID: String,
        badge: TranscriptSpeakerBadge
    ) {
        guard onRenameSpeaker != nil else { return }
        onBeginSpeakerEditing?()
        editingSpeaker = TranscriptSpeakerEditingTarget(
            speakerID: speakerID,
            currentName: customSpeakerNames[speakerID] ?? badge.label,
            hasCustomName: customSpeakerNames[speakerID] != nil
        )
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

private struct TranscriptSpeakerOption: Identifiable {
    let speakerID: String
    let badge: TranscriptSpeakerBadge

    var id: String { speakerID }
}

private struct TranscriptSpeakerEditingTarget: Identifiable {
    let speakerID: String
    let currentName: String
    let hasCustomName: Bool

    var id: String { speakerID }
}
