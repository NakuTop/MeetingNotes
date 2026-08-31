import Foundation

struct DetailedMinutesInputLimits: Equatable, Sendable {
    let requestByteLimit: Int
    let aggregateByteLimit: Int

    init(
        requestByteLimit: Int = 96 * 1_024,
        aggregateByteLimit: Int = 256 * 1_024
    ) {
        self.requestByteLimit = max(0, requestByteLimit)
        self.aggregateByteLimit = max(0, aggregateByteLimit)
    }
}

enum DetailedMinutesInputPlan: Equatable, Sendable {
    case direct(String)
    case partials([String])
}

struct DetailedMinutesInputChunker: Equatable, Sendable {
    let byteLimit: Int

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    func plan(for input: MeetingSummaryInput) throws -> DetailedMinutesInputPlan {
        let directMessage = try DetailedMinutesPrompt.userMessage(for: input)
        if fits(directMessage) {
            return .direct(directMessage)
        }

        let emptyPartial = try partialMessage(
            title: input.title,
            transcripts: [],
            userNotes: []
        )
        guard fits(emptyPartial) else {
            throw DeepSeekClientError.inputTooLarge
        }

        var chunks: [[MeetingTranscriptInput]] = []
        var current: [MeetingTranscriptInput] = []

        for transcript in input.transcripts {
            for fragment in try fragments(
                of: transcript,
                title: input.title,
                userNotes: input.userNotes
            ) {
                let candidate = current + [fragment]
                if try fitsPartial(
                    title: input.title,
                    transcripts: candidate,
                    userNotes: notes(
                        from: input.userNotes,
                        intersecting: candidate
                    )
                ) {
                    current = candidate
                } else {
                    if !current.isEmpty {
                        chunks.append(current)
                    }
                    guard try fitsPartial(
                        title: input.title,
                        transcripts: [fragment],
                        userNotes: notes(
                            from: input.userNotes,
                            intersecting: [fragment]
                        )
                    ) else {
                        throw DeepSeekClientError.inputTooLarge
                    }
                    current = [fragment]
                }
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        let partitionedNotes = MeetingUserNoteInputPolicy.partition(
            input.userNotes,
            across: chunks
        )
        let messages = try chunks.enumerated().map { index, chunk in
            try partialMessage(
                title: input.title,
                transcripts: chunk,
                userNotes: partitionedNotes[index]
            )
        }
        guard messages.allSatisfy(fits) else {
            throw DeepSeekClientError.inputTooLarge
        }
        return .partials(messages)
    }

    private func fragments(
        of transcript: MeetingTranscriptInput,
        title: String,
        userNotes: [MeetingUserNoteInput]
    ) throws -> [MeetingTranscriptInput] {
        let associatedNotes = notes(
            from: userNotes,
            intersecting: [transcript]
        )
        if try fitsPartial(
            title: title,
            transcripts: [transcript],
            userNotes: associatedNotes
        ) {
            return [transcript]
        }

        let emptyFragment = replacingText(in: transcript, with: "")
        guard try fitsPartial(
            title: title,
            transcripts: [emptyFragment],
            userNotes: associatedNotes
        ) else {
            throw DeepSeekClientError.inputTooLarge
        }

        let characters = Array(transcript.text)
        guard !characters.isEmpty else {
            throw DeepSeekClientError.inputTooLarge
        }

        var result: [MeetingTranscriptInput] = []
        var start = 0
        while start < characters.count {
            var lower = start + 1
            var upper = characters.count
            var bestEnd: Int?

            while lower <= upper {
                let middle = lower + (upper - lower) / 2
                let text = String(characters[start..<middle])
                let candidate = replacingText(in: transcript, with: text)
                if try fitsPartial(
                    title: title,
                    transcripts: [candidate],
                    userNotes: associatedNotes
                ) {
                    bestEnd = middle
                    lower = middle + 1
                } else {
                    upper = middle - 1
                }
            }

            guard let end = bestEnd else {
                throw DeepSeekClientError.inputTooLarge
            }
            result.append(
                replacingText(
                    in: transcript,
                    with: String(characters[start..<end])
                )
            )
            start = end
        }
        return result
    }

    private func fitsPartial(
        title: String,
        transcripts: [MeetingTranscriptInput],
        userNotes: [MeetingUserNoteInput]
    ) throws -> Bool {
        fits(
            try partialMessage(
                title: title,
                transcripts: transcripts,
                userNotes: userNotes
            )
        )
    }

    private func partialMessage(
        title: String,
        transcripts: [MeetingTranscriptInput],
        userNotes: [MeetingUserNoteInput]
    ) throws -> String {
        try DetailedMinutesPrompt.partialUserMessage(
            for: MeetingSummaryInput(
                title: title,
                transcripts: transcripts,
                bookmarks: [],
                userNotes: userNotes
            )
        )
    }

    private func notes(
        from userNotes: [MeetingUserNoteInput],
        intersecting transcripts: [MeetingTranscriptInput]
    ) -> [MeetingUserNoteInput] {
        MeetingUserNoteInputPolicy.partition(
            userNotes,
            across: [transcripts]
        ).first ?? []
    }

    private func fits(_ message: String) -> Bool {
        message.utf8.count <= byteLimit
    }

    private func replacingText(
        in transcript: MeetingTranscriptInput,
        with text: String
    ) -> MeetingTranscriptInput {
        MeetingTranscriptInput(
            startTime: transcript.startTime,
            endTime: transcript.endTime,
            text: text,
            speakerLabel: transcript.speakerLabel
        )
    }
}
