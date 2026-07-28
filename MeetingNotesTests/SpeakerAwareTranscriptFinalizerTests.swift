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
        let recordedStarts = await service.recordedStarts()
        XCTAssertEqual(
            recordedStarts,
            [4, 6, 2],
            "Each source chunk must retain its absolute timeline"
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

    func testRequestedOnlineDiarizationAssignsRemoteSpeakersAndKeepsMe()
        async {
        let meetingID = UUID()
        let source = makeSpeakerFinalizationSource(meetingID: meetingID)
        let diarizer = FakeSpeakerDiarizer(
            result: .success([
                SpeakerInterval(
                    rawSpeakerID: "speaker-b",
                    startTime: 1,
                    endTime: 2
                ),
                SpeakerInterval(
                    rawSpeakerID: "speaker-a",
                    startTime: 2,
                    endTime: 3
                ),
            ])
        )
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: FakeMeetingTrackAudioReader(
                chunksByTrack: [
                    .microphone: [
                        MeetingAudioSampleChunk(
                            samples: [1],
                            startingAt: 0
                        ),
                    ],
                    .system: [
                        MeetingAudioSampleChunk(
                            samples: [2],
                            startingAt: 1
                        ),
                    ],
                ]
            ),
            transcriptionService:
                FakeSpeakerFinalizationTranscriptionService(
                    responses: [
                        1: [
                            .init(
                                startTime: 0,
                                endTime: 1,
                                text: "我"
                            ),
                        ],
                        2: [
                            .init(
                                startTime: 1,
                                endTime: 2,
                                text: "远端一"
                            ),
                            .init(
                                startTime: 2,
                                endTime: 3,
                                text: "远端二"
                            ),
                        ],
                    ]
                ),
            sourceLoader: FakeSpeakerAudioSourceLoader(
                sources: [.system: source]
            ),
            diarizer: diarizer
        )

        let outcome = await finalizer.finalize(
            meetingID: meetingID,
            mode: .online,
            diarizationRequested: true,
            provisional: []
        )

        guard case let .replacement(drafts, sourceRevision) = outcome else {
            return XCTFail("Expected diarized replacement")
        }
        XCTAssertEqual(sourceRevision, 1)
        XCTAssertEqual(
            drafts.map(\.speakerID),
            ["me", "remote-1", "remote-2"]
        )
        XCTAssertEqual(
            drafts.map(\.source),
            [.microphone, .system, .system]
        )
        let diarizedSources = await diarizer.recordedSources()
        XCTAssertEqual(diarizedSources, [source])
    }

    func testOnlineModelFailureReturnsCoarseReplacementWithSafeCode()
        async {
        let meetingID = UUID()
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: FakeMeetingTrackAudioReader(
                chunksByTrack: [
                    .microphone: [
                        MeetingAudioSampleChunk(
                            samples: [1],
                            startingAt: 0
                        ),
                    ],
                    .system: [
                        MeetingAudioSampleChunk(
                            samples: [2],
                            startingAt: 1
                        ),
                    ],
                ]
            ),
            transcriptionService:
                FakeSpeakerFinalizationTranscriptionService(
                    responses: [
                        1: [
                            .init(
                                startTime: 0,
                                endTime: 1,
                                text: "我"
                            ),
                        ],
                        2: [
                            .init(
                                startTime: 1,
                                endTime: 2,
                                text: "远端"
                            ),
                        ],
                    ]
                ),
            sourceLoader: FakeSpeakerAudioSourceLoader(
                sources: [
                    .system: makeSpeakerFinalizationSource(
                        meetingID: meetingID
                    ),
                ]
            ),
            diarizer: FakeSpeakerDiarizer(
                result: .failure(
                    SpeakerDiarizationError.modelPreparationFailed
                )
            )
        )

        let outcome = await finalizer.finalize(
            meetingID: meetingID,
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
        XCTAssertEqual(
            errorCode,
            "speaker_diarization_model_preparation_failed"
        )
    }

    func testRequestedOfflineDiarizationAssignsRoomSpeakers() async {
        let meetingID = UUID()
        let source = makeSpeakerFinalizationSource(meetingID: meetingID)
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: FakeMeetingTrackAudioReader(chunksByTrack: [:]),
            transcriptionService:
                FakeSpeakerFinalizationTranscriptionService(responses: [:]),
            sourceLoader: FakeSpeakerAudioSourceLoader(
                sources: [.master: source]
            ),
            diarizer: FakeSpeakerDiarizer(
                result: .success([
                    SpeakerInterval(
                        rawSpeakerID: "first",
                        startTime: 0,
                        endTime: 1
                    ),
                    SpeakerInterval(
                        rawSpeakerID: "second",
                        startTime: 1,
                        endTime: 2
                    ),
                ])
            )
        )
        let provisional = [
            TranscriptDraft(startTime: 0, endTime: 1, text: "第一位"),
            TranscriptDraft(startTime: 1, endTime: 2, text: "第二位"),
        ]

        let outcome = await finalizer.finalize(
            meetingID: meetingID,
            mode: .offline,
            diarizationRequested: true,
            provisional: provisional
        )

        guard case let .replacement(drafts, sourceRevision) = outcome else {
            return XCTFail("Expected offline diarized replacement")
        }
        XCTAssertEqual(sourceRevision, 1)
        XCTAssertEqual(drafts.map(\.speakerID), ["room-1", "room-2"])
        XCTAssertEqual(drafts.map(\.source), [.room, .room])
    }

    func testOfflineInferenceFailureKeepsProvisionalWithSafeCode() async {
        let meetingID = UUID()
        let finalizer = SpeakerAwareTranscriptFinalizer(
            reader: FakeMeetingTrackAudioReader(chunksByTrack: [:]),
            transcriptionService:
                FakeSpeakerFinalizationTranscriptionService(responses: [:]),
            sourceLoader: FakeSpeakerAudioSourceLoader(
                sources: [
                    .master: makeSpeakerFinalizationSource(
                        meetingID: meetingID
                    ),
                ]
            ),
            diarizer: FakeSpeakerDiarizer(
                result: .failure(
                    SpeakerDiarizationError.inferenceFailed
                )
            )
        )

        let outcome = await finalizer.finalize(
            meetingID: meetingID,
            mode: .offline,
            diarizationRequested: true,
            provisional: [
                TranscriptDraft(
                    startTime: 0,
                    endTime: 1,
                    text: "保留内容"
                ),
            ]
        )

        XCTAssertEqual(
            outcome,
            .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: "speaker_diarization_inference_failed"
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
    private var starts: [TimeInterval] = []

    init(responses: [Float: [TranscriptDraft]]) {
        self.responses = responses
    }

    func prepare() async throws {}

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        guard let marker = samples.first,
              let response = responses[marker] else {
            throw SpeakerFinalizerTestError.transcribe
        }
        markers.append(marker)
        starts.append(startingAt)
        return response
    }

    func recordedMarkers() -> [Float] {
        markers
    }

    func recordedStarts() -> [TimeInterval] {
        starts
    }
}

