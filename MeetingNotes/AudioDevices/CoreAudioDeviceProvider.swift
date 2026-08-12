import CoreAudio
import Foundation

struct CoreAudioBufferListParser {
    static func channelCount(
        in bytes: [UInt8],
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        try bytes.withUnsafeBytes { buffer in
            guard let countOffset = MemoryLayout<AudioBufferList>.offset(
                of: \.mNumberBuffers
            ),
            let buffersOffset = MemoryLayout<AudioBufferList>.offset(
                of: \.mBuffers
            ),
            let channelCountOffset = MemoryLayout<AudioBuffer>.offset(
                of: \.mNumberChannels
            ) else {
                throw invalidDataError(
                    objectID: objectID,
                    selector: selector
                )
            }

            let uint32Size = MemoryLayout<UInt32>.size
            let (countEnd, countEndOverflow) =
                countOffset.addingReportingOverflow(uint32Size)
            let (channelsEndInBuffer, channelLayoutOverflow) =
                channelCountOffset.addingReportingOverflow(uint32Size)
            let bufferStride = MemoryLayout<AudioBuffer>.stride
            guard !countEndOverflow,
                  countEnd <= buffersOffset,
                  buffersOffset <= buffer.count,
                  !channelLayoutOverflow,
                  channelsEndInBuffer <= bufferStride else {
                throw invalidDataError(
                    objectID: objectID,
                    selector: selector
                )
            }

            let declaredCount = buffer.loadUnaligned(
                fromByteOffset: countOffset,
                as: UInt32.self
            )
            guard let bufferCount = Int(exactly: declaredCount) else {
                throw invalidDataError(
                    objectID: objectID,
                    selector: selector
                )
            }

            let (buffersSize, sizeOverflow) =
                bufferCount.multipliedReportingOverflow(by: bufferStride)
            let (requiredSize, requiredSizeOverflow) =
                buffersOffset.addingReportingOverflow(buffersSize)
            guard !sizeOverflow,
                  !requiredSizeOverflow,
                  requiredSize <= buffer.count else {
                throw invalidDataError(
                    objectID: objectID,
                    selector: selector
                )
            }

            var totalChannels: UInt32 = 0
            for index in 0..<bufferCount {
                let (relativeOffset, relativeOffsetOverflow) =
                    index.multipliedReportingOverflow(by: bufferStride)
                let (bufferOffset, bufferOffsetOverflow) =
                    buffersOffset.addingReportingOverflow(relativeOffset)
                let (channelCountByteOffset, channelOffsetOverflow) =
                    bufferOffset.addingReportingOverflow(channelCountOffset)
                let (channelsEnd, channelsEndOverflow) =
                    channelCountByteOffset.addingReportingOverflow(uint32Size)
                guard !relativeOffsetOverflow,
                      !bufferOffsetOverflow,
                      !channelOffsetOverflow,
                      !channelsEndOverflow,
                      channelsEnd <= requiredSize else {
                    throw invalidDataError(
                        objectID: objectID,
                        selector: selector
                    )
                }

                let channels = buffer.loadUnaligned(
                    fromByteOffset: channelCountByteOffset,
                    as: UInt32.self
                )
                let (newTotal, totalOverflow) =
                    totalChannels.addingReportingOverflow(channels)
                guard !totalOverflow else {
                    throw invalidDataError(
                        objectID: objectID,
                        selector: selector
                    )
                }
                totalChannels = newTotal
            }
            return totalChannels
        }
    }

    private static func invalidDataError(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> AudioDeviceCatalogError {
        .invalidCoreAudioPropertyData(
            objectID: objectID,
            selector: selector
        )
    }
}

enum CoreAudioDeviceProvider {
    static func inputDevices() throws -> [CoreAudioInputDevice] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = try readObjectIDs(
            objectID: systemObjectID,
            address: propertyAddress(
                selector: kAudioHardwarePropertyDevices
            )
        )
        let defaultInputID = try readUInt32(
            objectID: systemObjectID,
            address: propertyAddress(
                selector: kAudioHardwarePropertyDefaultInputDevice
            )
        )

        return try deviceIDs.compactMap { deviceID in
            let streamConfigurationAddress = propertyAddress(
                selector: kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeInput
            )
            let channels = try channelCount(
                objectID: deviceID,
                address: streamConfigurationAddress
            )
            guard channels > 0 else {
                return nil
            }

            let uid = try readString(
                objectID: deviceID,
                address: propertyAddress(
                    selector: kAudioDevicePropertyDeviceUID
                )
            )
            let name = try readString(
                objectID: deviceID,
                address: propertyAddress(
                    selector: kAudioObjectPropertyName
                )
            )
            let isAlive = try readUInt32(
                objectID: deviceID,
                address: propertyAddress(
                    selector: kAudioDevicePropertyDeviceIsAlive
                )
            ) != 0

            return CoreAudioInputDevice(
                deviceID: deviceID,
                uid: uid,
                name: name,
                isAlive: isAlive,
                inputChannelCount: channels,
                isSystemDefault: deviceID == defaultInputID
            )
        }
    }

