import QuickLook
import SwiftUI

struct TranscriptDisplayEntry: Identifiable, Equatable {
    let id: UUID
    let correctionID: UUID?
    let transcriptIDs: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerID: String?
    let source: TranscriptAudioSource
}

struct TranscriptDisplayTurn: Identifiable, Equatable {
    let canonicalEntryID: UUID
    let correctionID: UUID?
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

@MainActor
enum TranscriptDisplayPolicy {
    private static let maximumTurnGap: TimeInterval = 5

    static func entries(
        from transcripts: [TranscriptRecord]
    ) -> [TranscriptDisplayEntry] {
        entries(
            from: TranscriptCorrectionResolver.resolve(
                transcripts: transcripts,
                corrections: []
            )
        )
    }

    static func entries(
        from transcripts: [CanonicalTranscriptEntry]
    ) -> [TranscriptDisplayEntry] {
        transcripts
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }
            .compactMap { transcript in
                let text = TranscriptTextSanitizer.nonEmpty(transcript.text)
                // An emptied manual edit must retain its native editor and
                // undo target after autosave. Empty generated rows stay hidden.
                guard text != nil || transcript.isManuallyEdited else {
                    return nil
                }
                return TranscriptDisplayEntry(
                    id: transcript.id,
                    correctionID: transcript.isManuallyEdited
                        ? transcript.id
                        : nil,
                    transcriptIDs: transcript.transcriptIDs.isEmpty
                        ? [transcript.id]
                        : transcript.transcriptIDs,
                    startTime: transcript.startTime,
                    endTime: transcript.endTime,
                    text: text ?? "",
                    speakerID: transcript.speakerID,
                    source: transcript.source
                )
            }
    }

    static func turns(
        from transcripts: [TranscriptRecord],
        bookmarks: [BookmarkRecord]
    ) -> [TranscriptDisplayTurn] {
        turns(
            from: TranscriptCorrectionResolver.resolve(
                transcripts: transcripts,
                corrections: []
            ),
            bookmarks: bookmarks
        )
    }

    static func turns(
        from transcripts: [CanonicalTranscriptEntry],
        bookmarks: [BookmarkRecord],
        preservingDraftTargets: [MeetingTranscriptEditTarget] = []
    ) -> [TranscriptDisplayTurn] {
        appending(
            transcripts,
            to: [],
            bookmarks: bookmarks,
            preservingDraftTargets: preservingDraftTargets
        )
    }

    /// The caller verifies that earlier entries and grouping inputs are
    /// unchanged, so only the existing last turn can absorb an appended entry.
    static func appending(
        _ transcripts: [CanonicalTranscriptEntry],
        to existingTurns: [TranscriptDisplayTurn],
        bookmarks: [BookmarkRecord],
        preservingDraftTargets: [MeetingTranscriptEditTarget] = []
    ) -> [TranscriptDisplayTurn] {
        let appendedEntries = entries(from: transcripts)
        guard !appendedEntries.isEmpty else { return existingTurns }
        let draftScopes = preservingDraftTargets.map {
            Set($0.transcriptIDs)
        }
        var turns = existingTurns
        var current = turns.popLast().map {
            TurnAccumulator(
                turn: $0,
                draftMembership: draftMembership(
                    transcriptIDs: $0.transcriptIDs,
                    scopes: draftScopes
                )
            )
        }

        for entry in appendedEntries {
            let highlighted = isHighlighted(entry, bookmarks: bookmarks)
            let membership = draftMembership(
                transcriptIDs: entry.transcriptIDs,
                scopes: draftScopes
            )
            if current?.canAppend(
                entry,
                highlighted: highlighted,
                draftMembership: membership
            ) == true {
                current?.append(entry)
            } else {
                if let current {
                    turns.append(current.turn)
                }
                current = TurnAccumulator(
                    entry: entry,
                    highlighted: highlighted,
                    draftMembership: membership
                )
            }
        }

        if let current {
            turns.append(current.turn)
        }
        return turns
    }

    @MainActor
    private struct TurnAccumulator {
        let canonicalEntryID: UUID
        let correctionID: UUID?
        var transcriptIDs: [UUID]
        let startTime: TimeInterval
        var endTime: TimeInterval
        var textParts: [String]
        let speakerID: String?
        let source: TranscriptAudioSource
        let isHighlighted: Bool
        let draftMembership: [Bool]

        init(
            entry: TranscriptDisplayEntry,
            highlighted: Bool,
            draftMembership: [Bool]
        ) {
            canonicalEntryID = entry.id
            correctionID = entry.correctionID
            transcriptIDs = entry.transcriptIDs
            startTime = entry.startTime
            endTime = entry.endTime
            textParts = [entry.text]
            speakerID = entry.speakerID
            source = entry.source
            isHighlighted = highlighted
            self.draftMembership = draftMembership
        }

        init(turn: TranscriptDisplayTurn, draftMembership: [Bool]) {
            canonicalEntryID = turn.canonicalEntryID
            correctionID = turn.correctionID
            transcriptIDs = turn.transcriptIDs
            startTime = turn.startTime
            endTime = turn.endTime
            textParts = [turn.text]
            speakerID = turn.speakerID
            source = turn.source
            isHighlighted = turn.isHighlighted
            self.draftMembership = draftMembership
        }

