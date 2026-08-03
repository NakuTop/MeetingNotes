enum AudioDevicePreferenceResolver {
    static func resolveInput(
        preferredID: String?,
        devices: [AudioInputDevice]
    ) -> ResolvedAudioDevice<AudioInputDevice> {
        resolve(
            preferredID: preferredID,
            devices: devices,
            id: \.id,
            isUsable: \.isUsable,
            isSystemDefault: \.isSystemDefault
        )
    }

    static func resolveOutput(
        preferredID: String?,
        devices: [AudioOutputDevice]
    ) -> ResolvedAudioDevice<AudioOutputDevice> {
        resolve(
            preferredID: preferredID,
            devices: devices,
            id: \.id,
            isUsable: \.isUsable,
            isSystemDefault: \.isSystemDefault
        )
    }

    private static func resolve<Device: Equatable & Sendable>(
        preferredID: String?,
        devices: [Device],
        id: (Device) -> String,
        isUsable: (Device) -> Bool,
        isSystemDefault: (Device) -> Bool
    ) -> ResolvedAudioDevice<Device> {
        if let preferredID,
           let preferred = devices.first(where: {
               id($0) == preferredID && isUsable($0)
           }) {
            return .preferred(preferred)
        }

        let systemDefault = devices.first(where: {
            isUsable($0) && isSystemDefault($0)
        })
        let selected = systemDefault ?? devices.first(where: isUsable)

        guard let selected else {
            return .unavailable
        }

        if let preferredID {
            return .fallback(
                selected: selected,
                unavailablePreferredID: preferredID
            )
        }

        if systemDefault != nil {
            return .systemDefault(selected)
        }

        return .firstUsable(selected)
    }
}