    static func outputDevices() throws -> [AudioOutputDevice] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = try readObjectIDs(
            objectID: systemObjectID,
            address: propertyAddress(
                selector: kAudioHardwarePropertyDevices
            )
        )
        let defaultOutputID = try readUInt32(
            objectID: systemObjectID,
            address: propertyAddress(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
        )

        return try deviceIDs.compactMap { deviceID in
            let streamConfigurationAddress = propertyAddress(
                selector: kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeOutput
            )
            guard try channelCount(
                objectID: deviceID,
                address: streamConfigurationAddress
            ) > 0 else {
                return nil
            }

            let uid = try readString(
                objectID: deviceID,
                address: propertyAddress(
                    selector: kAudioDevicePropertyDeviceUID
                )
            )
            let name = try readString(
                objectID: deviceID,
                address: propertyAddress(
                    selector: kAudioObjectPropertyName
                )
            )
            let isAlive = try readUInt32(
                objectID: deviceID,
                address: propertyAddress(
                    selector: kAudioDevicePropertyDeviceIsAlive
                )
            ) != 0

            return AudioOutputDevice(
                id: uid,
                name: name,
                isConnected: isAlive,
                isSystemDefault: deviceID == defaultOutputID
            )
        }
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func propertyDataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var mutableAddress = address
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            objectID,
            &mutableAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw AudioDeviceCatalogError.coreAudioPropertySizeFailed(
                objectID: objectID,
                selector: address.mSelector,
                status: status
            )
        }
        return dataSize
    }

    private static func readObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        let dataSize = try propertyDataSize(
            objectID: objectID,
            address: address
        )
        let elementSize = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard dataSize % elementSize == 0 else {
            throw invalidDataError(objectID: objectID, address: address)
        }

        let count = Int(dataSize / elementSize)
        guard count > 0 else {
            return []
        }

        var values = [AudioObjectID](repeating: 0, count: count)
        var mutableAddress = address
        var mutableDataSize = dataSize
        try values.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw invalidDataError(
                    objectID: objectID,
                    address: address
                )
            }
            let status = AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &mutableDataSize,
                baseAddress
            )
            guard status == noErr else {
                throw readError(
                    objectID: objectID,
                    address: address,
                    status: status
                )
            }
        }
        guard mutableDataSize == dataSize else {
            throw invalidDataError(objectID: objectID, address: address)
        }
        return values
    }

    private static func readUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var mutableAddress = address
        let status = AudioObjectGetPropertyData(
            objectID,
            &mutableAddress,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            throw readError(
                objectID: objectID,
                address: address,
                status: status
            )
        }
        guard dataSize == UInt32(MemoryLayout<UInt32>.size) else {
            throw invalidDataError(objectID: objectID, address: address)
        }
        return value
    }

    private static func readString(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> String {
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(
            MemoryLayout<Unmanaged<CFString>?>.size
        )
        var mutableAddress = address
        let status = AudioObjectGetPropertyData(
            objectID,
            &mutableAddress,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            throw readError(
                objectID: objectID,
                address: address,
                status: status
            )
        }
        guard dataSize == UInt32(
            MemoryLayout<Unmanaged<CFString>?>.size
        ),
        let value else {
            throw invalidDataError(objectID: objectID, address: address)
        }
        return value.takeRetainedValue() as String
    }

    private static func channelCount(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        let dataSize = try propertyDataSize(
            objectID: objectID,
            address: address
        )
        guard let byteCount = Int(exactly: dataSize),
              byteCount > 0 else {
            throw invalidDataError(objectID: objectID, address: address)
        }

        var data = [UInt8](repeating: 0, count: byteCount)
        var mutableAddress = address
        var mutableDataSize = dataSize
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw invalidDataError(
                    objectID: objectID,
                    address: address
                )
            }
            let status = AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &mutableDataSize,
                baseAddress
            )
            guard status == noErr else {
                throw readError(
                    objectID: objectID,
                    address: address,
                    status: status
                )
            }
        }
        guard mutableDataSize <= dataSize,
              let returnedByteCount = Int(exactly: mutableDataSize) else {
            throw invalidDataError(objectID: objectID, address: address)
        }
        data.removeLast(data.count - returnedByteCount)

        return try CoreAudioBufferListParser.channelCount(
            in: data,
            objectID: objectID,
            selector: address.mSelector
        )
    }

    private static func readError(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        status: OSStatus
    ) -> AudioDeviceCatalogError {
        .coreAudioPropertyReadFailed(
            objectID: objectID,
            selector: address.mSelector,
            status: status
        )
    }

    private static func invalidDataError(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> AudioDeviceCatalogError {
        .invalidCoreAudioPropertyData(
            objectID: objectID,
            selector: address.mSelector
        )
    }
}
