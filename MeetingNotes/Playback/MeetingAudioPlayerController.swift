import AVFoundation
import Foundation
import Observation

protocol MeetingAudioSourceLoading: Sendable {
    func load(meetingID: UUID) async throws -> MeetingAudioSource
}

extension MeetingAudioSourceLoader: MeetingAudioSourceLoading {}

protocol MeetingWaveformLoading: Sendable {
    func values(
        for source: MeetingAudioSource,
        bucketCount: Int
    ) async throws -> [Float]
}

extension WaveformAnalyzer: MeetingWaveformLoading {}

@MainActor
protocol MeetingAudioPlaybackEngine: AnyObject {
    func prepare(
        source: MeetingAudioSource,
        onPeriodicTime: @escaping @MainActor @Sendable (TimeInterval) -> Void,
        onEnd: @escaping @MainActor @Sendable () -> Void
    ) async throws -> TimeInterval
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

@MainActor
protocol MeetingPlaybackStopping: AnyObject {
    func stopAndWait(meetingID: UUID?) async
}

enum MeetingAudioPlayerState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

@MainActor
@Observable
final class MeetingAudioPlayerController: MeetingPlaybackStopping {
    private(set) var meetingID: UUID?
    private(set) var state: MeetingAudioPlayerState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var waveform: [Float] = []

    @ObservationIgnored private let sourceLoader: any MeetingAudioSourceLoading
    @ObservationIgnored private let waveformLoader: any MeetingWaveformLoading
    @ObservationIgnored private let engine: any MeetingAudioPlaybackEngine
    @ObservationIgnored private let waveformBucketCount: Int
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var prepareWaiters: Set<UUID> = []
    @ObservationIgnored private var quiescingPreparations: [
        UUID: [UUID: Task<Void, Never>]
    ] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var shouldResumeAfterSeeking = false

    init(
        sourceLoader: any MeetingAudioSourceLoading,
        waveformLoader: any MeetingWaveformLoading,
        engine: any MeetingAudioPlaybackEngine,
        waveformBucketCount: Int = 120
    ) {
        self.sourceLoader = sourceLoader
        self.waveformLoader = waveformLoader
        self.engine = engine
        self.waveformBucketCount = max(1, waveformBucketCount)
    }

    /// Preparing an already loaded meeting is idempotent. If that meeting is
    /// still loading, additional callers wait for the shared preparation.
    func prepare(meetingID requestedMeetingID: UUID) async {
        let waiterID = UUID()
        let requestedGeneration: UInt64
        let task: Task<Void, Never>

        if meetingID == requestedMeetingID {
            switch state {
            case .loading:
                if let prepareTask {
                    requestedGeneration = generation
                    prepareWaiters.insert(waiterID)
                    task = prepareTask
                    await waitForPreparation(
                        task,
                        waiterID: waiterID,
                        generation: requestedGeneration
                    )
                    return
                }
            case .ready, .playing, .paused, .ended:
                return
            case .failed, .idle:
                break
            }
        }

        replaceCurrentSelectionIfNeeded()
        generation &+= 1
        requestedGeneration = generation
        meetingID = requestedMeetingID
        state = .loading
        currentTime = 0
        duration = 0
        waveform = []
        clearSeekingState()

        prepareWaiters = [waiterID]
        task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performPreparation(
                meetingID: requestedMeetingID,
                generation: requestedGeneration
            )
        }
        prepareTask = task

        await waitForPreparation(
            task,
            waiterID: waiterID,
            generation: requestedGeneration
        )
    }