        func canAppend(
            _ entry: TranscriptDisplayEntry,
            highlighted: Bool,
            draftMembership: [Bool]
        ) -> Bool {
            guard let speakerID,
                  speakerID == entry.speakerID,
                  correctionID == nil,
                  entry.correctionID == nil else {
                return false
            }
            let maximumGap = maximumTurnGap
            return source == entry.source
                && entry.startTime <= endTime + maximumGap
                && isHighlighted == highlighted
                && self.draftMembership == draftMembership
        }

        mutating func append(_ entry: TranscriptDisplayEntry) {
            transcriptIDs.append(contentsOf: entry.transcriptIDs)
            endTime = max(endTime, entry.endTime)
            textParts.append(entry.text)
        }

        var turn: TranscriptDisplayTurn {
            TranscriptDisplayTurn(
                canonicalEntryID: canonicalEntryID,
                correctionID: correctionID,
                transcriptIDs: transcriptIDs,
                startTime: startTime,
                endTime: endTime,
                text: textParts.joined(separator: " "),
                speakerID: speakerID,
                source: source,
                isHighlighted: isHighlighted
            )
        }
    }

    private static func draftMembership(
        transcriptIDs: [UUID],
        scopes: [Set<UUID>]
    ) -> [Bool] {
        scopes.map { scope in
            transcriptIDs.contains(where: scope.contains)
        }
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
    let projection: MeetingTimelineProjectionSnapshot
    var customSpeakerNames: [String: String] = [:]
    var frequentSpeakerNames: [String] = []
    var speakerNameErrorMessage: String?
    var onBeginSpeakerEditing: (() -> Void)?
    var onRenameSpeaker: ((String, String) -> Bool)?
    var onClearSpeakerName: ((String) -> Bool)?
    var onChangeTranscript: ((String, MeetingTranscriptEditTarget) -> Void)?
    var onFlushEdits: (() -> Void)?
    var onRequestExactReplacement: ((String) -> Void)?
    var transcriptText: (MeetingTranscriptEditTarget) -> String = {
        $0.originalText
    }
    var noteText: (MeetingNoteDisplayItem) -> String = { $0.text }
    var onChangeNote: ((String, MeetingNoteDisplayItem) -> Void)?
    var onDeleteNote: ((MeetingNoteDisplayItem) -> Void)?
    var onResolveScreenshot:
        ((MeetingScreenshotDisplayItem) async -> URL?)?
    var onDeleteScreenshot: ((MeetingScreenshotDisplayItem) -> Void)?

    @State private var editingSpeaker: TranscriptSpeakerEditingTarget?
    @State private var previewURL: URL?

    private var timelineItems: [MeetingTimelineDisplayItem] {
        projection.timelineItems
    }

    private var speakerOptions: [TranscriptSpeakerOption] {
        projection.speakerOptions
    }

    var body: some View {
        Group {
            if timelineItems.isEmpty {
                Label("暂无转录、笔记或截图", systemImage: "text.bubble")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !speakerOptions.isEmpty {
                        speakerSelector
                            .padding(.bottom, 4)
                    }

                    ForEach(timelineItems) { item in
                        switch item {
                        case let .transcript(turn):
                            transcriptRow(turn)
                        case let .note(note):
                            MeetingNoteTimelineEventView(
                                item: note,
                                text: Binding(
                                    get: { noteText(note) },
                                    set: { value in
                                        onChangeNote?(value, note)
                                    }
                                ),
                                onFlush: onFlushEdits,
                                onRequestExactReplacement:
                                    onRequestExactReplacement,
                                onDelete: onDeleteNote.map { action in
                                    { action(note) }
                                }
                            )
                        case let .screenshot(screenshot):
                            MeetingScreenshotTimelineEventView(
                                item: screenshot,
                                resolveURL: {
                                    guard let onResolveScreenshot else {
                                        return nil
                                    }
                                    return await onResolveScreenshot(screenshot)
                                },
                                onOpen: { previewURL = $0 },
                                onDelete: onDeleteScreenshot.map { action in
                                    { action(screenshot) }
                                }
                            )
                        }
                    }
                }
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
        .quickLookPreview($previewURL)
    }

    private func transcriptRow(_ turn: TranscriptDisplayTurn) -> some View {
        let speakerBadge = TranscriptSpeakerDisplayPolicy.badge(
            speakerID: turn.speakerID,
            source: turn.source,
            customNames: customSpeakerNames
        )
        let editTarget = MeetingTranscriptEditTarget(turn: turn)
        let displayedText = transcriptText(editTarget)

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
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
            InlineEditableMeetingText(
                text: Binding(
                    get: { transcriptText(editTarget) },
                    set: { value in
                        onChangeTranscript?(value, editTarget)
                    }
                ),
                accessibilityIdentifier:
                    "meeting.transcripts.text.\(Int((turn.startTime * 1_000).rounded()))",
                onFlush: {
                    onFlushEdits?()
                },
                onRequestExactReplacement: onRequestExactReplacement
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(
            turn.isHighlighted
                ? Color.accentColor.opacity(0.14)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "meeting.transcripts.turn.\(Int((turn.startTime * 1_000).rounded()))"
        )
        .accessibilityLabel(
            "\(MeetingDisplayFormat.timecode(turn.startTime))\(speakerBadge.map { "，\($0.label)" } ?? "")，\(displayedText)\(turn.isHighlighted ? "，书签附近" : "")"
        )
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

private struct TranscriptSpeakerEditingTarget: Identifiable {
    let speakerID: String
    let currentName: String
    let hasCustomName: Bool

    var id: String { speakerID }
}
