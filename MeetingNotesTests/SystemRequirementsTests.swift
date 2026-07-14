import Foundation
import XCTest
@testable import MeetingNotes

final class SystemRequirementsTests: XCTestCase {
    func testRequiresAppleSiliconAndMacOS15OrNewer() {
        let supported = SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: SystemRequirements.minimumFreeDiskBytes
        )
        let intel = SystemRequirements.evaluate(
            architecture: "x86_64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: SystemRequirements.minimumFreeDiskBytes
        )
        let oldSystem = SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 9,
                patchVersion: 9
            ),
            availableDiskBytes: SystemRequirements.minimumFreeDiskBytes
        )

        XCTAssertTrue(supported.isSupportedPlatform)
        XCTAssertTrue(supported.canStartRecording)
        XCTAssertFalse(intel.isSupportedPlatform)
        XCTAssertFalse(intel.canStartRecording)
        XCTAssertFalse(oldSystem.isSupportedPlatform)
        XCTAssertFalse(oldSystem.canStartRecording)
    }

    func testInsufficientOrUnknownDiskCapacityBlocksRecording() {
        let insufficient = SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: SystemRequirements.minimumFreeDiskBytes - 1
        )
        let unknown = SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: nil
        )

        XCTAssertFalse(insufficient.hasEnoughDiskSpace)
        XCTAssertFalse(insufficient.canStartRecording)
        XCTAssertFalse(unknown.hasEnoughDiskSpace)
        XCTAssertFalse(unknown.canStartRecording)
    }

    func testPermissionRepairURLsOpenCorrespondingPrivacySettings() {
        XCTAssertEqual(
            SystemRequirements.settingsURL(for: .microphone)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        XCTAssertEqual(
            SystemRequirements.settingsURL(for: .screenRecording)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }
}
