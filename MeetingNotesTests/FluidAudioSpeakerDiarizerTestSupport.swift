import AVFoundation
import Foundation
import XCTest
@testable import MeetingNotes

enum DiarizationAdapterTestError: Error, Sendable {
    case conversion
    case identityChanged
    case invalidFixture
    case preparation
    case processing
}

class DiarizationAdapterTestCase: XCTestCase {
    func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FluidAudioSpeakerDiarizerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    func makeSource(
        root: URL,
        segmentSamples: [[Float]],
        segmentStartTimes: [TimeInterval],
        declaredFrameCounts: [Int64]? = nil,
        meetingID: UUID = UUID()
    ) throws -> MeetingAudioSource {
        let frameCounts = declaredFrameCounts
            ?? segmentSamples.map { Int64($0.count) }
        guard frameCounts.count == segmentSamples.count else {
            throw DiarizationAdapterTestError.invalidFixture
        }
        var resolvedSegments: [ResolvedMeetingRecordingSegment] = []
        for (index, samples) in segmentSamples.enumerated() {
            let url = root.appendingPathComponent(
                "segment-\(meetingID.uuidString)-\(index).caf"
            )
            try writeCAF(samples: samples, to: url)
            resolvedSegments.append(
                ResolvedMeetingRecordingSegment(
                    url: url,
                    fileIdentity: MeetingRecordingFileIdentity(
                        deviceID: 1,
                        inodeNumber: UInt64(index + 1)
                    ),
                    meetingDirectoryIdentity:
                        MeetingRecordingFileIdentity(
                            deviceID: 1,
                            inodeNumber: 1
                        )
                )
            )
        }
        return MeetingAudioSource(
            meetingID: meetingID,
            resolvedSegments: resolvedSegments,
            segmentFrameCounts: frameCounts,
            sampleRate: 48_000,
            channelCount: 1,
            totalFrames: frameCounts.reduce(0, +),
            manifestSignature: "manifest-\(meetingID.uuidString)",
            identitySignature: "identity-\(meetingID.uuidString)",
            segmentStartTimes: segmentStartTimes
        )
    }

    func makeDiarizer(
        root: URL,
        sourceLoader: any MeetingTrackAudioSourceLoading,
        engine: any DiarizationEngine,
        converter: any DiarizationAudioConverting,
        timelineLimits: DiarizationTimelineLimits = .production
    ) -> FluidAudioSpeakerDiarizer {
        FluidAudioSpeakerDiarizer(
            modelsDirectory: root.appendingPathComponent(
                "models",
                isDirectory: true
            ),
            sourceLoader: sourceLoader,
            engine: engine,
            converter: converter,
            temporaryDirectory: root,
            timelineLimits: timelineLimits
        )
    }

    func assertDiarizationFailure(
        _ expected: SpeakerDiarizationError,
        _ operation: () async throws -> [SpeakerInterval],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected diarization failure", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SpeakerDiarizationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func writeCAF(
        samples: [Float],
        to url: URL
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard !samples.isEmpty else {
            file.close()
            return
        }
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try file.write(from: buffer)
        file.close()
    }
}

