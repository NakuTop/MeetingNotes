import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingNotes

final class CoreAudioMicrophoneSampleProviderTests: XCTestCase {
    func testProviderConfiguresResolvedDeviceAndDeliversSamples() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["external-mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let buffer = try makeBuffer(samples: [0.3, -0.2, 0.5])

        let stream = try await provider.start(deviceID: "external-mic")
        await session.emit(
            .buffer(buffer, AVAudioFramePosition(4_800), 48_000)
        )

        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        let sample = try XCTUnwrap(next)
        let configuredIDs = await session.configuredDeviceIDs()
        XCTAssertEqual(configuredIDs, [AudioDeviceID(42)])
        XCTAssertEqual(sample.sampleTime, 4_800)
        XCTAssertEqual(sample.sampleRate, 48_000)
        XCTAssertEqual(sample.buffer.frameLength, 3)
        await provider.stop()
    }

    func testNilDeviceIDUsesSystemDefaultInput() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(7)
            )
        )

        _ = try await provider.start(deviceID: nil)

        let configuredIDs = await session.configuredDeviceIDs()
        XCTAssertEqual(configuredIDs, [AudioDeviceID(7)])
        await provider.stop()
    }

    func testStartFailureStopsSessionAndCanRetry() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        await session.setStartError(CoreAudioSessionTestError.startFailed)
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected start failure")
        } catch {
            XCTAssertEqual(
                error as? CoreAudioSessionTestError,
                .startFailed
            )
        }
        let stopsAfterFailure = await session.stopCount()
        XCTAssertEqual(stopsAfterFailure, 1)

        await session.setStartError(nil)
        let stream = try await provider.start(deviceID: nil)
        withExtendedLifetime(stream) {}
        await provider.stop()
        let finalStops = await session.stopCount()
        XCTAssertEqual(finalStops, 2)
    }

    func testDoubleStartIsRejected() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        let stream = try await provider.start(deviceID: nil)

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected already running")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .alreadyRunning)
        }
        withExtendedLifetime(stream) {}
        await provider.stop()
    }

    func testStopIsIdempotentAndStopsSessionExactlyOnce() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        let stream = try await provider.start(deviceID: nil)

        await provider.stop()
        await provider.stop()

        let stops = await session.stopCount()
        XCTAssertEqual(stops, 1)
        var iterator = stream.makeAsyncIterator()
        let firstAfterStop = try await iterator.next()
        let secondAfterStop = try await iterator.next()
        XCTAssertNil(firstAfterStop)
        XCTAssertNil(secondAfterStop)
    }

    func testPauseResumeForwardAndAreIdempotent() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        let stream = try await provider.start(deviceID: nil)

        try await provider.pause()
        try await provider.pause()
        try await provider.resume()
        try await provider.resume()

        let pauses = await session.pauseCount()
        let resumes = await session.resumeCount()
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(resumes, 1)
        withExtendedLifetime(stream) {}
        await provider.stop()
    }

    func testStreamTerminationStopsSessionExactlyOnce() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        do {
            let stream = try await provider.start(deviceID: nil)
            var iterator = stream.makeAsyncIterator()
            _ = iterator
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let stopsAfterTermination = await session.stopCount()
        XCTAssertEqual(stopsAfterTermination, 1)
        await provider.stop()
        let stopsAfterExplicitStop = await session.stopCount()
        XCTAssertEqual(stopsAfterExplicitStop, 1)
    }

    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        samples.enumerated().forEach { index, value in
            channel[index] = value
        }
        return buffer
    }
}

private enum CoreAudioSessionTestError: Error, Equatable, Sendable {
    case startFailed
}

private actor FakeCoreAudioMicrophoneSession:
    CoreAudioMicrophoneSessionManaging {
    private var configuredIDs: [AudioDeviceID?] = []
    private var handler:
        (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    private var startError: CoreAudioSessionTestError?
    private var pauses = 0
    private var resumes = 0
    private var stops = 0

    func configure(
        deviceID: AudioDeviceID?,
        eventHandler:
            @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void
    ) async throws {
        configuredIDs.append(deviceID)
        handler = eventHandler
    }

    func start() async throws {
        if let startError {
            throw startError
        }
    }

    func pause() async {
        pauses += 1
    }

    func resume() async throws {
        resumes += 1
    }

    func stop() async {
        stops += 1
        handler = nil
    }

    func emit(_ event: CoreAudioMicrophoneSessionEvent) {
        handler?(event)
    }

    func setStartError(_ error: CoreAudioSessionTestError?) {
        startError = error
    }

    func configuredDeviceIDs() -> [AudioDeviceID?] {
        configuredIDs
    }

    func pauseCount() -> Int {
        pauses
    }

    func resumeCount() -> Int {
        resumes
    }

    func stopCount() -> Int {
        stops
    }
}

private struct StaticCoreAudioDeviceIDResolver:
    CoreAudioDeviceIDResolving {
    let idsByUID: [String: AudioDeviceID]
    let defaultID: AudioDeviceID

    func resolve(deviceID: String?) throws -> AudioDeviceID? {
        if let deviceID {
            return idsByUID[deviceID]
        }
        return defaultID
    }
}
