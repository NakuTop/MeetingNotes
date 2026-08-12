import AudioToolbox
import AudioUnit
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

enum CoreAudioMicrophoneError: Error, Equatable, Sendable {
    case unitCreationFailed
    case enableIOFailed(OSStatus)
    case currentDeviceFailed(OSStatus)
    case streamFormatReadFailed(OSStatus)
    case streamFormatFailed(OSStatus)
    case maximumFramesPerSliceFailed(OSStatus)
    case inputCallbackFailed(OSStatus)
    case initializationFailed(OSStatus)
    case startFailed(OSStatus)
    case renderFailed(OSStatus)
    case deviceUnavailable
    case defaultDeviceUnavailable
    case invalidDeviceFormat
    case invalidFormat
    case bufferAllocationFailed
    case notConfigured
}

protocol CoreAudioMicrophoneAudioUnitAPI: Sendable {
    func makeHALOutputUnit() throws -> AudioUnit
    func enableIO(
        _ enabled: Bool,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        unit: AudioUnit
    ) throws
    func setCurrentDevice(
        _ deviceID: AudioDeviceID,
        unit: AudioUnit
    ) throws
    func getInputStreamFormat(
        unit: AudioUnit
    ) throws -> AudioStreamBasicDescription
    func setClientInputFormat(
        _ format: AudioStreamBasicDescription,
        unit: AudioUnit
    ) throws
    func getMaximumFramesPerSlice(
        unit: AudioUnit
    ) throws -> UInt32
    func setInputCallback(
        _ callback: AURenderCallbackStruct,
        unit: AudioUnit
    ) throws
    func initialize(unit: AudioUnit) throws
    func start(unit: AudioUnit) throws
    func stop(unit: AudioUnit)
    func uninitialize(unit: AudioUnit)
    func dispose(unit: AudioUnit)
    func render(
        unit: AudioUnit,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus
}

struct LiveCoreAudioMicrophoneAudioUnitAPI:
    CoreAudioMicrophoneAudioUnitAPI {
    func makeHALOutputUnit() throws -> AudioUnit {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(
            nil,
            &componentDescription
        ) else {
            throw CoreAudioMicrophoneError.unitCreationFailed
        }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw CoreAudioMicrophoneError.unitCreationFailed
        }
        return unit
    }

    func enableIO(
        _ enabled: Bool,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        unit: AudioUnit
    ) throws {
        var value: UInt32 = enabled ? 1 : 0
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            scope,
            element,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw CoreAudioMicrophoneError.enableIOFailed(status)
        }
    }

    func setCurrentDevice(
        _ deviceID: AudioDeviceID,
        unit: AudioUnit
    ) throws {
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CoreAudioMicrophoneError.currentDeviceFailed(status)
        }
    }

    func getInputStreamFormat(
        unit: AudioUnit
    ) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(
            MemoryLayout<AudioStreamBasicDescription>.size
        )
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &format,
            &dataSize
        )
        guard status == noErr else {
            throw CoreAudioMicrophoneError.streamFormatReadFailed(status)
        }
        return format
    }

    func setClientInputFormat(
        _ format: AudioStreamBasicDescription,
        unit: AudioUnit
    ) throws {
        var format = format
        let status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw CoreAudioMicrophoneError.streamFormatFailed(status)
        }
    }

    func getMaximumFramesPerSlice(
        unit: AudioUnit
    ) throws -> UInt32 {
        var maximumFrames: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            &dataSize
        )
        guard status == noErr else {
            throw CoreAudioMicrophoneError
                .maximumFramesPerSliceFailed(status)
        }
        return maximumFrames
    }

    func setInputCallback(
        _ callback: AURenderCallbackStruct,
        unit: AudioUnit
    ) throws {
        var callback = callback
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw CoreAudioMicrophoneError.inputCallbackFailed(status)
        }
    }

    func initialize(unit: AudioUnit) throws {
        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw CoreAudioMicrophoneError.initializationFailed(status)
        }
    }

    func start(unit: AudioUnit) throws {
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw CoreAudioMicrophoneError.startFailed(status)
        }
    }

    func stop(unit: AudioUnit) {
        AudioOutputUnitStop(unit)
    }

    func uninitialize(unit: AudioUnit) {
        AudioUnitUninitialize(unit)
    }

    func dispose(unit: AudioUnit) {
        AudioComponentInstanceDispose(unit)
    }

    func render(
        unit: AudioUnit,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        AudioUnitRender(
            unit,
            flags,
            timestamp,
            bus,
            frames,
            data
        )
    }
}

