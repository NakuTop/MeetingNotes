import Foundation
import os
import XCTest
@testable import MeetingNotes

final class VoiceprintTestStore: VoiceprintStoring, Sendable {
    struct State { var profiles: [LocalVoiceprintProfile] = []; var failSave = false; var saves = 0 }
    let state = OSAllocatedUnfairLock(initialState: State())
    func load() -> [LocalVoiceprintProfile] { state.withLock { $0.profiles } }
    func save(_ profiles: [LocalVoiceprintProfile]) throws {
        try state.withLock {
            if $0.failSave { throw VoiceprintError.storageUnavailable }
            $0.profiles = profiles
            $0.saves += 1
        }
    }
}

struct VoiceprintTestExtractor: VoiceprintExtracting {
    var vector = [Float](repeating: 1, count: 256)
    var modelID = VoiceprintEmbedding.currentModelID
    func extractVoiceprint(samples: [Float]) -> VoiceprintEmbedding {
        .init(values: vector, modelID: modelID, speechSeconds: 5)
    }
}

actor VoiceprintBlockedExtractor: VoiceprintExtracting {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<VoiceprintEmbedding, Never>?
    func extractVoiceprint(samples: [Float]) async -> VoiceprintEmbedding {
        await withCheckedContinuation {
            result = $0
            entered = true
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        result?.resume(returning: .init(values: [Float](repeating: 1, count: 256), speechSeconds: 5))
        result = nil
    }
}

actor VoiceprintTestReader: MeetingTrackAudioReading {
    let values: [MeetingAudioSampleChunk]
    private(set) var calls: [(UUID, AudioTrack)] = []
    init(_ values: [MeetingAudioSampleChunk]) { self.values = values }
    func chunks(meetingID: UUID, track: AudioTrack) -> MeetingAudioSampleChunks {
        calls.append((meetingID, track))
        return .init(values)
    }
}

@MainActor
final class LocalVoiceprintLibraryTests: XCTestCase {
    private var pcm: [Float] { [Float](repeating: 0.1, count: 80_000) }

    func testDefaultOffAndExplicitConsentAreRequired() async throws {
        let store = VoiceprintTestStore()
        let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor())
        do { try await library.enroll(name: "同意录入的人", samples: pcm, consent: true); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceprintError, .disabled) }
        await library.setEnabled(true)
        do { try await library.enroll(name: "未同意", samples: pcm, consent: false); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceprintError, .consentRequired) }
        XCTAssertTrue(store.load().isEmpty)
    }

    func testEnrollmentAndSuggestionNeverApplyIdentityWithoutConfirmation() async throws {
        let store = VoiceprintTestStore()
        let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "  本地示例姓名  ", samples: pcm, consent: true)
        let profiles = try await library.summaries()
        XCTAssertEqual(profiles.map(\.name), ["本地示例姓名"])
        let suggestion = try await library.suggest(samples: pcm)
        let value = try XCTUnwrap(suggestion)
        XCTAssertEqual(value.name, "本地示例姓名")
        XCTAssertEqual(store.state.withLock { $0.saves }, 1, "Matching is read-only")
        let confirmed = try await library.confirmedName(for: value)
        XCTAssertEqual(confirmed, value.name)
        XCTAssertEqual(store.state.withLock { $0.saves }, 1)
    }

    func testAmbiguousMatchingIsRejected() async throws {
        let store = VoiceprintTestStore()
        let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "甲", samples: pcm, consent: true)
        try await library.enroll(name: "乙", samples: pcm, consent: true)
        let suggestion = try await library.suggest(samples: pcm)
        XCTAssertNil(suggestion, "Identical vectors with two identities must not choose either")
    }

    func testWeakMatchAndIncompatibleStoredModelNeverSuggestAName() async throws {
        for compatible in [true, false] {
            let store = VoiceprintTestStore()
            store.state.withLock {
                $0.profiles = [.init(id: UUID(), name: "旧声纹",
                    modelID: compatible ? VoiceprintEmbedding.currentModelID : "different-feature-space",
                    embedding: [Float](repeating: -1, count: 256), speechSeconds: 5, createdAt: .now)]
            }
            let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor(), enabled: true)
            let suggestion = try await library.suggest(samples: pcm)
            XCTAssertNil(suggestion)
            XCTAssertEqual(store.load().count, 1, "Unknown models are preserved, not compared or deleted")
        }
    }

    func testInvalidAudioAndEmbeddingsFailClosed() async throws {
        for samples in [[Float](repeating: 0, count: 80_000), [Float](repeating: 0.1, count: 79_999),
                        [Float](repeating: 1, count: 80_000), [Float](repeating: .nan, count: 80_000),
                        [Float](repeating: .infinity, count: 80_000), [Float](repeating: 0.1, count: 320_001)] {
            XCTAssertThrowsError(try VoiceprintQuality.validate(samples: samples))
        }
        for vector in [[], [Float](repeating: 0, count: 256), [Float](repeating: 1, count: 255),
                       [Float](repeating: .infinity, count: 256)] {
            XCTAssertThrowsError(try VoiceprintQuality.normalized(vector))
        }
        let store = VoiceprintTestStore()
        let library = LocalVoiceprintLibrary(store: store,
            extractor: VoiceprintTestExtractor(modelID: "wrong-model"), enabled: true)
        do { try await library.enroll(name: "示例", samples: pcm, consent: true); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceprintError, .incompatibleModel) }
        XCTAssertTrue(store.load().isEmpty)
    }

    func testDisableDeleteAndCancellationRejectLateEnrollment() async throws {
        for action in ["disable", "delete", "cancel"] {
            let store = VoiceprintTestStore()
            let extractor = VoiceprintBlockedExtractor()
            let library = LocalVoiceprintLibrary(store: store, extractor: extractor, enabled: true)
            let samples = pcm
            let task = Task { try await library.enroll(name: "不应保存", samples: samples, consent: true) }
            await extractor.waitUntilEntered()
            switch action {
            case "disable": await library.setEnabled(false)
            case "delete": try await library.deleteAll()
            default: task.cancel()
            }
            await extractor.release()
            do { try await task.value; XCTFail("Late work must fail") }
            catch { XCTAssertTrue(error is CancellationError || error as? VoiceprintError == .staleOperation) }
            XCTAssertTrue(store.load().isEmpty)
        }
    }

    func testDeletionAndDisableInvalidatePreviouslyDisplayedSuggestions() async throws {
        for action in ["disable", "one", "all"] {
            let store = VoiceprintTestStore()
            let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor(), enabled: true)
            try await library.enroll(name: "示例", samples: pcm, consent: true)
            let result = try await library.suggest(samples: pcm)
            let suggestion = try XCTUnwrap(result)
            switch action {
            case "disable": await library.setEnabled(false); await library.setEnabled(true)
            case "one": try await library.delete(id: suggestion.profileID)
            default: try await library.deleteAll()
            }
            do { _ = try await library.confirmedName(for: suggestion); XCTFail() }
            catch { XCTAssertEqual(error as? VoiceprintError, .staleOperation) }
        }
    }

    func testOutOfOrderToggleRequestsCannotReenableLibrary() async throws {
        let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor())
        await library.setEnabled(false, request: 2)
        await library.setEnabled(true, request: 1)
        do { _ = try await library.suggest(samples: pcm); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceprintError, .disabled) }
    }

    func testSaveFailurePreservesExistingLibrary() async throws {
        let store = VoiceprintTestStore()
        let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "原声纹", samples: pcm, consent: true)
        store.state.withLock { $0.failSave = true }
        do { try await library.enroll(name: "新声纹", samples: pcm, consent: true); XCTFail() } catch {}
        do { try await library.deleteAll(); XCTFail() } catch {}
        let profiles = try await library.summaries()
        XCTAssertEqual(profiles.map(\.name), ["原声纹"])
        XCTAssertEqual(store.load().map(\.name), ["原声纹"])
    }

    func testDuplicateNameDoesNotReplaceProfileOrCreateCompetingIdentity() async throws {
        let store = VoiceprintTestStore()
        let library = LocalVoiceprintLibrary(store: store, extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "Alice", samples: pcm, consent: true)
        let id = store.load().first?.id
        do { try await library.enroll(name: " alice ", samples: pcm, consent: true); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceprintError, .duplicateName) }
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.id, id)
    }

    func testClipReaderUsesExactMasterTimelineAndBoundsMemory() async throws {
        let id = UUID()
        let a = [Float](repeating: 0.1, count: 160_000)
        let b = [Float](repeating: 0.2, count: 160_000)
        let c = [Float](repeating: 0.3, count: 160_000)
        let source = VoiceprintTestReader([.init(samples: a, startingAt: 0), .init(samples: b, startingAt: 10),
                                          .init(samples: c, startingAt: 20)])
        let clip = try await VoiceprintClipReader(reader: source).samples(meetingID: id, start: 7, end: 40)
        XCTAssertEqual(clip, Array(a.suffix(48_000)) + b + Array(c.prefix(112_000)))
        XCTAssertEqual(clip.count, 320_000)
        let calls = await source.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, id)
        XCTAssertEqual(calls[0].1, .master)
    }

    func testClipReaderRejectsMissingGappedAndInvalidTimeline() async throws {
        for chunks: [MeetingAudioSampleChunk] in [[], [.init(samples: pcm, startingAt: 1)],
             [.init(samples: pcm, startingAt: .nan)], [.init(samples: pcm, startingAt: .infinity)]] {
            do {
                _ = try await VoiceprintClipReader(reader: VoiceprintTestReader(chunks))
                    .samples(meetingID: UUID(), start: 0, end: 5)
                XCTFail()
            } catch { XCTAssertEqual(error as? VoiceprintError, .poorAudio) }
        }
    }
}