actor DiarizationAdapterTestSourceLoader:
    MeetingTrackAudioSourceLoading {
    private let source: MeetingAudioSource
    private let failingConfirmation: Int?
    private let cancellingConfirmation: Int?
    private var confirmationCount = 0

    init(
        source: MeetingAudioSource,
        failingConfirmation: Int? = nil,
        cancellingConfirmation: Int? = nil
    ) {
        self.source = source
        self.failingConfirmation = failingConfirmation
        self.cancellingConfirmation = cancellingConfirmation
    }

    func load(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSource {
        _ = meetingID
        _ = track
        return source
    }

    func confirmSegmentIdentity(
        in source: MeetingAudioSource,
        segmentIndex: Int
    ) async throws {
        _ = source
        _ = segmentIndex
        confirmationCount += 1
        if confirmationCount == cancellingConfirmation {
            throw CancellationError()
        }
        if confirmationCount == failingConfirmation {
            throw DiarizationAdapterTestError.identityChanged
        }
    }

    func confirmations() -> Int {
        confirmationCount
    }
}

actor DiarizationAdapterTestConverter: DiarizationAudioConverting {
    enum Behavior: Sendable {
        case succeed
        case failAfterWriting
        case cancelAfterWriting
    }

    private let behavior: Behavior
    private var inputSamples: [[Float]] = []
    private var rawOutputURLs: [URL] = []

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func convert(
        inputURL: URL,
        rawOutputURL: URL,
        targetSampleRate: Int
    ) async throws -> Int {
        let file = try AVAudioFile(forReading: inputURL)
        let frameCapacity: AVAudioFrameCount = 4_096
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCapacity
            )
        )
        var samples: [Float] = []
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(
                min(Int64(frameCapacity), remaining)
            )
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0,
                  let channel = buffer.floatChannelData?.pointee else {
                throw DiarizationAdapterTestError.conversion
            }
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(buffer.frameLength)
                )
            )
        }
        file.close()
        inputSamples.append(samples)
        rawOutputURLs.append(rawOutputURL)

        let sourceRate = Int(buffer.format.sampleRate.rounded())
        let step = max(1, sourceRate / targetSampleRate)
        let converted = Swift.stride(
            from: 0,
            to: samples.count,
            by: step
        ).map { samples[$0] }
        let data = converted.withUnsafeBufferPointer { pointer in
            Data(
                bytes: pointer.baseAddress!,
                count: pointer.count * MemoryLayout<Float>.stride
            )
        }
        try data.write(to: rawOutputURL)
        if behavior == .failAfterWriting {
            throw DiarizationAdapterTestError.conversion
        }
        if behavior == .cancelAfterWriting {
            throw CancellationError()
        }
        return converted.count
    }

    func recordedInputSamples() -> [[Float]] {
        inputSamples
    }

    func recordedOutputURLs() -> [URL] {
        rawOutputURLs
    }
}

actor DiarizationAdapterImmediateEngine: DiarizationEngine {
    private var results: [[SpeakerInterval]]
    private var remainingPreparationFailures: Int
    private var prepareCount = 0
    private var processCount = 0
    private var processedSampleCounts: [Int] = []
    private var processedURLs: [URL] = []
    private let processError: DiarizationAdapterTestError?
    private let cancelPreparation: Bool
    private let cancelProcessing: Bool

    init(
        results: [[SpeakerInterval]],
        preparationFailures: Int = 0,
        processError: DiarizationAdapterTestError? = nil,
        cancelPreparation: Bool = false,
        cancelProcessing: Bool = false
    ) {
        self.results = results
        remainingPreparationFailures = preparationFailures
        self.processError = processError
        self.cancelPreparation = cancelPreparation
        self.cancelProcessing = cancelProcessing
    }

    func prepareModels(directory: URL) async throws {
        _ = directory
        prepareCount += 1
        if cancelPreparation {
            throw CancellationError()
        }
        if remainingPreparationFailures > 0 {
            remainingPreparationFailures -= 1
            throw DiarizationAdapterTestError.preparation
        }
    }

    func process(
        audioSource: DiarizationDiskAudioSource,
        audioLoadingSeconds: TimeInterval
    ) async throws -> [SpeakerInterval] {
        _ = audioLoadingSeconds
        processCount += 1
        processedSampleCounts.append(audioSource.sampleCount)
        processedURLs.append(audioSource.fileURL)
        if cancelProcessing {
            throw CancellationError()
        }
        if let processError {
            throw processError
        }
        guard !results.isEmpty else {
            return []
        }
        return results.removeFirst()
    }

    func counts() -> (prepare: Int, process: Int) {
        (prepareCount, processCount)
    }

    func sampleCounts() -> [Int] {
        processedSampleCounts
    }

    func sourceURLs() -> [URL] {
        processedURLs
    }
}

