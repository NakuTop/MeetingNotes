import AVFoundation
import Foundation

protocol AVFoundationInputDeviceProviding: Sendable {
    func inputs() throws -> [AVFoundationInputDevice]
}

protocol CoreAudioInputDeviceProviding: Sendable {
    func inputs() throws -> [CoreAudioInputDevice]
}

protocol AudioInputDeviceProviding: Sendable {
    func discover() throws -> AudioInputDiscoverySnapshot
}

struct LiveAVFoundationInputDeviceProvider:
    AVFoundationInputDeviceProviding {
    func inputs() throws -> [AVFoundationInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.map { device in
            AVFoundationInputDevice(
                uniqueID: device.uniqueID,
                name: device.localizedName,
                manufacturer: device.manufacturer,
                isConnected: device.isConnected,
                isSuspended: device.isSuspended,
                isInUseByAnotherApplication:
                    device.isInUseByAnotherApplication,
                isSystemDefault: device.uniqueID == defaultID
            )
        }
    }
}

struct LiveCoreAudioInputDeviceProvider: CoreAudioInputDeviceProviding {
    func inputs() throws -> [CoreAudioInputDevice] {
        try CoreAudioDeviceProvider.inputDevices()
    }
}

struct LiveAudioInputDeviceProvider: AudioInputDeviceProviding {
    private let avFoundationProvider: any AVFoundationInputDeviceProviding
    private let coreAudioProvider: any CoreAudioInputDeviceProviding

    init(
        avFoundationProvider: any AVFoundationInputDeviceProviding =
            LiveAVFoundationInputDeviceProvider(),
        coreAudioProvider: any CoreAudioInputDeviceProviding =
            LiveCoreAudioInputDeviceProvider()
    ) {
        self.avFoundationProvider = avFoundationProvider
        self.coreAudioProvider = coreAudioProvider
    }

    func discover() throws -> AudioInputDiscoverySnapshot {
        var avFoundationInputs: [AVFoundationInputDevice] = []
        var coreAudioInputs: [CoreAudioInputDevice] = []
        var failedBackends: Set<AudioInputDiscoveryBackend> = []

        do {
            avFoundationInputs = try avFoundationProvider.inputs()
        } catch {
            failedBackends.insert(.avFoundation)
        }
        do {
            coreAudioInputs = try coreAudioProvider.inputs()
        } catch {
            failedBackends.insert(.coreAudio)
        }

        if failedBackends.count == 2 {
            throw AudioInputDiscoveryError.allBackendsFailed
        }

        return AudioInputDiscoverySnapshot(
            avFoundationInputs: avFoundationInputs,
            coreAudioInputs: coreAudioInputs,
            failedBackends: failedBackends
        )
    }
}
