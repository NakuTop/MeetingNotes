struct AudioInputDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let manufacturer: String
    let isConnected: Bool
    let isSuspended: Bool
    let isInUseByAnotherApplication: Bool
    let isSystemDefault: Bool

    var isUsable: Bool {
        isConnected && !isSuspended
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
