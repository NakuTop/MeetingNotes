import Foundation
import Observation

@MainActor
@Observable
final class OnboardingState {
    private enum Key {
        static let privacyAndConsentCompleted =
            "onboarding.privacyAndRecordingConsentCompleted"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    private(set) var hasConfirmedRecordingConsent: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasConfirmedRecordingConsent = defaults.bool(
            forKey: Key.privacyAndConsentCompleted
        )
    }

    var shouldPresentPrivacyAndConsent: Bool {
        !hasConfirmedRecordingConsent
    }

    func completePrivacyAndConsent() {
        defaults.set(true, forKey: Key.privacyAndConsentCompleted)
        hasConfirmedRecordingConsent = true
    }
}
