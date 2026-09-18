import Foundation

enum VoiceprintError: Error, Equatable, Sendable {
    case disabled, consentRequired, invalidName, poorAudio, multipleSpeakers
    case invalidEmbedding, incompatibleModel, staleOperation, storageUnavailable, libraryFull, duplicateName
}

struct VoiceprintEmbedding: Sendable {
    // Explicit model/feature-space identity, never compared across SDK models.
    static let currentModelID = "FluidAudio-0.13.2-offline-wespeaker-256"
    let values: [Float]
    var modelID = currentModelID
    let speechSeconds: Double
}

protocol VoiceprintExtracting: Sendable {
    func extractVoiceprint(samples: [Float]) async throws -> VoiceprintEmbedding
}

struct LocalVoiceprintProfile: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let modelID: String
    let embedding: [Float]
    let speechSeconds: Double
    let createdAt: Date
}

struct VoiceprintProfileSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
}

struct VoiceprintSuggestion: Sendable, Equatable {
    let profileID: UUID
    let name: String
    let similarity: Float
    let revision: UUID
}

protocol VoiceprintStoring: Sendable {
    func load() throws -> [LocalVoiceprintProfile]
    func save(_ profiles: [LocalVoiceprintProfile]) throws
}

enum VoiceprintQuality {
    static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == 256, values.allSatisfy(\.isFinite) else { throw VoiceprintError.invalidEmbedding }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0.000001 else { throw VoiceprintError.invalidEmbedding }
        return values.map { Float(Double($0) / norm) }
    }

    static func validate(samples: [Float]) throws {
        guard (80_000...320_000).contains(samples.count), samples.allSatisfy(\.isFinite) else {
            throw VoiceprintError.poorAudio
        }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        let clipped = Double(samples.filter { abs($0) >= 0.999 }.count) / Double(samples.count)
        guard rms >= 0.005, clipped < 0.01 else { throw VoiceprintError.poorAudio }
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

actor LocalVoiceprintLibrary {
    private let store: any VoiceprintStoring
    private let extractor: any VoiceprintExtracting
    private var enabled: Bool
    private var profiles: [LocalVoiceprintProfile]?
    private var revision = UUID()
    private var lastEnablementRequest: UInt64 = 0

    init(store: any VoiceprintStoring, extractor: any VoiceprintExtracting, enabled: Bool = false) {
        self.store = store
        self.extractor = extractor
        self.enabled = enabled
    }

    func setEnabled(_ value: Bool, request: UInt64? = nil) {
        if let request {
            guard request > lastEnablementRequest else { return }
            lastEnablementRequest = request
        }
        enabled = value
        revision = UUID() // invalidate pending work/suggestions even after re-enabling
    }

    func summaries() throws -> [VoiceprintProfileSummary] {
        try loadedProfiles().map { .init(id: $0.id, name: $0.name) }
    }

    func enroll(name: String, samples: [Float], consent: Bool) async throws {
        try Task.checkCancellation()
        guard enabled else { throw VoiceprintError.disabled }
        guard consent else { throw VoiceprintError.consentRequired }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VoiceprintError.invalidName
        }
        try VoiceprintQuality.validate(samples: samples)
        let existing = try loadedProfiles()
        guard existing.count < 64 else { throw VoiceprintError.libraryFull }
        guard !existing.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw VoiceprintError.duplicateName
        }
        let token = revision
        let result = try await extractor.extractVoiceprint(samples: samples)
        try Task.checkCancellation()
        guard enabled, token == revision else { throw VoiceprintError.staleOperation }
        guard result.modelID == VoiceprintEmbedding.currentModelID,
              result.speechSeconds.isFinite, result.speechSeconds >= 4 else {
            throw VoiceprintError.incompatibleModel
        }
        let profile = LocalVoiceprintProfile(id: UUID(), name: name, modelID: result.modelID,
            embedding: try VoiceprintQuality.normalized(result.values),
            speechSeconds: result.speechSeconds, createdAt: .now)
        let updated = try loadedProfiles() + [profile]
        try store.save(updated)
        profiles = updated
        revision = UUID()
    }

    func suggest(samples: [Float]) async throws -> VoiceprintSuggestion? {
        try Task.checkCancellation()
        guard enabled else { throw VoiceprintError.disabled }
        try VoiceprintQuality.validate(samples: samples)
        let candidates = try loadedProfiles().filter { $0.modelID == VoiceprintEmbedding.currentModelID }
        guard !candidates.isEmpty else { return nil }
        let token = revision
        let result = try await extractor.extractVoiceprint(samples: samples)
        try Task.checkCancellation()
        guard enabled, revision == token else { throw VoiceprintError.staleOperation }
        guard result.modelID == VoiceprintEmbedding.currentModelID,
              result.speechSeconds.isFinite, result.speechSeconds >= 4 else {
            throw VoiceprintError.incompatibleModel
        }
        let vector = try VoiceprintQuality.normalized(result.values)
        var ranked: [(profile: LocalVoiceprintProfile, score: Float)] = []
        for profile in candidates {
            let reference = try VoiceprintQuality.normalized(profile.embedding)
            ranked.append((profile, VoiceprintQuality.similarity(vector, reference)))
        }
        ranked.sort {
            if $0.score == $1.score { return $0.profile.id.uuidString < $1.profile.id.uuidString }
            return $0.score > $1.score
        }
        // Conservative, uncalibrated similarity gates. Never a probability,
        // never an automatic identity assignment, even for a near-perfect match.
        guard let best = ranked.first, best.score >= 0.80,
              best.score - (ranked.dropFirst().first?.score ?? -1) >= 0.08 else { return nil }
        return .init(profileID: best.profile.id, name: best.profile.name, similarity: best.score, revision: token)
    }

    func confirmedName(for suggestion: VoiceprintSuggestion) throws -> String {
        guard enabled, suggestion.revision == revision,
              let profile = try loadedProfiles().first(where: { $0.id == suggestion.profileID }),
              profile.name == suggestion.name else { throw VoiceprintError.staleOperation }
        return profile.name
    }

    func delete(id: UUID) throws {
        // Invalidate in-flight enrollment/matching before touching storage.
        revision = UUID()
        let updated = try loadedProfiles().filter { $0.id != id }
        try store.save(updated)
        profiles = updated
    }

    func deleteAll() throws {
        revision = UUID()
        try store.save([])
        profiles = []
    }

    private func loadedProfiles() throws -> [LocalVoiceprintProfile] {
        if let profiles { return profiles }
        let loaded = try store.load()
        guard loaded.count <= 64 else { throw VoiceprintError.storageUnavailable }
        for profile in loaded { _ = try VoiceprintQuality.normalized(profile.embedding) }
        profiles = loaded
        return loaded
    }
}