final class CoreAudioMicrophoneSlot: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var sampleTime: AVAudioFramePosition = 0
    var sampleRate: Double = 0

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class CoreAudioMicrophoneSPSCRing: @unchecked Sendable {
    let slots: [CoreAudioMicrophoneSlot]

    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(slots: [CoreAudioMicrophoneSlot]) {
        precondition(slots.count >= 2)
        self.slots = slots
    }

    var capacity: Int {
        slots.count - 1
    }

    func acquireWritableSlot() -> CoreAudioMicrophoneSlot? {
        let write = writeIndex.load(ordering: .relaxed)
        let next = (write + 1) % slots.count
        let read = readIndex.load(ordering: .acquiring)
        guard next != read else {
            return nil
        }
        return slots[write]
    }

    func publishWrittenSlot() {
        let write = writeIndex.load(ordering: .relaxed)
        let next = (write + 1) % slots.count
        writeIndex.store(next, ordering: .releasing)
    }

    func acquireReadableSlot() -> CoreAudioMicrophoneSlot? {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        guard read != write else {
            return nil
        }
        return slots[read]
    }

    func releaseReadSlot() {
        let read = readIndex.load(ordering: .relaxed)
        let next = (read + 1) % slots.count
        readIndex.store(next, ordering: .releasing)
    }
}

