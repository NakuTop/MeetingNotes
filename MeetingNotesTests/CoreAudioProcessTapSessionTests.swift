import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingNotes

final class CoreAudioProcessTapSessionTests: XCTestCase {
    func testOwnedSystemAggregateCannotBecomeAMicrophoneCandidate() throws {
        let description = SystemAudioTapPolicy.aggregateDescription(tapUID: "tap", id: UUID())
        let uid = try XCTUnwrap(description[kAudioAggregateDeviceUIDKey] as? String)
        let devices = CoreAudioDeviceProvider.buildInputDevices(
            deviceIDs: [100, 101], defaultInputID: nil, channelCount: { _ in 1 },
            uid: { $0 == 100 ? uid : "third-party-virtual-mic" },
            // Names alone must never determine whether a mic is usable.
            name: { _ in "MeetingNotes System Audio Input" }, isAlive: { _ in true }
        )
        XCTAssertEqual(devices.map(\.deviceID), [101])
    }

    func testTapIsPrivateUnmutedAndExcludesThisProcess() {
        let description = SystemAudioTapPolicy.description(excluding: 77)
        XCTAssertTrue(description.isPrivate)
        XCTAssertTrue(description.isExclusive)
        XCTAssertTrue(description.isMono)
        XCTAssertTrue(description.isMixdown)
        XCTAssertEqual(description.processes, [77])
        XCTAssertEqual(description.muteBehavior, .unmuted)
    }

    func testDiagnosticTapIncludesOwnTestToneWithoutChangingMeetingDefault() async throws {
        let log = TapTestLog()
        let api = TapTestAPI(log: log)
        let session = CoreAudioProcessTapSession(
            excludesCurrentProcessAudio: false, api: api,
            readerFactory: { TapTestReader(log: log) }
        )
        try await session.start(onEvent: { _ in })
        XCTAssertFalse(log.values.contains("process"))
        XCTAssertEqual(api.excludedProcesses, [])
        XCTAssertEqual(SystemAudioTapPolicy.description(excluding: 77).processes, [77])
        await session.stop()
    }

