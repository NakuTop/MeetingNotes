import XCTest
@testable import MeetingNotes

final class SpeakerAwareTranscriptFinalizerTests: XCTestCase {
    func testOnlineFinalizationMergesAttributedTracksChronologically()
        async throws {
        let reader = FakeMeetingTrackAudioReader(
            chunksByTrack: [
                .microphone: [
                    MeetingAudioSampleChunk(samples: [1], startingAt: 4),
                    MeetingAudioSampleChunk(samples: [2], startingAt: 6),
                ],
                .system: [
                    MeetingAudioSampleChunk(samples: [3], startingAt: 2),
                ],
            ]
        )
        let service = FakeSpeakerFinalizationTranscriptionService(
            responses: [
                1: [.init(startTime: 4, endTime: 8, text: "我先说")],
                2: [.init(startTime: 6, endTime: 10, text: "我补充")],
                3: [.init(startTime: 2, endTime: 9, text: "远端开始")],
            ]
        )
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: reader,
            transcriptionService: service
        )

        let outcome = await finalizer.finalize(
            meetingID: UUID(),
            mode: .online,
            diarizationRequested: false,
            provisional: []
        )

        guard case let .replacement(drafts, sourceRevision) = outcome else {
            return XCTFail("Expected complete replacement")
        }
        XCTAssertEqual(sourceRevision, 1)
        XCTAssertEqual(
            drafts.map(\.transcript.text),
            ["远端开始", "我先说", "我补充"]
        )
        XCTAssertEqual(drafts.map(\.speakerID), ["remote", "me", "me"])
        XCTAssertEqual(
            drafts.map(\.source),
            [.system, .microphone, .microphone]
        )
        let recordedMarkers = await service.recordedMarkers()
        XCTAssertEqual(
            recordedMarkers,
            [1, 2, 3],
            "The shared service must finish microphone before system"
        )
    }

    func testOnlineFinalizationPreservesSimultaneousEntriesFromBothTracks()
        async {
        let reader = FakeMeetingTrackAudioReader(
            chunksByTrack: [
                .microphone: [
                    MeetingAudioSampleChunk(samples: [1], startingAt: 3),
                ],
                .system: [
                    MeetingAudioSampleChunk(samples: [2], startingAt: 3),
                ],
            ]
        )
        let service = FakeSpeakerFinalizationTranscriptionService(
            responses: [
                1: [.init(startTime: 3, endTime: 5, text: "同时说话")],
                2: [.init(startTime: 3, endTime: 6, text: "同时说话")],
            ]
        )
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: reader,
            transcriptionService: service
        )

        let outcome = await finalizer.finalize(
            meetingID: UUID(),
            mode: .online,
            diarizationRequested: false,
            provisional: []
        )

        guard case let .replacement(drafts, _) = outcome else {
            return XCTFail("Expected complete replacement")
        }
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.speakerID), ["me", "remote"])
        XCTAssertEqual(drafts.map(\.source), [.microphone, .system])
    }

    func testFailureOnEitherOnlineTrackKeepsProvisionalWithoutReplacement()
        async {
        for failedTrack in [AudioTrack.microphone, .system] {
            let reader = FakeMeetingTrackAudioReader(
                chunksByTrack: [
                    .microphone: [
                        MeetingAudioSampleChunk(samples: [1], startingAt: 0),
                    ],
                    .system: [
                        MeetingAudioSampleChunk(samples: [2], startingAt: 0),
                    ],
                ],
                failedTrack: failedTrack
            )
            let finalizer = SpeakerAwareTranscriptFinalizer(
                reader: reader,
                transcriptionService:
                    FakeSpeakerFinalizationTranscriptionService(
                        responses: [
                            1: [.init(startTime: 0, endTime: 1, text: "本地")],
                            2: [.init(startTime: 0, endTime: 1, text: "远端")],
                        ]
                    )
            )
            let provisional = [
                TranscriptDraft(startTime: 0, endTime: 1, text: "混合转录"),
            ]

            let outcome = await finalizer.finalize(
                meetingID: UUID(),
                mode: .online,
                diarizationRequested: false,
                provisional: provisional
            )

            XCTAssertEqual(
                outcome,
                .degraded(
                    replacement: nil,
                    sourceRevision: nil,
                    errorCode:
                        "source_track_transcription_failed_\(failedTrack.rawValue)"
                )
            )
        }
    }

    func testRequestedDiarizationReturnsCoarseReplacementWithSafeDegradation()
        async {
        let reader = FakeMeetingTrackAudioReader(
            chunksByTrack: [
                .microphone: [
                    MeetingAudioSampleChunk(samples: [1], startingAt: 0),
                ],
                .system: [
                    MeetingAudioSampleChunk(samples: [2], startingAt: 1),
                ],
            ]
        )
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: reader,
            transcriptionService: FakeSpeakerFinalizationTranscriptionService(
                responses: [
                    1: [.init(startTime: 0, endTime: 1, text: "本地")],
                    2: [.init(startTime: 1, endTime: 2, text: "远端")],
                ]
            )
        )

        let outcome = await finalizer.finalize(
            meetingID: UUID(),
            mode: .online,
            diarizationRequested: true,
            provisional: []
        )

        guard case let .degraded(
            replacement?,
            sourceRevision?,
            errorCode
        ) = outcome else {
            return XCTFail("Expected degraded coarse replacement")
        }
        XCTAssertEqual(replacement.map(\.speakerID), ["me", "remote"])
        XCTAssertEqual(sourceRevision, 1)
        XCTAssertEqual(errorCode, "speaker_diarization_unavailable")
    }

    func testOfflinePolicyLeavesProvisionalUnchanged() async {
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: FakeMeetingTrackAudioReader(chunksByTrack: [:]),
            transcriptionService:
                FakeSpeakerFinalizationTranscriptionService(responses: [:])
        )
        let provisional = [
            TranscriptDraft(startTime: 0, endTime: 1, text: "会议内容"),
        ]

        let disabled = await finalizer.finalize(
            meetingID: UUID(),
            mode: .offline,
            diarizationRequested: false,
            provisional: provisional
        )
        let requested = await finalizer.finalize(
            meetingID: UUID(),
            mode: .offline,
            diarizationRequested: true,
            provisional: provisional
        )

        XCTAssertEqual(disabled, .unchanged)
        XCTAssertEqual(
            requested,
            .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: "speaker_diarization_unavailable"
            )
        )
    }
}