    private func waitForPreparation(
        _ task: Task<Void, Never>,
        waiterID: UUID,
        generation requestedGeneration: UInt64
    ) async {
        await withTaskCancellationHandler {
            await task.value
            releasePreparationWaiter(
                waiterID,
                generation: requestedGeneration
            )
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.releasePreparationWaiter(
                    waiterID,
                    generation: requestedGeneration
                )
            }
        }
    }

    func togglePlayback() {
        switch state {
        case .ready, .paused:
            engine.play()
            state = .playing
        case .playing:
            engine.pause()
            state = .paused
        case .ended:
            currentTime = 0
            engine.seek(to: 0)
            engine.play()
            state = .playing
        case .idle, .loading, .failed:
            break
        }
    }

    func beginSeeking(to fraction: Double) {
        guard canSeek else { return }
        if !isSeeking {
            isSeeking = true
            shouldResumeAfterSeeking = state == .playing
            engine.pause()
        }
        currentTime = time(for: fraction)
    }

    func updateSeeking(to fraction: Double) {
        guard isSeeking else { return }
        currentTime = time(for: fraction)
    }

    func endSeeking(at fraction: Double) {
        guard isSeeking else { return }
        let target = time(for: fraction)
        let resumePlayback = shouldResumeAfterSeeking
        clearSeekingState()
        currentTime = target
        engine.seek(to: target)
        if resumePlayback {
            engine.play()
            state = .playing
        } else if target >= duration {
            state = .ended
        } else {
            state = .paused
        }
    }

    func stop(meetingID requestedMeetingID: UUID? = nil) {
        _ = cancelAndReset(meetingID: requestedMeetingID)
    }

    func stopAndWait(meetingID requestedMeetingID: UUID? = nil) async {
        let targetMeetingID = requestedMeetingID ?? meetingID
        _ = cancelAndReset(meetingID: requestedMeetingID)
        let tasks: [Task<Void, Never>]
        if let targetMeetingID {
            tasks = Array(
                quiescingPreparations[targetMeetingID, default: [:]].values
            )
        } else {
            tasks = quiescingPreparations.values.flatMap { $0.values }
        }
        for task in tasks {
            await task.value
        }
    }

    @discardableResult
    private func cancelAndReset(
        meetingID requestedMeetingID: UUID?
    ) -> Task<Void, Never>? {
        if let requestedMeetingID, requestedMeetingID != meetingID {
            return nil
        }
        guard meetingID != nil || state != .idle || prepareTask != nil else {
            return nil
        }

        let task = prepareTask
        let stoppedMeetingID = meetingID
        generation &+= 1
        task?.cancel()
        prepareTask = nil
        prepareWaiters.removeAll()
        engine.stop()
        meetingID = nil
        state = .idle
        currentTime = 0
        duration = 0
        waveform = []
        clearSeekingState()
        if let task, let stoppedMeetingID {
            registerQuiescingPreparation(
                task,
                meetingID: stoppedMeetingID
            )
        }
        return task
    }

    private var canSeek: Bool {
        duration > 0 && {
            switch state {
            case .ready, .playing, .paused, .ended:
                true
            case .idle, .loading, .failed:
                false
            }
        }()
    }

    private func replaceCurrentSelectionIfNeeded() {
        guard meetingID != nil || prepareTask != nil || state != .idle else {
            return
        }
        _ = cancelAndReset(meetingID: nil)
    }

    private func releasePreparationWaiter(
        _ waiterID: UUID,
        generation requestedGeneration: UInt64
    ) {
        guard generation == requestedGeneration,
              prepareWaiters.remove(waiterID) != nil else {
            return
        }
        guard prepareWaiters.isEmpty, prepareTask != nil else { return }
        stop(meetingID: meetingID)
    }

    private func registerQuiescingPreparation(
        _ task: Task<Void, Never>,
        meetingID: UUID
    ) {
        let token = UUID()
        quiescingPreparations[meetingID, default: [:]][token] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.removeQuiescingPreparation(
                token: token,
                meetingID: meetingID
            )
        }
    }

    private func removeQuiescingPreparation(
        token: UUID,
        meetingID: UUID
    ) {
        quiescingPreparations[meetingID]?[token] = nil
        if quiescingPreparations[meetingID]?.isEmpty == true {
            quiescingPreparations[meetingID] = nil
        }
    }

    private func performPreparation(
        meetingID requestedMeetingID: UUID,
        generation requestedGeneration: UInt64
    ) async {
        defer {
            if generation == requestedGeneration {
                prepareTask = nil
                prepareWaiters.removeAll()
            }
        }

        do {
            let source = try await sourceLoader.load(
                meetingID: requestedMeetingID
            )
            try Task.checkCancellation()
            guard isCurrent(
                meetingID: requestedMeetingID,
                generation: requestedGeneration
            ) else { return }

            let preparedDuration = try await engine.prepare(
                source: source,
                onPeriodicTime: { [weak self] time in
                    guard let self,
                          self.isCurrent(
                            meetingID: requestedMeetingID,
                            generation: requestedGeneration
                          ) else { return }
                    self.receivePeriodicTime(time)
                },
                onEnd: { [weak self] in
                    guard let self,
                          self.isCurrent(
                            meetingID: requestedMeetingID,
                            generation: requestedGeneration
                          ) else { return }
                    self.receiveEnd()
                }
            )
            try Task.checkCancellation()
            guard isCurrent(
                meetingID: requestedMeetingID,
                generation: requestedGeneration
            ) else { return }
            guard preparedDuration.isFinite, preparedDuration > 0 else {
                throw AVFoundationMeetingAudioPlaybackEngine.Error.invalidSource
            }

            let loadedWaveform: [Float]
            do {
                loadedWaveform = try await waveformLoader.values(
                    for: source,
                    bucketCount: waveformBucketCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                loadedWaveform = []
            }
            try Task.checkCancellation()
            guard isCurrent(
                meetingID: requestedMeetingID,
                generation: requestedGeneration
            ) else { return }

            duration = preparedDuration
            waveform = loadedWaveform
            currentTime = 0
            state = .ready
        } catch is CancellationError {
            // A newer selection or an explicit stop owns the visible state.
        } catch {
            guard isCurrent(
                meetingID: requestedMeetingID,
                generation: requestedGeneration
            ) else { return }
            engine.stop()
            currentTime = 0
            duration = 0
            waveform = []
            state = .failed(Self.failureMessage(for: error))
        }
    }

    private func receivePeriodicTime(_ time: TimeInterval) {
        guard !isSeeking else { return }
        currentTime = Self.clamp(time, lower: 0, upper: duration)
    }

    private func receiveEnd() {
        guard !isSeeking else { return }
        currentTime = duration
        state = .ended
    }

    private func isCurrent(
        meetingID requestedMeetingID: UUID,
        generation requestedGeneration: UInt64
    ) -> Bool {
        generation == requestedGeneration && meetingID == requestedMeetingID
    }

    private func time(for fraction: Double) -> TimeInterval {
        Self.safeFraction(fraction) * duration
    }

    private func clearSeekingState() {
        isSeeking = false
        shouldResumeAfterSeeking = false
    }

    private static func safeFraction(_ fraction: Double) -> Double {
        if fraction.isNaN { return 0 }
        if fraction == .infinity { return 1 }
        if fraction == -.infinity { return 0 }
        return clamp(fraction, lower: 0, upper: 1)
    }

    private static func clamp(
        _ value: Double,
        lower: Double,
        upper: Double
    ) -> Double {
        if value.isNaN { return lower }
        guard value.isFinite else {
            return value.sign == .minus ? lower : upper
        }
        return min(max(value, lower), upper)
    }

    private static func failureMessage(for error: Swift.Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return "无法准备会议录音，请稍后重试。"
    }
}