    func testReaderStartupPreservesTypedFailureStageAndStatus() async {
        let log = TapTestLog()
        let reader = TapTestReader(log: log, startupError: .initializationFailed(-10868))
        let session = CoreAudioProcessTapSession(api: TapTestAPI(log: log), readerFactory: { reader })
        do {
            try await session.start(onEvent: { _ in })
            XCTFail("Expected initialization failure")
        } catch {
            XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailure(.initializationFailed(-10868)))
        }
        XCTAssertEqual(Array(log.values.suffix(3)), ["stop", "aggregate-200", "tap-100"])
    }

    func testRenderFailureIsNotFlattenedIntoPermissionOrGenericStartupError() async throws {
        let log = TapTestLog()
        let reader = TapTestReader(log: log)
        let events = TapTestEvents()
        let session = CoreAudioProcessTapSession(api: TapTestAPI(log: log), readerFactory: { reader })
        try await session.start(onEvent: { events.append($0) })
        reader.emitFailure(error: CoreAudioMicrophoneError.renderFailed(-50))
        guard case let .failure(error) = try XCTUnwrap(events.snapshot.first) else {
            await session.stop()
            return XCTFail("Expected callback failure")
        }
        XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailure(.renderFailed(-50)))
        await session.stop()
    }

    func testAggregateIsEphemeralAndDoesNotWaitForOtherAppsToPlay() throws {
        let description = SystemAudioTapPolicy.aggregateDescription(tapUID: "test-tap", id: UUID())
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, false)
        XCTAssertNil(description[kAudioAggregateDeviceSubDeviceListKey])
        let taps = try XCTUnwrap(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0][kAudioSubTapUIDKey] as? String, "test-tap")
    }

    func testStartsAggregateInputAndStopsReaderBeforeDestroyingResources() async throws {
        let log = TapTestLog()
        let reader = TapTestReader(log: log)
        let session = CoreAudioProcessTapSession(api: TapTestAPI(log: log), readerFactory: { reader })
        try await session.start(onEvent: { _ in })
        await session.stop()
        await session.stop()
        XCTAssertEqual(log.values, ["process", "tap+100", "aggregate+200", "configure:200", "start", "stop", "aggregate-200", "tap-100"])
    }

    func testAggregateFailureDestroysOnlyCreatedTap() async {
        let log = TapTestLog()
        let api = TapTestAPI(log: log, failAggregate: true)
        let session = CoreAudioProcessTapSession(api: api, readerFactory: { TapTestReader(log: log) })
        do {
            try await session.start(onEvent: { _ in })
            XCTFail("Expected aggregate failure")
        } catch {
            XCTAssertEqual(error as? SystemAudioCaptureError, .aggregateCreationFailed(-1))
        }
        XCTAssertEqual(log.values, ["process", "tap+100", "aggregate-failed", "tap-100"])
    }

    func testReaderStartFailureCleansResourcesWithoutMutingOutput() async {
        let log = TapTestLog()
        let reader = TapTestReader(log: log, failStart: true)
        let session = CoreAudioProcessTapSession(api: TapTestAPI(log: log), readerFactory: { reader })
        do {
            try await session.start(onEvent: { _ in })
            XCTFail("Expected input failure")
        } catch { XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailed) }
        XCTAssertEqual(Array(log.values.suffix(3)), ["stop", "aggregate-200", "tap-100"])
    }

    func testPreCancelledCallerDoesNotCreateTap() async {
        let barrier = TapTestBarrier()
        let log = TapTestLog()
        let session = CoreAudioProcessTapSession(api: TapTestAPI(log: log), readerFactory: { TapTestReader(log: log) })
        let caller = Task { () -> Bool in
            await barrier.wait()
            do { try await session.start(onEvent: { _ in }); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        caller.cancel()
        await barrier.release()
        let cancelled = await caller.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(log.values.isEmpty)
    }

    func testCancelledPendingStartReturnsPromptlyAndLateCompletionCannotAffectRestart() async throws {
        let log = TapTestLog()
        let entered = expectation(description: "old input configure entered")
        let completed = expectation(description: "cancelled caller returned")
        let cleaned = expectation(description: "old tap cleaned after its configure returns")
        let barrier = TapTestBarrier()
        let oldReader = TapTestReader(log: log, barrier: barrier, entered: entered)
        let newReader = TapTestReader(log: log)
        let readers = TapTestReaders([oldReader, newReader])
        let api = TapTestAPI(log: log, oldCleanup: cleaned)
        let session = CoreAudioProcessTapSession(api: api, readerFactory: { readers.next() })
        let events = TapTestEvents()
        let caller = Task { () -> Bool in
            defer { completed.fulfill() }
            do { try await session.start(onEvent: { events.append($0) }); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        await fulfillment(of: [entered], timeout: 1)
        caller.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        let cancelled = await caller.value
        XCTAssertTrue(cancelled)
        try await session.start(onEvent: { events.append($0) })
        await barrier.release()
        await fulfillment(of: [cleaned], timeout: 1)
        oldReader.emitFailure()
        XCTAssertTrue(events.snapshot.isEmpty)
        XCTAssertFalse(log.values.contains("aggregate-201"))
        await session.stop()
        XCTAssertEqual(log.values.filter { $0 == "tap-100" }.count, 1)
        XCTAssertEqual(log.values.filter { $0 == "tap-101" }.count, 1)
    }

    func testInputPreservesAmplitudeAndDeliversMono48KWithoutScreenFrames() async throws {
        let log = TapTestLog()
        let reader = TapTestReader(log: log)
        let events = TapTestEvents()
        let session = CoreAudioProcessTapSession(api: TapTestAPI(log: log), readerFactory: { reader })
        try await session.start(onEvent: { events.append($0) })
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = 0.02 }
        reader.emit(buffer: buffer)
        let event = try XCTUnwrap(events.snapshot.first)
        guard case let .frame(frame) = event else { return XCTFail("Expected PCM frame") }
        XCTAssertEqual(frame.sampleRate, 48_000)
        XCTAssertEqual(frame.channelCount, 1)
        XCTAssertEqual(frame.samples.count, 480)
        XCTAssertEqual(frame.samples[200], 0.02, accuracy: 0.000_1)
        await session.stop()
        reader.emit(buffer: buffer)
        XCTAssertEqual(events.snapshot.count, 1)
    }
}

private final class TapTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.withLock { entries.append(value) } }
    var values: [String] { lock.withLock { entries } }
}