private enum SpeakerFinalizerTestError: Error {
    case read
    case transcribe
}

private struct FakeMeetingTrackAudioReader: MeetingTrackAudioReading {
    let chunksByTrack: [AudioTrack: [MeetingAudioSampleChunk]]
    var failedTrack: AudioTrack?

    init(
        chunksByTrack: [AudioTrack: [MeetingAudioSampleChunk]],
        failedTrack: AudioTrack? = nil
    ) {
        self.chunksByTrack = chunksByTrack
        self.failedTrack = failedTrack
    }

    func chunks(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSampleChunks {
        _ = meetingID
        if track == failedTrack {
            throw SpeakerFinalizerTestError.read
        }
        return MeetingAudioSampleChunks(chunksByTrack[track] ?? [])
    }
}

private actor FakeSpeakerFinalizationTranscriptionService:
    TranscriptionService {
    private let responses: [Float: [TranscriptDraft]]
    private var markers: [Float] = []

    init(responses: [Float: [TranscriptDraft]]) {
        self.responses = responses
    }

    func prepare() async throws {}

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        _ = startingAt
        guard let marker = samples.first,
              let response = responses[marker] else {
            throw SpeakerFinalizerTestError.transcribe
        }
        markers.append(marker)
        return response
    }

    func recordedMarkers() -> [Float] {
        markers
    }
}