final class LiveCoreAudioMicrophoneSession:
    CoreAudioMicrophoneSessionManaging,
    @unchecked Sendable {
    private let api: any CoreAudioMicrophoneAudioUnitAPI
    private let ringSlotCount: Int
    private let ioQueue = DispatchQueue(
        label: "MeetingNotes.CoreAudioMicrophone.IO"
    )
    private let drainQueue = DispatchQueue(
        label: "MeetingNotes.CoreAudioMicrophone.Drain"
    )
    private let drainSource: DispatchSourceUserDataAdd
    private let handlerLock = NSLock()
    private let acceptingCallback = Atomic<Bool>(false)
    private let pendingRenderError = Atomic<Int32>(0)
    private let droppedInputFrameCount = Atomic<UInt64>(0)

    private var eventHandler:
        (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    private var audioUnit: AudioUnit?
    private var ring: CoreAudioMicrophoneSPSCRing?
    private var scratchBuffer: AVAudioPCMBuffer?
    private var isRunning = false
    private var clientSampleRate: Double = 0
    private var maximumFrameCapacity: AVAudioFrameCount = 8_192
    private var nextSampleTime: AVAudioFramePosition = 0

    init(
        api: any CoreAudioMicrophoneAudioUnitAPI =
            LiveCoreAudioMicrophoneAudioUnitAPI(),
        ringSlotCount: Int = 9
    ) {
        self.api = api
        self.ringSlotCount = max(2, ringSlotCount)
        drainSource = DispatchSource.makeUserDataAddSource(
            queue: drainQueue
        )
        drainSource.setEventHandler { [weak self] in
            self?.drainPublishedFrames()
        }
        drainSource.resume()
    }

    func configure(
        deviceID: AudioDeviceID?,
        eventHandler:
            @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try configureOnQueue(
                        deviceID: deviceID,
                        eventHandler: eventHandler
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try setRunning(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func pause() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                acceptingCallback.store(false, ordering: .releasing)
                if isRunning, let unit = audioUnit {
                    api.stop(unit: unit)
                    isRunning = false
                }
                drainQueue.sync {
                    self.drainPublishedFrames()
                }
                continuation.resume()
            }
        }
    }

    func resume() async throws {
        try await start()
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                stopOnQueue()
                continuation.resume()
            }
        }
    }

    internal var testDroppedInputFrameCount: UInt64 {
        droppedInputFrameCount.load(ordering: .relaxed)
    }

    internal func setDrainSuspendedForTesting(_ suspended: Bool) {
        if suspended {
            drainSource.suspend()
        } else {
            drainSource.resume()
        }
    }

    private func configureOnQueue(
        deviceID: AudioDeviceID?,
        eventHandler:
            @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void
    ) throws {
        stopOnQueue()

        let unit = try api.makeHALOutputUnit()
        do {
            try api.enableIO(
                true,
                scope: kAudioUnitScope_Input,
                element: 1,
                unit: unit
            )
            try api.enableIO(
                false,
                scope: kAudioUnitScope_Output,
                element: 0,
                unit: unit
            )
            let resolvedDeviceID =
                try deviceID ?? Self.defaultInputDeviceID()
            try api.setCurrentDevice(
                resolvedDeviceID,
                unit: unit
            )

            let deviceFormat = try api.getInputStreamFormat(unit: unit)
            guard deviceFormat.mSampleRate.isFinite,
                  deviceFormat.mSampleRate > 0,
                  deviceFormat.mChannelsPerFrame > 0 else {
                throw CoreAudioMicrophoneError.invalidDeviceFormat
            }

            let clientFormat = AudioStreamBasicDescription(
                mSampleRate: deviceFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags:
                    kAudioFormatFlagIsFloat
                    | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
                mBitsPerChannel:
                    UInt32(MemoryLayout<Float>.size * 8),
                mReserved: 0
            )
            try api.setClientInputFormat(
                clientFormat,
                unit: unit
            )

            let reportedMaximumFrames =
                try api.getMaximumFramesPerSlice(unit: unit)
            let frameCapacity = max(
                reportedMaximumFrames,
                8_192
            )
            guard let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: deviceFormat.mSampleRate,
                channels: AVAudioChannelCount(
                    deviceFormat.mChannelsPerFrame
                ),
                interleaved: false
            ) else {
                throw CoreAudioMicrophoneError.invalidFormat
            }
            let ring = try Self.makeRing(
                slotCount: ringSlotCount,
                format: pcmFormat,
                frameCapacity: frameCapacity
            )
            let scratch = try Self.makeBuffer(
                format: pcmFormat,
                frameCapacity: frameCapacity
            )

            let callback = AURenderCallbackStruct(
                inputProc: Self.inputCallbackProc,
                inputProcRefCon:
                    Unmanaged.passUnretained(self).toOpaque()
            )
            try api.setInputCallback(callback, unit: unit)
            try api.initialize(unit: unit)

            audioUnit = unit
            self.ring = ring
            scratchBuffer = scratch
            clientSampleRate = deviceFormat.mSampleRate
            maximumFrameCapacity = frameCapacity
            nextSampleTime = 0
            pendingRenderError.store(0, ordering: .relaxed)
            droppedInputFrameCount.store(0, ordering: .relaxed)
            setEventHandler(eventHandler)
        } catch {
            api.dispose(unit: unit)
            throw error
        }
    }

    private func setRunning(_ shouldRun: Bool) throws {
        guard let unit = audioUnit else {
            throw CoreAudioMicrophoneError.notConfigured
        }
        if shouldRun {
            guard !isRunning else { return }
            acceptingCallback.store(true, ordering: .releasing)
            do {
                try api.start(unit: unit)
                isRunning = true
            } catch {
                acceptingCallback.store(false, ordering: .releasing)
                throw error
            }
        } else {
            if isRunning {
                acceptingCallback.store(false, ordering: .releasing)
                api.stop(unit: unit)
                isRunning = false
            }
        }
    }

    private func stopOnQueue() {
        acceptingCallback.store(false, ordering: .releasing)
        if isRunning, let unit = audioUnit {
            api.stop(unit: unit)
            isRunning = false
        }
        if let unit = audioUnit {
            api.uninitialize(unit: unit)
        }
        // Non-realtime barrier: the drain queue must finish using the
        // current ring before we dispose the unit and release slots.
        drainQueue.sync {
            self.drainPublishedFrames()
        }
        if let unit = audioUnit {
            api.dispose(unit: unit)
            audioUnit = nil
        }
        ring = nil
        scratchBuffer = nil
        nextSampleTime = 0
        setEventHandler(nil)
    }

    private static let inputCallbackProc: AURenderCallback = {
        refCon, flags, timestamp, bus, frames, _ in
        let session = Unmanaged<LiveCoreAudioMicrophoneSession>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        return session.handleInputCallback(
            flags: flags,
            timestamp: timestamp,
            bus: bus,
            frames: frames
        )
    }

    private func handleInputCallback(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard acceptingCallback.load(ordering: .acquiring) else {
            return noErr
        }
        guard let unit = audioUnit,
              let ring else {
            return noErr
        }
        if frames > maximumFrameCapacity {
            pendingRenderError.store(
                Int32(kAudio_ParamError),
                ordering: .relaxed
            )
            drainSource.add(data: 1)
            return kAudio_ParamError
        }

        if let slot = ring.acquireWritableSlot() {
            let status = api.render(
                unit: unit,
                flags: flags,
                timestamp: timestamp,
                bus: bus,
                frames: frames,
                data: slot.buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                pendingRenderError.store(
                    status,
                    ordering: .relaxed
                )
                drainSource.add(data: 1)
                return status
            }
            slot.buffer.frameLength = frames
            slot.sampleTime = nextSampleTime
            slot.sampleRate = clientSampleRate
            nextSampleTime += AVAudioFramePosition(frames)
            ring.publishWrittenSlot()
            drainSource.add(data: 1)
            return noErr
        }

        guard let scratch = scratchBuffer else {
            return noErr
        }
        let status = api.render(
            unit: unit,
            flags: flags,
            timestamp: timestamp,
            bus: bus,
            frames: frames,
            data: scratch.mutableAudioBufferList
        )
        guard status == noErr else {
            pendingRenderError.store(
                status,
                ordering: .relaxed
            )
            drainSource.add(data: 1)
            return status
        }
        droppedInputFrameCount.wrappingAdd(
            UInt64(frames),
            ordering: .relaxed
        )
        nextSampleTime += AVAudioFramePosition(frames)
        drainSource.add(data: 1)
        return noErr
    }

    private func drainPublishedFrames() {
        guard let ring else { return }
        while let slot = ring.acquireReadableSlot() {
            do {
                let copy = try deepCopyBuffer(from: slot.buffer)
                let sampleTime = slot.sampleTime
                let sampleRate = slot.sampleRate
                ring.releaseReadSlot()
                let handler = readEventHandler()
                handler?(.buffer(copy, sampleTime, sampleRate))
            } catch {
                ring.releaseReadSlot()
                let handler = readEventHandler()
                handler?(.failure(error))
                return
            }
        }

        let dropped = droppedInputFrameCount.exchange(
            0,
            ordering: .acquiring
        )
        if dropped > 0 {
            MicrophoneDiagnosticLogger.coreAudioInputOverflow(
                droppedFrameCount: dropped
            )
        }

        let renderStatus = pendingRenderError.exchange(
            0,
            ordering: .acquiring
        )
        if renderStatus != 0 {
            let handler = readEventHandler()
            handler?(
                .failure(
                    CoreAudioMicrophoneError
                        .renderFailed(renderStatus)
                )
            )
        }
    }

    private func deepCopyBuffer(
        from source: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer {
        let frameLength = source.frameLength
        let format = source.format
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            throw CoreAudioMicrophoneError.bufferAllocationFailed
        }
        copy.frameLength = frameLength

        let channelCount = Int(format.channelCount)
        guard let sourceChannels = source.floatChannelData,
              let destinationChannels = copy.floatChannelData else {
            throw CoreAudioMicrophoneError.bufferAllocationFailed
        }
        for channel in 0..<channelCount {
            let sourceChannel = sourceChannels[channel]
            let destinationChannel = destinationChannels[channel]
            destinationChannel.update(
                from: sourceChannel,
                count: Int(frameLength)
            )
        }
        return copy
    }

    private func readEventHandler()
        -> (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)? {
        handlerLock.lock()
        let handler = eventHandler
        handlerLock.unlock()
        return handler
    }

    private func setEventHandler(
        _ handler:
            (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    ) {
        handlerLock.lock()
        eventHandler = handler
        handlerLock.unlock()
    }

    private static func makeRing(
        slotCount: Int,
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount
    ) throws -> CoreAudioMicrophoneSPSCRing {
        let slots = try (0..<slotCount).map { _ in
            try makeSlot(
                format: format,
                frameCapacity: frameCapacity
            )
        }
        return CoreAudioMicrophoneSPSCRing(slots: slots)
    }

    private static func makeSlot(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount
    ) throws -> CoreAudioMicrophoneSlot {
        CoreAudioMicrophoneSlot(
            buffer: try makeBuffer(
                format: format,
                frameCapacity: frameCapacity
            )
        )
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            throw CoreAudioMicrophoneError.bufferAllocationFailed
        }
        return buffer
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            throw CoreAudioMicrophoneError.defaultDeviceUnavailable
        }
        return deviceID
    }
}