actor DiarizationAdapterCancellableEngine: DiarizationEngine {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var processContinuation:
        CheckedContinuation<Void, Error>?
    private var processedURL: URL?

    func prepareModels(directory: URL) async throws {
        _ = directory
    }

    func process(
        audioSource: DiarizationDiskAudioSource,
        audioLoadingSeconds: TimeInterval
    ) async throws -> [SpeakerInterval] {
        _ = audioLoadingSeconds
        processedURL = audioSource.fileURL
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(
                        throwing: CancellationError()
                    )
                } else {
                    processContinuation = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelProcess()
            }
        }
        return []
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func sourceURL() -> URL? {
        processedURL
    }

    private func cancelProcess() {
        processContinuation?.resume(
            throwing: CancellationError()
        )
        processContinuation = nil
    }
}

actor DiarizationAdapterBlockingEngine: DiarizationEngine {
    private var prepareCount = 0
    private var startCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var processContinuations: [
        Int: CheckedContinuation<Void, Error>
    ] = [:]
    private var automaticallyRelease = false

    func prepareModels(directory: URL) async throws {
        _ = directory
        prepareCount += 1
    }

    func process(
        audioSource: DiarizationDiskAudioSource,
        audioLoadingSeconds: TimeInterval
    ) async throws -> [SpeakerInterval] {
        _ = audioLoadingSeconds
        var firstSample: Float = 0
        try withUnsafeMutablePointer(to: &firstSample) {
            try audioSource.copySamples(
                into: $0,
                offset: 0,
                count: 1
            )
        }

        startCount += 1
        let processNumber = startCount
        activeCount += 1
        maximumActiveCount = max(
            maximumActiveCount,
            activeCount
        )
        resumeSatisfiedStartWaiters()
        defer { activeCount -= 1 }

        if !automaticallyRelease {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<Void, Error>
                    ) in
                    if Task.isCancelled {
                        continuation.resume(
                            throwing: CancellationError()
                        )
                    } else if automaticallyRelease {
                        continuation.resume()
                    } else {
                        processContinuations[processNumber] =
                            continuation
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelProcess(processNumber)
                }
            }
        }

        return [
            SpeakerInterval(
                rawSpeakerID: String(
                    format: "source-%.2f",
                    firstSample
                ),
                startTime: 0,
                endTime: 0.05
            ),
        ]
    }

    func waitUntilStarted(_ count: Int) async {
        if startCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func releaseAllProcesses() {
        automaticallyRelease = true
        let continuations = processContinuations.values
        processContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func snapshot() -> (
        prepare: Int,
        started: Int,
        maximumActive: Int
    ) {
        (prepareCount, startCount, maximumActiveCount)
    }

    private func cancelProcess(_ processNumber: Int) {
        processContinuations.removeValue(
            forKey: processNumber
        )?.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in startWaiters {
            if startCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        startWaiters = remaining
    }
}

actor DiarizationAdapterPreparationEngine: DiarizationEngine {
    private var preparationCount = 0
    private var preparationWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var preparationContinuations: [
        CheckedContinuation<Void, Never>
    ] = []
    private var automaticallyRelease = false

    func prepareModels(directory: URL) async throws {
        _ = directory
        preparationCount += 1
        resumeSatisfiedPreparationWaiters()
        if automaticallyRelease {
            return
        }
        await withCheckedContinuation { continuation in
            if automaticallyRelease {
                continuation.resume()
            } else {
                preparationContinuations.append(continuation)
            }
        }
    }

    func process(
        audioSource: DiarizationDiskAudioSource,
        audioLoadingSeconds: TimeInterval
    ) async throws -> [SpeakerInterval] {
        _ = audioSource
        _ = audioLoadingSeconds
        return [
            SpeakerInterval(
                rawSpeakerID: "prepared",
                startTime: 0,
                endTime: 0.05
            ),
        ]
    }

    func waitUntilPreparationStarted(_ count: Int) async {
        if preparationCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            preparationWaiters.append((count, continuation))
        }
    }

    func releaseAllPreparations() {
        automaticallyRelease = true
        let continuations = preparationContinuations
        preparationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func count() -> Int {
        preparationCount
    }

    private func resumeSatisfiedPreparationWaiters() {
        var remaining: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in preparationWaiters {
            if preparationCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        preparationWaiters = remaining
    }
}
