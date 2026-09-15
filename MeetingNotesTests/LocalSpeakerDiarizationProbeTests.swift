import Foundation
import XCTest
@testable import MeetingNotes

// Explicit opt-in only. No real meeting paths, identifiers, audio or text are
// checked into the repository; normal test runs skip this local diagnostic.
final class LocalSpeakerDiarizationProbeTests: XCTestCase {
    private struct Input: Decodable {
        let recordingsRoot: URL
        let modelsCopy: URL
        let whisperModel: URL?
        let meetings: [UUID]
    }

    func testLocalSourceTrackRetranscriptionCost() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "MEETINGNOTES_DIARIZATION_PROBE_CONFIG"
        ] else { throw XCTSkip("Local audio probe requires explicit opt-in") }
        let input = try JSONDecoder().decode(
            Input.self, from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        guard let model = input.whisperModel else { throw XCTSkip("No cached model selected") }
        let service = WhisperKitTranscriptionService(
            persistentModelFolder: model, download: false
        )
        let preparationStart = Date()
        try await service.prepare()
        print("LOCAL_RETRANSCRIPTION stage=model_ready elapsed=\(Date().timeIntervalSince(preparationStart))")
        let reader = MeetingTrackAudioReader(sourceLoader: MeetingAudioSourceLoader(
            fileStore: MeetingFileStore(rootURL: input.recordingsRoot)
        ))
        for track in [AudioTrack.microphone, .system] {
            let chunks = try await reader.chunks(meetingID: input.meetings[0], track: track)
            var tested = 0
            for try await chunk in chunks {
                let started = Date()
                print("LOCAL_RETRANSCRIPTION track=\(track.rawValue) chunk=\(tested) stage=started duration=\(Double(chunk.samples.count) / 16000)")
                let drafts = try await service.transcribe(samples: chunk.samples, startingAt: chunk.startingAt)
                print("LOCAL_RETRANSCRIPTION track=\(track.rawValue) chunk=\(tested) stage=completed elapsed=\(Date().timeIntervalSince(started)) drafts=\(drafts.count)")
                tested += 1
                if tested == 3 { break }
            }
        }
    }

    func testLocalRecordedSystemAudioDiarization() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "MEETINGNOTES_DIARIZATION_PROBE_CONFIG"
        ] else { throw XCTSkip("Local audio probe requires explicit opt-in") }
        let input = try JSONDecoder().decode(
            Input.self, from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let loader = MeetingAudioSourceLoader(
            fileStore: MeetingFileStore(rootURL: input.recordingsRoot)
        )
        let diarizer = FluidAudioSpeakerDiarizer(
            modelsDirectory: input.modelsCopy, sourceLoader: loader
        )
        for (index, id) in input.meetings.enumerated() {
            let loadStart = Date()
            let source = try await loader.load(meetingID: id, track: .system)
            print("LOCAL_DIARIZATION case=\(index) stage=source_loaded seconds=\(source.duration) segments=\(source.resolvedSegments.count) elapsed=\(Date().timeIntervalSince(loadStart))")
            let started = Date()
            let intervals = try await diarizer.diarize(source: source)
            let elapsed = Date().timeIntervalSince(started)
            let speakers = Set(intervals.map(\.rawSpeakerID)).count
            print("LOCAL_DIARIZATION case=\(index) stage=completed elapsed=\(elapsed) intervals=\(intervals.count) speakers=\(speakers)")
            XCTAssertFalse(intervals.isEmpty)
        }
    }

    func testLocalLiveSpeakerPreviewOnRealMaster() async throws {
        guard let path = ProcessInfo.processInfo.environment["MEETINGNOTES_DIARIZATION_PROBE_CONFIG"] else {
            throw XCTSkip("Local audio probe requires explicit opt-in")
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let model = input.whisperModel else { throw XCTSkip("No cached model selected") }
        let service = WhisperKitTranscriptionService(persistentModelFolder: model, download: false)
        try await service.prepare()
        let reader = MeetingTrackAudioReader(sourceLoader: MeetingAudioSourceLoader(
            fileStore: MeetingFileStore(rootURL: input.recordingsRoot)))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotes-LiveSpeakerProbe", isDirectory: true)
            .appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        let session = FluidAudioLiveSpeakerSessionFactory(modelsDirectory: directory).makeSession(mode: .online)
        var updates = await session.updates().makeAsyncIterator()
        let chunks = try await reader.chunks(meetingID: input.meetings[1], track: .master)
        var count = 0
        var intervalCount = 0
        var speakerIDs = Set<String>()
        let started = Date()
        for try await chunk in chunks {
            async let transcription = service.transcribe(samples: chunk.samples, startingAt: chunk.startingAt)
            await session.enqueue(samples: chunk.samples, startingAt: chunk.startingAt)
            guard let update = await updates.next() else { return XCTFail("Live engine stopped before preview") }
            _ = try await transcription
            intervalCount += update.intervals.count
            speakerIDs.formUnion(update.intervals.map(\.rawSpeakerID))
            count += 1
            if count == 24 { break }
        }
        await session.cancel()
        XCTAssertGreaterThan(intervalCount, 0)
        print("LOCAL_LIVE_SPEAKERS chunks=\(count) intervals=\(intervalCount) speakers=\(speakerIDs.count) elapsed=\(Date().timeIntervalSince(started))")
    }

    func testLocalFixedFinalizationOnBothRealMasterRecordings() async throws {
        guard let path = ProcessInfo.processInfo.environment["MEETINGNOTES_DIARIZATION_PROBE_CONFIG"] else {
            throw XCTSkip("Local audio probe requires explicit opt-in")
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let model = input.whisperModel else { throw XCTSkip("No cached model selected") }
        let service = WhisperKitTranscriptionService(persistentModelFolder: model, download: false)
        try await service.prepare()
        let loader = MeetingAudioSourceLoader(fileStore: MeetingFileStore(rootURL: input.recordingsRoot))
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: MeetingTrackAudioReader(sourceLoader: loader), sourceLoader: loader,
            diarizer: FluidAudioSpeakerDiarizer(modelsDirectory: input.modelsCopy, sourceLoader: loader))
        for (index, id) in input.meetings.enumerated() {
            let source = try await loader.load(meetingID: id, track: .master)
            // Real audio, synthetic text anchors: no private transcript needs
            // copying into test artifacts to check label-only finalization.
            let drafts = stride(from: 0.0, to: source.duration - 2, by: 2).map {
                TranscriptDraft(startTime: $0, endTime: $0 + 2, text: "preserved")
            }
            let started = Date()
            let result = await finalizer.finalize(meetingID: id, mode: .online, diarizationRequested: true, provisional: drafts,
                transcriptionService: service)
            guard case let .replacement(attributed, _) = result else { return XCTFail("Real master did not finalize") }
            XCTAssertEqual(attributed.map(\.transcript), drafts)
            XCTAssertTrue(attributed.allSatisfy { $0.speakerID != nil && $0.source == .mixed })
            print("LOCAL_FIXED_FINALIZATION case=\(index) stage=completed elapsed=\(Date().timeIntervalSince(started)) labels=\(attributed.count)")
        }
    }
}
