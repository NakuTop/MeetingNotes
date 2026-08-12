import CoreAudio

struct AudioInputDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let manufacturer: String
    let isConnected: Bool
    let isSuspended: Bool
    let isInUseByAnotherApplication: Bool
    let isSystemDefault: Bool
    let avFoundationUniqueID: String?
    let coreAudioUID: String?
    let coreAudioDeviceID: AudioDeviceID?
    let inputChannelCount: UInt32
    let isAVFoundationAvailable: Bool
    let isCoreAudioAvailable: Bool

    init(
        id: String,
        name: String,
        manufacturer: String,
        isConnected: Bool,
        isSuspended: Bool,
        isInUseByAnotherApplication: Bool,
        isSystemDefault: Bool,
        avFoundationUniqueID: String? = nil,
        coreAudioUID: String? = nil,
        coreAudioDeviceID: AudioDeviceID? = nil,
        inputChannelCount: UInt32 = 0,
        isAVFoundationAvailable: Bool = false,
        isCoreAudioAvailable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isConnected = isConnected
        self.isSuspended = isSuspended
        self.isInUseByAnotherApplication = isInUseByAnotherApplication
        self.isSystemDefault = isSystemDefault
        self.avFoundationUniqueID = avFoundationUniqueID
        self.coreAudioUID = coreAudioUID
        self.coreAudioDeviceID = coreAudioDeviceID
        self.inputChannelCount = inputChannelCount
        self.isAVFoundationAvailable = isAVFoundationAvailable
        self.isCoreAudioAvailable = isCoreAudioAvailable
    }

    var isUsable: Bool {
        isConnected && !isSuspended
    }

    var isAVFoundationCapable: Bool {
        if isAVFoundationAvailable || isCoreAudioAvailable {
            return isAVFoundationAvailable
        }
        // Devices produced by older fakes/catalogs carry no explicit
        // backend flags; treat them as AVFoundation-capable.
        return true
    }

    var stableID: String {
        if let avFoundationUniqueID {
            return "avf:\(avFoundationUniqueID)"
        }
        if let coreAudioUID {
            return "ca:\(coreAudioUID)"
        }
        return "id:\(id)"
    }
}

struct AudioOutputDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let isConnected: Bool
    let isSystemDefault: Bool

    var isUsable: Bool {
        isConnected
    }
}

struct AudioDeviceSnapshot: Equatable, Sendable {
    let inputs: [AudioInputDevice]
    let outputs: [AudioOutputDevice]
}

enum ResolvedAudioDevice<Device: Equatable & Sendable>: Equatable, Sendable {
    case preferred(Device)
    case systemDefault(Device)
    case firstUsable(Device)
    case fallback(selected: Device, unavailablePreferredID: String)
    case unavailable
}
