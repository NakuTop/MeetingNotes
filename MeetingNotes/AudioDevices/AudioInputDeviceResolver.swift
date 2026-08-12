import CoreAudio
import Foundation

enum MicrophoneCaptureBackend: String, Codable, Sendable, Equatable {
    case avFoundation
    case coreAudioFallback
}

enum MicrophoneCapturePlan: Equatable, Sendable {
    case avFoundation(deviceID: String?)
    case coreAudio(deviceID: AudioDeviceID, uid: String)

    var backend: MicrophoneCaptureBackend {
        switch self {
        case .avFoundation:
            return .avFoundation
        case .coreAudio:
            return .coreAudioFallback
        }
    }
}

enum MicrophoneResolutionKind: Equatable, Sendable {
    case preferred
    case systemDefault
    case firstUsable
    case fallback(unavailablePreferredID: String)
}

struct ResolvedMicrophoneCapture: Equatable, Sendable {
    let plan: MicrophoneCapturePlan
    let kind: MicrophoneResolutionKind
    let device: AudioInputDevice

    var usesCoreAudioFallback: Bool {
        if case .coreAudio = plan {
            return true
        }
        return false
    }
}

enum AudioInputDeviceResolver {
    static func resolveCapture(
        preferred: PreferredAudioInput,
        inputs: [AudioInputDevice],
        excludingDeviceIDs: Set<String> = [],
        excludingBackend: MicrophoneCaptureBackend? = nil
    ) -> ResolvedMicrophoneCapture? {
        let usable = inputs.filter { device in
            guard device.isUsable else { return false }
            if let excludingBackend {
                switch excludingBackend {
                case .avFoundation:
                    if device.isAVFoundationCapable { return false }
                case .coreAudioFallback:
                    if device.isCoreAudioAvailable { return false }
                }
            }
            return !matches(excluded: excludingDeviceIDs, device: device)
        }

        // 1. User's previously selected device, when still present and usable.
        if let preferredDevice = usable.first(where: {
            matches(preferred: preferred, device: $0)
        }) {
            return capture(for: preferredDevice, kind: .preferred)
        }

        // 2. AVFoundation system default.
        if let avFoundationDefault = usable.first(where: {
            $0.isAVFoundationCapable && $0.isSystemDefault
        }) {
            return capture(
                for: avFoundationDefault,
                kind: fallbackKind(
                    hasPreferredID: preferred.hasAnyIdentifier,
                    preferred: preferred,
                    defaultKind: .systemDefault
                )
            )
        }

        // 3. Core Audio system default mapped to its AVFoundation device.
        if let coreAudioDefault = usable.first(where: {
            $0.isCoreAudioAvailable && $0.isSystemDefault
        }), let avFoundationCounterpart = usable.first(where: {
            $0.isAVFoundationAvailable
                && $0.coreAudioUID == coreAudioDefault.coreAudioUID
        }) {
            return capture(
                for: avFoundationCounterpart,
                kind: fallbackKind(
                    hasPreferredID: preferred.hasAnyIdentifier,
                    preferred: preferred,
                    defaultKind: .systemDefault
                )
            )
        }

        // 4. First valid AVFoundation input.
        if let firstAVFoundation = usable.first(where: {
            $0.isAVFoundationCapable
        }) {
            return capture(
                for: firstAVFoundation,
                kind: fallbackKind(
                    hasPreferredID: preferred.hasAnyIdentifier,
                    preferred: preferred,
                    defaultKind: .firstUsable
                )
            )
        }

        // 5. Core Audio fallback capture.
        let hasPreferredID = preferred.hasAnyIdentifier
        if let coreAudioDefault = usable.first(where: {
            $0.isCoreAudioAvailable && $0.isSystemDefault
        }) {
            return capture(
                for: coreAudioDefault,
                kind: fallbackKind(
                    hasPreferredID: hasPreferredID,
                    preferred: preferred,
                    defaultKind: .systemDefault
                )
            )
        }
        if let firstCoreAudio = usable.first(where: {
            $0.isCoreAudioAvailable
        }) {
            return capture(
                for: firstCoreAudio,
                kind: fallbackKind(
                    hasPreferredID: hasPreferredID,
                    preferred: preferred,
                    defaultKind: .firstUsable
                )
            )
        }

        return nil
    }

    private static func capture(
        for device: AudioInputDevice,
        kind: MicrophoneResolutionKind
    ) -> ResolvedMicrophoneCapture? {
        if device.isAVFoundationCapable {
            return ResolvedMicrophoneCapture(
                plan: .avFoundation(
                    deviceID: device.avFoundationUniqueID ?? device.id
                ),
                kind: kind,
                device: device
            )
        }
        if device.isCoreAudioAvailable,
           let deviceID = device.coreAudioDeviceID,
           let uid = device.coreAudioUID {
            return ResolvedMicrophoneCapture(
                plan: .coreAudio(
                    deviceID: deviceID,
                    uid: uid
                ),
                kind: kind,
                device: device
            )
        }
        return nil
    }

    private static func matches(
        preferred: PreferredAudioInput,
        device: AudioInputDevice
    ) -> Bool {
        if let stableID = preferred.stableID,
           !stableID.isEmpty,
           device.stableID == stableID {
            return true
        }
        if let legacyID = preferred.legacyAVFoundationID,
           !legacyID.isEmpty,
           device.avFoundationUniqueID == legacyID
            || device.id == legacyID {
            return true
        }
        if let coreAudioUID = preferred.coreAudioUID,
           !coreAudioUID.isEmpty,
           device.coreAudioUID == coreAudioUID {
            return true
        }
        if let stableID = preferred.stableID,
           !stableID.isEmpty,
           device.id == stableID || device.coreAudioUID == stableID {
            return true
        }
        return false
    }

    private static func matches(
        excluded: Set<String>,
        device: AudioInputDevice
    ) -> Bool {
        guard !excluded.isEmpty else { return false }
        let avFoundationExcluded =
            excluded.contains(device.stableID)
            || excluded.contains(device.id)
            || excluded.contains(device.avFoundationUniqueID ?? "")
        let coreAudioExcluded =
            excluded.contains(device.coreAudioUID ?? "")

        if device.isAVFoundationAvailable
            && device.isCoreAudioAvailable {
            // A merged device remains usable through its other backend
            // until both backend identifiers are excluded.
            return avFoundationExcluded && coreAudioExcluded
        }
        if device.isAVFoundationAvailable {
            return avFoundationExcluded
        }
        if device.isCoreAudioAvailable {
            return coreAudioExcluded
        }
        return false
    }

    private static func fallbackKind(
        hasPreferredID: Bool,
        preferred: PreferredAudioInput,
        defaultKind: MicrophoneResolutionKind
    ) -> MicrophoneResolutionKind {
        guard hasPreferredID else {
            return defaultKind
        }
        return .fallback(
            unavailablePreferredID:
                preferred.legacyAVFoundationID
                ?? preferred.coreAudioUID
                ?? preferred.stableID
                ?? "unknown"
        )
    }
}

extension PreferredAudioInput {
    fileprivate var hasAnyIdentifier: Bool {
        !(stableID?.isEmpty ?? true)
            || !(legacyAVFoundationID?.isEmpty ?? true)
            || !(coreAudioUID?.isEmpty ?? true)
    }
}
