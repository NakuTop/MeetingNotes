import AVFoundation
import CryptoKit
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingAudioImportTests: XCTestCase {
    private func fixture(root: URL, duration: Double = 2) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("项目周会.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44_100 * duration)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            channels[0][frame] = Float(sin(Double(frame) * 440 * 2 * .pi / 44_100)) * 0.2
            channels[1][frame] = channels[0][frame]
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    private func makeUseCase(root: URL, enabled: Bool = false,
                             provider: ImportServiceProvider = ImportServiceProvider(),
                             finalizer: ImportFinalizer = ImportFinalizer()) throws
        -> (MeetingAudioImportUseCase, MeetingRepository, MeetingFileStore, ImportCoordinator) {
        let repository = try MeetingRepository.inMemory()
        let files = MeetingFileStore(rootURL: root.appendingPathComponent("Recordings"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ImportTests-\(UUID().uuidString)"))
        let settings = AppSettingsStore(defaults: defaults)
        settings.isSpeakerDiarizationEnabled = enabled
        let coordinator = ImportCoordinator()
        let loader = MeetingAudioSourceLoader(fileStore: files)
        return (MeetingAudioImportUseCase(repository: repository, fileStore: files, settings: settings,
            coordinator: coordinator, operationGate: MeetingOperationGate(), serviceProvider: provider,
            reader: MeetingTrackAudioReader(sourceLoader: loader, maximumChunkSampleCount: 8000),
            finalizer: finalizer), repository, files, coordinator)
    }

    func testStereoLongImportPreservesOriginalAndProducesPlayableSegmentsAndTimedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root: root, duration: 31.25)
        let before = SHA256.hash(data: try Data(contentsOf: url))
        let (useCase, repository, files, coordinator) = try makeUseCase(root: root)
        var created: UUID?
        let id = try await useCase.importRecording(from: url, onCreated: { created = $0 }, onProgress: { _ in })
        XCTAssertEqual(created, id)
        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.title, "项目周会")
        XCTAssertEqual(meeting.mode, .offline)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertNil(meeting.lastErrorCode)
        XCTAssertEqual(meeting.activeDuration, 31.25, accuracy: 0.01)
        let source = try await MeetingAudioSourceLoader(fileStore: files).load(meetingID: id, track: .master)
        XCTAssertEqual(source.sampleRate, 48_000)
        XCTAssertEqual(source.channelCount, 1)
        XCTAssertEqual(source.segmentURLs.count, 3)
        XCTAssertEqual(source.duration, 31.25, accuracy: 0.01)
        XCTAssertGreaterThan(meeting.transcripts.count, 1)
        XCTAssertEqual(meeting.transcripts.map(\.endTime).max() ?? 0, 31.25, accuracy: 0.01)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
        let reserved = await coordinator.isReserved
        XCTAssertFalse(reserved)
    }

    func testWAVAndAACVoiceMemoCanBeImported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try fixture(root: root)
        for (extensionName, formatID) in [("wav", kAudioFormatLinearPCM), ("m4a", kAudioFormatMPEG4AAC)] {
            let input = try AVAudioFile(forReading: original)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
            try input.read(into: buffer)
            input.close()
            let source = root.appendingPathComponent("语音备忘录.\(extensionName)")
            let output = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: formatID,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2])
            try output.write(from: buffer)
            output.close()
            let (useCase, repository, files, _) = try makeUseCase(root: root.appendingPathComponent(extensionName))
            let id = try await useCase.importRecording(from: source, onCreated: { _ in }, onProgress: { _ in })
            XCTAssertFalse(try repository.meeting(id: id).transcripts.isEmpty)
            let imported = try await MeetingAudioSourceLoader(fileStore: files).load(meetingID: id, track: .master)
            XCTAssertEqual(imported.duration, 2, accuracy: 0.1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testModelFailureRetainsAudioAndRetryClearsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root: root)
        let provider = ImportServiceProvider()
        await provider.setFail(true)
        let (useCase, repository, files, coordinator) = try makeUseCase(root: root, enabled: true, provider: provider)
        var id: UUID?
        do {
            _ = try await useCase.importRecording(from: url, onCreated: { id = $0 }, onProgress: { _ in })
            XCTFail("Expected unavailable model")
        } catch LocalAudioImportError.processingFailed {}
        let meetingID = try XCTUnwrap(id)
        let failed = try repository.meeting(id: meetingID)
        XCTAssertEqual(failed.state, .ready)
        XCTAssertEqual(failed.lastErrorCode, "audio_import_transcription_failed")
        _ = try await MeetingAudioSourceLoader(fileStore: files).load(meetingID: meetingID, track: .master)
        let reserved = await coordinator.isReserved
        XCTAssertFalse(reserved)
        await provider.setFail(false)
        try await useCase.retryTranscription(meetingID: meetingID, onProgress: { _ in })
        let retried = try repository.meeting(id: meetingID)
        XCTAssertFalse(retried.transcripts.isEmpty)
        XCTAssertNil(retried.lastErrorCode)
        XCTAssertEqual(retried.speakerProcessingState, .completed)
    }

    func testSpeakerAnalysisFailureKeepsTranscriptAndAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root: root)
        let (useCase, repository, _, _) = try makeUseCase(root: root, enabled: true,
            finalizer: ImportFinalizer(degrade: true))
        let id = try await useCase.importRecording(from: url, onCreated: { _ in }, onProgress: { _ in })
        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertFalse(meeting.transcripts.isEmpty)
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(meeting.speakerProcessingErrorCode, "test_diarization_unavailable")
    }

    func testSpeakerResultsAreAppliedToImportedTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root: root)
        let (useCase, repository, _, _) = try makeUseCase(root: root, enabled: true)
        let id = try await useCase.importRecording(from: url, onCreated: { _ in }, onProgress: { _ in })
        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(Set(meeting.transcripts.compactMap(\.speakerID)), ["room-1"])
        XCTAssertEqual(meeting.speakerProcessingState, .completed)
    }

    func testUnreadableSourceLeavesNoMeetingAndReleasesImportReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (useCase, repository, _, coordinator) = try makeUseCase(root: root)
        do {
            _ = try await useCase.importRecording(from: root.appendingPathComponent("missing.wav"), onCreated: { _ in }, onProgress: { _ in })
            XCTFail("Expected bad source")
        } catch {}
        XCTAssertTrue(try repository.meetings().isEmpty)
        let reserved = await coordinator.isReserved
        XCTAssertFalse(reserved)
    }

    func testCancellationAfterAudioIsSavedCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root: root)
        let provider = ImportServiceProvider()
        await provider.setCancel(true)
        let (useCase, repository, files, _) = try makeUseCase(root: root, provider: provider)
        var id: UUID?
        do {
            _ = try await useCase.importRecording(from: url, onCreated: { id = $0 }, onProgress: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let meetingID = try XCTUnwrap(id)
        XCTAssertEqual(try repository.meeting(id: meetingID).state, .ready)
        _ = try await MeetingAudioSourceLoader(fileStore: files).load(meetingID: meetingID, track: .master)
        await provider.setCancel(false)
        try await useCase.retryTranscription(meetingID: meetingID, onProgress: { _ in })
        XCTAssertNil(try repository.meeting(id: meetingID).lastErrorCode)
    }

    func testRecoveryKeepsImportedFailureRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root: root)
        let (useCase, repository, files, _) = try makeUseCase(root: root)
        let id = try await useCase.importRecording(from: url, onCreated: { _ in }, onProgress: { _ in })
        try repository.saveImportedRecordingState(id: id, duration: 2, state: .finalizing, errorCode: "audio_import_processing")
        let recovery = MeetingRecoveryService(repository: repository, fileStore: files, recoveryCutoff: .distantFuture)
        _ = try await recovery.recoverAllInterruptedMeetings()
        XCTAssertEqual(try repository.meeting(id: id).lastErrorCode, "audio_import_interrupted")
        try await useCase.retryTranscription(meetingID: id, onProgress: { _ in })
        XCTAssertNil(try repository.meeting(id: id).lastErrorCode)
    }
}

