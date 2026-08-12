import CoreAudio
import Foundation

protocol AudioDeviceDiscovering: Sendable {
    func snapshot() async throws -> AudioDeviceSnapshot
}

@MainActor
protocol AudioDeviceChangeObserving: AnyObject {
    func start(handler: @escaping @Sendable () -> Void)
    func stop()
}

@MainActor
final class CoreAudioDeviceChangeObserver: AudioDeviceChangeObserving {
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let callbackQueue = DispatchQueue(
        label: "MeetingNotes.audio-device-changes"
    )
    private var listener: AudioObjectPropertyListenerBlock?
    private var registeredAddresses: [AudioObjectPropertyAddress] = []

    func start(handler: @escaping @Sendable () -> Void) {
        stop()
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        var registeredAddresses: [AudioObjectPropertyAddress] = []
        for address in Self.observedAddresses {
            var mutableAddress = address
            let status = AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &mutableAddress,
                callbackQueue,
                listener
            )
            if status == noErr {
                registeredAddresses.append(address)
            }
        }
        self.listener = listener
        self.registeredAddresses = registeredAddresses
    }

    func stop() {
        guard let listener else { return }
        for address in registeredAddresses {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &mutableAddress,
                callbackQueue,
                listener
            )
        }
        self.listener = nil
        registeredAddresses = []
    }

    private static let observedAddresses = [
        propertyAddress(selector: kAudioHardwarePropertyDevices),
        propertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice),
        propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
    ]

    private static func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

enum AudioDeviceCatalogError: Error, Equatable, Sendable {
    case coreAudioPropertySizeFailed(
        objectID: UInt32,
        selector: UInt32,
        status: Int32
    )
    case coreAudioPropertyReadFailed(
        objectID: UInt32,
        selector: UInt32,
        status: Int32
    )
    case invalidCoreAudioPropertyData(
        objectID: UInt32,
        selector: UInt32
    )
}

struct AudioDeviceCatalog: AudioDeviceDiscovering, Sendable {
    typealias InputProvider = @Sendable () throws -> [AudioInputDevice]
    typealias OutputProvider = @Sendable () throws -> [AudioOutputDevice]

    private static let unnamedDeviceName = "未命名音频设备"

    private let inputProvider: InputProvider
    private let outputProvider: OutputProvider

    init(
        inputProvider: @escaping InputProvider = discoverLiveInputs,
        outputProvider: @escaping OutputProvider =
            CoreAudioDeviceProvider.outputDevices
    ) {
        self.inputProvider = inputProvider
        self.outputProvider = outputProvider
    }

    func snapshot() async throws -> AudioDeviceSnapshot {
        let inputs = try normalize(inputProvider())
        let outputs = try normalize(outputProvider())
        return AudioDeviceSnapshot(inputs: inputs, outputs: outputs)
    }

    private func normalize(
        _ devices: [AudioInputDevice]
    ) -> [AudioInputDevice] {
        uniqueDevices(devices).map { device in
            AudioInputDevice(
                id: device.id,
                name: normalizedName(device.name),
                manufacturer: device.manufacturer,
                isConnected: device.isConnected,
                isSuspended: device.isSuspended,
                isInUseByAnotherApplication:
                    device.isInUseByAnotherApplication,
                isSystemDefault: device.isSystemDefault
            )
        }
        .sorted {
            orderedByNameThenID(
                lhsName: $0.name,
                lhsID: $0.id,
                rhsName: $1.name,
                rhsID: $1.id
            )
        }
    }

    private func normalize(
        _ devices: [AudioOutputDevice]
    ) -> [AudioOutputDevice] {
        uniqueDevices(devices).map { device in
            AudioOutputDevice(
                id: device.id,
                name: normalizedName(device.name),
                isConnected: device.isConnected,
                isSystemDefault: device.isSystemDefault
            )
        }
        .sorted {
            orderedByNameThenID(
                lhsName: $0.name,
                lhsID: $0.id,
                rhsName: $1.name,
                rhsID: $1.id
            )
        }
    }

    private func uniqueDevices<Device: Identifiable>(
        _ devices: [Device]
    ) -> [Device] where Device.ID == String {
        var seenIDs: Set<String> = []
        return devices.filter { seenIDs.insert($0.id).inserted }
    }

    private func normalizedName(_ name: String) -> String {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmedName.isEmpty ? Self.unnamedDeviceName : trimmedName
    }

    private func orderedByNameThenID(
        lhsName: String,
        lhsID: String,
        rhsName: String,
        rhsID: String
    ) -> Bool {
        let nameOrder = lhsName.localizedStandardCompare(rhsName)
        if nameOrder == .orderedSame {
            return lhsID < rhsID
        }
        return nameOrder == .orderedAscending
    }

    private static func discoverLiveInputs() throws -> [AudioInputDevice] {
        let snapshot = try LiveAudioInputDeviceProvider().discover()
        return AudioInputDeviceIdentityMatcher.mergedInputs(
            from: snapshot
        )
    }
}
