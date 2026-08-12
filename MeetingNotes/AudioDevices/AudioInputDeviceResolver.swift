import CoreAudio
import Foundation

enum MicrophoneCaptureBackend: String, Codable, Sendable, Equatable, Hashable {
    case avFoundation
    case coreAudioFallback
}

struct MicrophoneCaptureAttemptKey: Hashable, Sendable {
    let physicalStableID: String
    let backend: MicrophoneCaptureBackend
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

    var attemptKey: MicrophoneCaptureAttemptKey {
        MicrophoneCaptureAttemptKey(
            physicalStableID: device.stableID,
            backend: plan.backend
        )
    }
}

enum AudioInputDeviceResolver {
    static func resolveCapture(
        preferred: PreferredAudioInput,
        inputs: [AudioInputDevice],
        excludingAttempts:
            Set<MicrophoneCaptureAttemptKey> = [],
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
        let backendOrder = Self.backendOrder(for: preferred)

        // 1. User's previously selected device, when still present and usable.
        if let preferredDevice = usable.first(where: {
            matches(preferred: preferred, device: $0)
        }) {
            if let resolution = capture(
                for: preferredDevice,
                backendOrder: backendOrder,
                excludingAttempts: excludingAttempts,
                kind: .preferred
            ) {
                return resolution
            }
        }

        // 2. AVFoundation system default.
        if let avFoundationDefault = usable.first(where: {
            $0.isAVFoundationCapable && $0.isSystemDefault
        }) {
            if let resolution = capture(
                for: avFoundationDefault,
                backendOrder: backendOrder,
                excludingAttempts: excludingAttempts,
                kind: fallbackKind(
                    hasPreferredID: preferred.hasAnyIdentifier,
                    preferred: preferred,
                    defaultKind: .systemDefault
                )
            ) {
                return resolution
            }
        }

        // 3. Core Audio system default mapped to its AVFoundation device.
        if let coreAudioDefault = usable.first(where: {
            $0.isCoreAudioAvailable && $0.isSystemDefault
        }), let avFoundationCounterpart = usable.first(where: {
            $0.isAVFoundationCapable
                && $0.coreAudioUID == coreAudioDefault.coreAudioUID
        }) {
            if let resolution = capture(
                for: avFoundationCounterpart,
                backendOrder: backendOrder,
                excludingAttempts: excludingAttempts,
                kind: fallbackKind(
                    hasPreferredID: preferred.hasAnyIdentifier,
                    preferred: preferred,
                    defaultKind: .systemDefault
                )
            ) {
                return resolution
            }
        }

        // 4. First valid AVFoundation input.
        if let firstAVFoundation = usable.first(where: {
            $0.isAVFoundationCapable
        }) {
            if let resolution = capture(
                for: firstAVFoundation,
                backendOrder: backendOrder,
                excludingAttempts: excludingAttempts,
                kind: fallbackKind(
                    hasPreferredID: preferred.hasAnyIdentifier,
                    preferred: preferred,
                    defaultKind: .firstUsable
                )
            ) {
                return resolution
            }
        }

        // 5. Core Audio fallback capture.
        let hasPreferredID = preferred.hasAnyIdentifier
        if let coreAudioDefault = usable.first(where: {
            $0.isCoreAudioAvailable && $0.isSystemDefault
        }) {
            if let resolution = capture(
                for: coreAudioDefault,
                backendOrder: backendOrder,
                excludingAttempts: excludingAttempts,
                kind: fallbackKind(
                    hasPreferredID: hasPreferredID,
                    preferred: preferred,
                    defaultKind: .systemDefault
                )
            ) {
                return resolution
            }
        }
        if let firstCoreAudio = usable.first(where: {
            $0.isCoreAudioAvailable
        }) {
            if let resolution = capture(
                for: firstCoreAudio,
                backendOrder: backendOrder,
                excludingAttempts: excludingAttempts,
                kind: fallbackKind(
                    hasPreferredID: hasPreferredID,
                    preferred: preferred,
                    defaultKind: .firstUsable
                )
            ) {
                return resolution
            }
        }

        return nil
    }

    private static func backendOrder(
        for preferred: PreferredAudioInput
    ) -> [MicrophoneCaptureBackend] {
        switch preferred.backend {
        case .coreAudio:
            return [.coreAudioFallback, .avFoundation]
        case .automatic, .avFoundation:
            return [.avFoundation, .coreAudioFallback]
        }
    }

    private static func capture(
        for device: AudioInputDevice,
        backendOrder: [MicrophoneCaptureBackend],
        excludingAttempts: Set<MicrophoneCaptureAttemptKey>,
        kind: MicrophoneResolutionKind
    ) -> ResolvedMicrophoneCapture? {
        for backend in backendOrder {
            let attemptKey = MicrophoneCaptureAttemptKey(
                physicalStableID: device.stableID,
                backend: backend
            )
            if excludingAttempts.contains(attemptKey) {
                continue
            }
            switch backend {
            case .avFoundation:
                if device.isAVFoundationCapable {
                    return ResolvedMicrophoneCapture(
                        plan: .avFoundation(
                            deviceID:
                                device.avFoundationUniqueID ?? device.id
                        ),
                        kind: kind,
                        device: device
                    )
                }
            case .coreAudioFallback:
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
            }
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
