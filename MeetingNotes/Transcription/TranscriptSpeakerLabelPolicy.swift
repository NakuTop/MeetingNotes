import Foundation

enum TranscriptSpeakerLabelPolicy {
    static func label(
        speakerID: String?,
        source: TranscriptAudioSource,
        customNames: [String: String] = [:]
    ) -> String? {
        guard let speakerID else { return nil }
        if let customName = customNames[speakerID]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !customName.isEmpty {
            return customName
        }

        switch (speakerID, source) {
        case ("me", .microphone):
            return "我"
        case ("remote", .system):
            return "远端"
        case (_, .system):
            return numberedLabel(
                speakerID: speakerID,
                prefix: "remote",
                labelPrefix: "远端"
            )
        case (_, .room):
            return numberedLabel(
                speakerID: speakerID,
                prefix: "room",
                labelPrefix: "说话人"
            )
        case (_, .microphone), (_, .mixed):
            return nil
        }
    }

    private static func numberedLabel(
        speakerID: String,
        prefix: String,
        labelPrefix: String
    ) -> String? {
        let expectedPrefix = "\(prefix)-"
        guard speakerID.hasPrefix(expectedPrefix),
              let number = Int(speakerID.dropFirst(expectedPrefix.count)),
              number > 0 else {
            return nil
        }
        return "\(labelPrefix) \(number)"
    }
}
