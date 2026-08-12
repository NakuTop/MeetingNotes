import CoreAudio
import Foundation

enum AudioInputDiscoveryBackend: String, Hashable, Equatable, Sendable {
    case avFoundation
    case coreAudio
}

enum AudioInputDiscoveryError: Error, Equatable, Sendable {
    case allBackendsFailed
}

struct AVFoundationInputDevice: Equatable, Sendable, Identifiable {
    let uniqueID: String
    let name: String
    let manufacturer: String
    let isConnected: Bool
    let isSuspended: Bool
    let isInUseByAnotherApplication: Bool
    let isSystemDefault: Bool

    var id: String {
        uniqueID
    }

    var isUsable: Bool {
        isConnected && !isSuspended
    }
}

struct CoreAudioInputDevice: Equatable, Sendable, Identifiable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let isAlive: Bool
    let inputChannelCount: UInt32
    let isSystemDefault: Bool

    var id: String {
        uid
    }

    var isUsable: Bool {
        isAlive && inputChannelCount > 0
    }
}

struct AudioInputDiscoverySnapshot: Equatable, Sendable {
    let avFoundationInputs: [AVFoundationInputDevice]
    let coreAudioInputs: [CoreAudioInputDevice]
    let failedBackends: Set<AudioInputDiscoveryBackend>

    init(
        avFoundationInputs: [AVFoundationInputDevice] = [],
        coreAudioInputs: [CoreAudioInputDevice] = [],
        failedBackends: Set<AudioInputDiscoveryBackend> = []
    ) {
        self.avFoundationInputs = avFoundationInputs
        self.coreAudioInputs = coreAudioInputs
        self.failedBackends = failedBackends
    }

    var avFoundationInputCount: Int {
        avFoundationInputs.count
    }

    var coreAudioInputCount: Int {
        coreAudioInputs.count
    }

    var avFoundationDefaultAvailable: Bool {
        avFoundationInputs.contains { $0.isSystemDefault && $0.isUsable }
    }

    var coreAudioDefaultAvailable: Bool {
        coreAudioInputs.contains { $0.isSystemDefault && $0.isUsable }
    }

    var avFoundationDiscoveryFailed: Bool {
        failedBackends.contains(.avFoundation)
    }

    var coreAudioDiscoveryFailed: Bool {
        failedBackends.contains(.coreAudio)
    }
}
