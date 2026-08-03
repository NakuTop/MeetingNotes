import AppKit
import Foundation

enum PrivacySettingsDestination: Equatable, Sendable {
    case microphone
    case screenRecording
    case unknown
}

enum PrivacySettingsOpenError: LocalizedError, Equatable {
    case destinationUnavailable
    case openFailed

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            "无法定位对应的 macOS 隐私设置，请手动打开“系统设置 > 隐私与安全性”。"
        case .openFailed:
            "无法打开 macOS 隐私设置，请手动打开“系统设置 > 隐私与安全性”。"
        }
    }
}

@MainActor
protocol PrivacySettingsOpening {
    func open(_ destination: PrivacySettingsDestination) throws
}

@MainActor
struct PrivacySettingsOpener: PrivacySettingsOpening {
    private let openURL: (URL) -> Bool

    init(
        openURL: @escaping (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.openURL = openURL
    }

    func open(_ destination: PrivacySettingsDestination) throws {
        guard let url = Self.url(for: destination) else {
            throw PrivacySettingsOpenError.destinationUnavailable
        }
        guard openURL(url) else {
            throw PrivacySettingsOpenError.openFailed
        }
    }

    private static func url(
        for destination: PrivacySettingsDestination
    ) -> URL? {
        let anchor: String
        switch destination {
        case .microphone:
            anchor = "Privacy_Microphone"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        case .unknown:
            return nil
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        )
    }
}