private actor ImportCoordinator: MeetingAudioImportCoordinating {
    private(set) var isReserved = false
    func beginAudioImport() throws {
        guard !isReserved else { throw MeetingCoordinatorError.operationInProgress }
        isReserved = true
    }
    func endAudioImport() { isReserved = false }
}

private actor ImportServiceProvider: PreferredTranscriptionServiceProviding {
    var fail = false
    var cancel = false
    func setFail(_ value: Bool) { fail = value }
    func setCancel(_ value: Bool) { cancel = value }
    func service() async throws -> any TranscriptionService {
        if cancel { throw CancellationError() }
        if fail { throw LocalAudioImportError.processingFailed }
        return ImportTranscriber()
    }
}

private struct ImportTranscriber: TranscriptionService {
    func prepare() async throws {}
    func transcribe(samples: [Float], startingAt: TimeInterval) async throws -> [TranscriptDraft] {
        [.init(startTime: startingAt, endTime: startingAt + Double(samples.count) / 16_000, text: "导入的会议内容 \(startingAt)")]
    }
}

private struct ImportFinalizer: MeetingSpeakerFinalizing {
    var degrade = false
    func finalize(meetingID: UUID, mode: MeetingMode, diarizationRequested: Bool,
                  provisional: [TranscriptDraft]) async -> SpeakerFinalizationOutcome {
        if degrade { return .degraded(replacement: nil, sourceRevision: nil, errorCode: "test_diarization_unavailable") }
        return .replacement(provisional.map {
            AttributedTranscriptDraft(transcript: $0, speakerID: "room-1", source: .room)
        }, sourceRevision: 1)
    }
}