private struct FakeSpeakerAudioSourceLoader:
    MeetingTrackAudioSourceLoading {
    let sources: [AudioTrack: MeetingAudioSource]

    func load(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSource {
        _ = meetingID
        guard let source = sources[track] else {
            throw SpeakerFinalizerTestError.read
        }
        return source
    }

    func confirmSegmentIdentity(
        in source: MeetingAudioSource,
        segmentIndex: Int
    ) async throws {
        _ = source
        _ = segmentIndex
    }
}

private actor FakeSpeakerDiarizer: SpeakerDiarizing {
    private let result: Result<[SpeakerInterval], Error>
    private var sources: [MeetingAudioSource] = []

    init(result: Result<[SpeakerInterval], Error>) {
        self.result = result
    }

    func diarize(
        source: MeetingAudioSource
    ) async throws -> [SpeakerInterval] {
        sources.append(source)
        return try result.get()
    }

    func recordedSources() -> [MeetingAudioSource] {
        sources
    }
}

private func makeSpeakerFinalizationSource(
    meetingID: UUID
) -> MeetingAudioSource {
    MeetingAudioSource(
        meetingID: meetingID,
        resolvedSegments: [],
        segmentFrameCounts: [],
        sampleRate: AudioSegmentManifest.transcriptionSampleRate,
        channelCount: AudioSegmentManifest.transcriptionChannelCount,
        totalFrames: 0,
        manifestSignature: "manifest",
        identitySignature: "identity"
    )
}