@MainActor
final class AVFoundationMeetingAudioPlaybackEngine: MeetingAudioPlaybackEngine {
    typealias CompositionBuilder = @MainActor @Sendable (
        MeetingAudioSource
    ) async throws -> AVMutableComposition

    private final class ObserverStorage: @unchecked Sendable {
        var periodicTimeObserver: Any?
        var endObserver: NSObjectProtocol?
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidSource
        case missingAudioTrack(index: Int)
        case cannotCreateCompositionTrack

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                "该会议的录音长度无效。"
            case .missingAudioTrack:
                "该会议的部分录音没有可播放的音频轨道。"
            case .cannotCreateCompositionTrack:
                "无法创建会议录音播放队列。"
            }
        }
    }

    private let player: AVPlayer
    private let compositionBuilder: CompositionBuilder
    private let observers = ObserverStorage()
    private var generation: UInt64 = 0

    init(
        player: AVPlayer = AVPlayer(),
        compositionBuilder: @escaping CompositionBuilder = { source in
            try await AVFoundationMeetingAudioPlaybackEngine
                .makeComposition(for: source)
        }
    ) {
        self.player = player
        self.compositionBuilder = compositionBuilder
    }

    func prepare(
        source: MeetingAudioSource,
        onPeriodicTime: @escaping @MainActor @Sendable (TimeInterval) -> Void,
        onEnd: @escaping @MainActor @Sendable () -> Void
    ) async throws -> TimeInterval {
        stop()
        let requestedGeneration = generation
        do {
            let composition = try await compositionBuilder(source)
            try Task.checkCancellation()
            guard generation == requestedGeneration else {
                throw CancellationError()
            }
            let item = AVPlayerItem(asset: composition)
            player.replaceCurrentItem(with: item)
            observers.periodicTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor in
                    guard self?.generation == requestedGeneration else { return }
                    onPeriodicTime(time.seconds)
                }
            }
            observers.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard self?.generation == requestedGeneration else { return }
                    onEnd()
                }
            }
            return composition.duration.seconds
        } catch {
            if generation == requestedGeneration {
                resetPlayer()
            }
            throw error
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval) {
        let seconds = time.isFinite ? max(0, time) : 0
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stop() {
        generation &+= 1
        resetPlayer()
    }

    private func resetPlayer() {
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        if let periodicTimeObserver = observers.periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        if let endObserver = observers.endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    static func makeComposition(
        for source: MeetingAudioSource
    ) async throws -> AVMutableComposition {
        guard source.resolvedSegments.count == source.segmentFrameCounts.count,
              !source.resolvedSegments.isEmpty,
              source.sampleRate.isFinite,
              source.sampleRate > 0,
              source.sampleRate.rounded() == source.sampleRate,
              source.sampleRate <= Double(Int32.max),
              source.totalFrames > 0 else {
            throw Error.invalidSource
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw Error.cannotCreateCompositionTrack
        }
        let timescale = CMTimeScale(source.sampleRate)
        var cursor = CMTime.zero

        for (index, resolvedSegment) in source.resolvedSegments.enumerated() {
            try Task.checkCancellation()
            let frameCount = source.segmentFrameCounts[index]
            guard frameCount > 0 else { throw Error.invalidSource }
            let asset = AVURLAsset(url: resolvedSegment.url)
            guard let sourceTrack = try await asset
                .loadTracks(withMediaType: .audio)
                .first else {
                throw Error.missingAudioTrack(index: index)
            }
            try Task.checkCancellation()
            let segmentDuration = CMTime(
                value: frameCount,
                timescale: timescale
            )
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: segmentDuration),
                of: sourceTrack,
                at: cursor
            )
            cursor = CMTimeAdd(cursor, segmentDuration)
        }

        return composition
    }

    private func removeObservers() {
        if let periodicTimeObserver = observers.periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
            observers.periodicTimeObserver = nil
        }
        if let endObserver = observers.endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            observers.endObserver = nil
        }
    }
}
