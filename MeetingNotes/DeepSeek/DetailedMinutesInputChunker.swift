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
            transcripts: []
        )
        guard fits(emptyPartial) else {
            throw DeepSeekClientError.inputTooLarge
        }

        var chunks: [[MeetingTranscriptInput]] = []
        var current: [MeetingTranscriptInput] = []

        for transcript in input.transcripts {
            for fragment in try fragments(
                of: transcript,
                title: input.title
            ) {
                let candidate = current + [fragment]
                if try fitsPartial(title: input.title, transcripts: candidate) {
                    current = candidate
                } else {
                    if !current.isEmpty {
                        chunks.append(current)
                    }
                    guard try fitsPartial(
                        title: input.title,
                        transcripts: [fragment]
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

        let messages = try chunks.map {
            try partialMessage(title: input.title, transcripts: $0)
        }
        return .partials(messages)
    }

    private func fragments(
        of transcript: MeetingTranscriptInput,
        title: String
    ) throws -> [MeetingTranscriptInput] {
        if try fitsPartial(title: title, transcripts: [transcript]) {
            return [transcript]
        }

        let emptyFragment = replacingText(in: transcript, with: "")
        guard try fitsPartial(title: title, transcripts: [emptyFragment]) else {
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
                if try fitsPartial(title: title, transcripts: [candidate]) {
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
        transcripts: [MeetingTranscriptInput]
    ) throws -> Bool {
        fits(try partialMessage(title: title, transcripts: transcripts))
    }

    private func partialMessage(
        title: String,
        transcripts: [MeetingTranscriptInput]
    ) throws -> String {
        try DetailedMinutesPrompt.partialUserMessage(
            for: MeetingSummaryInput(
                title: title,
                transcripts: transcripts,
                bookmarks: []
            )
        )
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