// Read exactly the selected production timeline, bounded to 20 seconds.
// Missing/gapped input is rejected, not padded into an artificial voice sample.
struct VoiceprintClipReader: Sendable {
    let reader: any MeetingTrackAudioReading
    func samples(meetingID: UUID, start: Double, end: Double) async throws -> [Float] {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 5 else { throw VoiceprintError.poorAudio }
        let stop = min(end, start + 20)
        let expected = Int(((stop - start) * 16_000).rounded())
        var output: [Float] = []
        output.reserveCapacity(expected)
        var cursor = start
        for try await chunk in try await reader.chunks(meetingID: meetingID, track: .master) {
            try Task.checkCancellation()
            guard chunk.startingAt.isFinite, chunk.startingAt >= 0 else { throw VoiceprintError.poorAudio }
            let chunkEnd = chunk.startingAt + Double(chunk.samples.count) / 16_000
            if chunkEnd <= cursor { continue }
            guard chunk.startingAt <= cursor + 1.0 / 16_000 else { throw VoiceprintError.poorAudio }
            let offset = max(0, Int(((cursor - chunk.startingAt) * 16_000).rounded()))
            let count = min(expected - output.count, chunk.samples.count - offset)
            guard offset <= chunk.samples.count, count > 0 else { throw VoiceprintError.poorAudio }
            output.append(contentsOf: chunk.samples[offset..<(offset + count)])
            cursor = start + Double(output.count) / 16_000
            if output.count == expected { break }
        }
        guard output.count == expected else { throw VoiceprintError.poorAudio }
        try VoiceprintQuality.validate(samples: output)
        return output
    }
}
