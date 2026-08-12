import AudioToolbox
import AudioUnit
import AVFoundation
import CoreAudio
import Foundation

enum CoreAudioMicrophoneError: Error, Equatable, Sendable {
    case unitCreationFailed
    case enableIOFailed(OSStatus)
    case currentDeviceFailed(OSStatus)
    case streamFormatFailed(OSStatus)
    case renderCallbackFailed(OSStatus)
    case initializationFailed(OSStatus)
    case startFailed(OSStatus)
    case deviceUnavailable
    case defaultDeviceUnavailable
    case invalidFormat
    case notConfigured
}

final class LiveCoreAudioMicrophoneSession:
    CoreAudioMicrophoneSessionManaging,
    @unchecked Sendable {
    private let ioQueue = DispatchQueue(
        label: "MeetingNotes.CoreAudioMicrophone.IO"
    )
    private let drainQueue = DispatchQueue(
        label: "MeetingNotes.CoreAudioMicrophone.Drain"
    )
    private let handlerLock = NSLock()
    private let slotLock = NSLock()
    private var eventHandler:
        (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    private var audioUnit: AudioUnit?
    private var isRunning = false
    private var currentSampleRate: Double = 48_000
    private var slots: [CoreAudioMicrophoneSlot] = []

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
                try? setRunning(false)
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

    private func configureOnQueue(
        deviceID: AudioDeviceID?,
        eventHandler:
            @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void
    ) throws {
        stopOnQueue()

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
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw CoreAudioMicrophoneError.unitCreationFailed
        }

        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            dispose(unit)
            throw CoreAudioMicrophoneError.enableIOFailed(status)
        }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            dispose(unit)
            throw CoreAudioMicrophoneError.enableIOFailed(status)
        }

        let resolvedDeviceID = try resolveDeviceID(
            deviceID ?? Self.defaultInputDeviceID()
        )
        var deviceIDValue = resolvedDeviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDValue,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            dispose(unit)
            throw CoreAudioMicrophoneError.currentDeviceFailed(status)
        }

        let sampleRate =
            try Self.nominalSampleRate(for: resolvedDeviceID) ?? 48_000
        currentSampleRate = sampleRate
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            dispose(unit)
            throw CoreAudioMicrophoneError.streamFormatFailed(status)
        }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            dispose(unit)
            throw CoreAudioMicrophoneError.invalidFormat
        }
        prepareSlots(format: pcmFormat)

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frames, data in
                let session = Unmanaged<LiveCoreAudioMicrophoneSession>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()
                return session.handleInput(
                    flags: flags,
                    timestamp: timestamp,
                    bus: bus,
                    frames: frames,
                    data: data
                )
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            1,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            dispose(unit)
            throw CoreAudioMicrophoneError.renderCallbackFailed(status)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            dispose(unit)
            throw CoreAudioMicrophoneError.initializationFailed(status)
        }

        audioUnit = unit
        setEventHandler(eventHandler)
    }

    private func setRunning(_ shouldRun: Bool) throws {
        guard let audioUnit else {
            throw CoreAudioMicrophoneError.notConfigured
        }
        if shouldRun {
            guard !isRunning else { return }
            let status = AudioOutputUnitStart(audioUnit)
            guard status == noErr else {
                throw CoreAudioMicrophoneError.startFailed(status)
            }
            isRunning = true
        } else {
            if isRunning {
                AudioOutputUnitStop(audioUnit)
                isRunning = false
            }
        }
    }

    private func stopOnQueue() {
        if let audioUnit {
            if isRunning {
                AudioOutputUnitStop(audioUnit)
                isRunning = false
            }
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
        slots.removeAll()
        setEventHandler(nil)
    }

    private func handleInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let audioUnit, let data else { return noErr }
        let status = AudioUnitRender(
            audioUnit,
            flags,
            timestamp,
            bus,
            frames,
            data
        )
        guard status == noErr else { return status }
        copyInput(
            data: data,
            frames: frames,
            sampleTime: AVAudioFramePosition(
                timestamp.pointee.mSampleTime
            ),
            sampleRate: currentSampleRate
        )
        return noErr
    }

    private func copyInput(
        data: UnsafeMutablePointer<AudioBufferList>,
        frames: UInt32,
        sampleTime: AVAudioFramePosition,
        sampleRate: Double
    ) {
        guard let slot = takeFreeSlot() else {
            return
        }
        let bufferList = data.pointee
        guard bufferList.mNumberBuffers > 0,
              let source = bufferList.mBuffers.mData else {
            markFree(slot)
            return
        }
        let sourceFrameCount = min(
            Int(frames),
            Int(slot.buffer.frameCapacity)
        )
        let sourceFloats = source.assumingMemoryBound(to: Float.self)
        if let destination = slot.buffer.floatChannelData?.pointee {
            destination.update(
                from: sourceFloats,
                count: sourceFrameCount
            )
        }
        slot.buffer.frameLength = AVAudioFrameCount(sourceFrameCount)
        slot.sampleTime = sampleTime
        slot.sampleRate = sampleRate

        drainQueue.async { [weak self] in
            self?.drainSlots()
        }
    }

    private func drainSlots() {
        while let slot = takeNextOccupiedSlot() {
            let copy = copyBuffer(from: slot)
            markFree(slot)
            let handler: (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
            handlerLock.lock()
            handler = eventHandler
            handlerLock.unlock()
            handler?(
                .buffer(
                    copy,
                    slot.sampleTime,
                    slot.sampleRate
                )
            )
        }
    }

    private func takeFreeSlot() -> CoreAudioMicrophoneSlot? {
        slotLock.lock()
        defer { slotLock.unlock() }
        guard let slot = slots.first(where: { !$0.isOccupied }) else {
            return nil
        }
        slot.isOccupied = true
        return slot
    }

    private func takeNextOccupiedSlot() -> CoreAudioMicrophoneSlot? {
        slotLock.lock()
        defer { slotLock.unlock() }
        guard let slot = slots.first(where: { $0.isOccupied }) else {
            return nil
        }
        slot.isOccupied = false
        return slot
    }

    private func markFree(_ slot: CoreAudioMicrophoneSlot) {
        slotLock.lock()
        slot.isOccupied = false
        slotLock.unlock()
    }

    private func copyBuffer(
        from slot: CoreAudioMicrophoneSlot
    ) -> AVAudioPCMBuffer {
        let frameLength = slot.buffer.frameLength
        let format = slot.buffer.format
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            return slot.buffer
        }
        copy.frameLength = frameLength
        if let source = slot.buffer.floatChannelData?.pointee,
           let destination = copy.floatChannelData?.pointee {
            destination.update(
                from: source,
                count: Int(frameLength)
            )
        }
        return copy
    }

    private func prepareSlots(format: AVAudioFormat) {
        slots = (0..<8).compactMap { _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 8_192
            ) else {
                return nil
            }
            return CoreAudioMicrophoneSlot(buffer: buffer)
        }
    }

    private func setEventHandler(
        _ handler:
            (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    ) {
        handlerLock.lock()
        eventHandler = handler
        handlerLock.unlock()
    }

    private func resolveDeviceID(
        _ deviceID: AudioDeviceID
    ) throws -> AudioDeviceID {
        var address = Self.propertyAddress(
            selector: kAudioDevicePropertyDeviceIsAlive
        )
        var alive: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &alive
        )
        guard status == noErr, alive != 0 else {
            throw CoreAudioMicrophoneError.deviceUnavailable
        }
        return deviceID
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDefaultInputDevice
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

    private static func nominalSampleRate(
        for deviceID: AudioDeviceID
    ) throws -> Double? {
        var address = propertyAddress(
            selector: kAudioDevicePropertyNominalSampleRate
        )
        var sampleRate: Double = 0
        var dataSize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &sampleRate
        )
        guard status == noErr, sampleRate > 0 else {
            return nil
        }
        return sampleRate
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func dispose(_ unit: AudioUnit) {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

private final class CoreAudioMicrophoneSlot: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var sampleTime: AVAudioFramePosition = 0
    var sampleRate: Double = 0
    var isOccupied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