private final class TapTestAPI: CoreAudioProcessTapAPI, @unchecked Sendable {
    private let lock = NSLock()
    let log: TapTestLog
    let failAggregate: Bool
    let oldCleanup: XCTestExpectation?
    private var nextTap: AudioObjectID = 100
    private var nextAggregate: AudioObjectID = 200
    private var processes: [AudioObjectID] = []
    var excludedProcesses: [AudioObjectID] { lock.withLock { processes } }
    init(log: TapTestLog, failAggregate: Bool = false, oldCleanup: XCTestExpectation? = nil) {
        self.log = log; self.failAggregate = failAggregate; self.oldCleanup = oldCleanup
    }
    func currentProcessObjectID() throws -> AudioObjectID { log.append("process"); return 77 }
    func createTap(description: CATapDescription) throws -> AudioObjectID {
        lock.withLock {
            processes = description.processes
            let id = nextTap; nextTap += 1; log.append("tap+\(id)"); return id
        }
    }
    func createAggregate(tapUID: String) throws -> AudioObjectID {
        if failAggregate { log.append("aggregate-failed"); throw SystemAudioCaptureError.aggregateCreationFailed(-1) }
        return lock.withLock { let id = nextAggregate; nextAggregate += 1; log.append("aggregate+\(id)"); return id }
    }
    func destroyAggregate(_ id: AudioObjectID) { log.append("aggregate-\(id)") }
    func destroyTap(_ id: AudioObjectID) { log.append("tap-\(id)"); if id == 100 { oldCleanup?.fulfill() } }
}

private actor TapTestBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private final class TapTestReader: CoreAudioMicrophoneSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    let log: TapTestLog
    let barrier: TapTestBarrier?
    let entered: XCTestExpectation?
    let failStart: Bool
    let startupError: CoreAudioMicrophoneError?
    init(log: TapTestLog, barrier: TapTestBarrier? = nil, entered: XCTestExpectation? = nil,
         failStart: Bool = false, startupError: CoreAudioMicrophoneError? = nil) {
        self.log = log; self.barrier = barrier; self.entered = entered; self.failStart = failStart
        self.startupError = startupError
    }
    func configure(deviceID: AudioDeviceID?, eventHandler: @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void) async throws {
        log.append("configure:\(deviceID ?? 0)")
        lock.withLock { handler = eventHandler }
        entered?.fulfill()
        await barrier?.wait()
    }
    func start() async throws {
        log.append("start")
        if let startupError { throw startupError }
        if failStart { throw SystemAudioCaptureError.inputFailed }
    }
    func pause() async {}
    func resume() async throws {}
    func stop() async { log.append("stop") }
    func emit(buffer: AVAudioPCMBuffer) { lock.withLock { handler }?(.buffer(buffer, 0, 48_000)) }
    func emitFailure(error: Error = SystemAudioCaptureError.inputFailed) {
        lock.withLock { handler }?(.failure(error))
    }
}

private final class TapTestReaders: @unchecked Sendable {
    private let lock = NSLock()
    private var readers: [TapTestReader]
    init(_ readers: [TapTestReader]) { self.readers = readers }
    func next() -> TapTestReader { lock.withLock { readers.removeFirst() } }
}

private final class TapTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SystemAudioCaptureEvent] = []
    func append(_ event: SystemAudioCaptureEvent) { lock.withLock { events.append(event) } }
    var snapshot: [SystemAudioCaptureEvent] { lock.withLock { events } }
}
