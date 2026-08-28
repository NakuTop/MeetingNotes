import Foundation
import XCTest
@testable import MeetingNotes

final class SparkleUpdateConfigurationTests: XCTestCase {
    func testStableAndBetaUseSeparateHTTPSFeeds() throws {
        let stable = try XCTUnwrap(
            SparkleUpdateConfiguration(
                infoDictionary: updateInfo(
                    channel: "stable",
                    feed: "https://nakutop.github.io/MeetingNotes/updates/stable/appcast.xml"
                ),
                isUITesting: false
            )
        )
        let beta = try XCTUnwrap(
            SparkleUpdateConfiguration(
                infoDictionary: updateInfo(
                    channel: "beta",
                    feed: "https://nakutop.github.io/MeetingNotes/updates/beta/appcast.xml"
                ),
                isUITesting: false
            )
        )

        XCTAssertEqual(stable.channel, .stable)
        XCTAssertEqual(beta.channel, .beta)
        XCTAssertEqual(stable.feedURL.scheme, "https")
        XCTAssertEqual(beta.feedURL.scheme, "https")
        XCTAssertNotEqual(stable.feedURL, beta.feedURL)
        XCTAssertTrue(stable.shouldStartUpdater)
        XCTAssertTrue(beta.shouldStartUpdater)
    }

    func testUITestingNeverStartsUpdater() throws {
        let configuration = try XCTUnwrap(
            SparkleUpdateConfiguration(
                infoDictionary: updateInfo(
                    channel: "beta",
                    feed: "https://nakutop.github.io/MeetingNotes/updates/beta/appcast.xml"
                ),
                isUITesting: true
            )
        )

        XCTAssertFalse(configuration.shouldStartUpdater)
    }

    func testMissingPublicKeyDisablesUpdaterWithoutUsingPlaceholder() throws {
        var info = updateInfo(
            channel: "stable",
            feed: "https://nakutop.github.io/MeetingNotes/updates/stable/appcast.xml"
        )
        info["SUPublicEDKey"] = ""

        let configuration = try XCTUnwrap(
            SparkleUpdateConfiguration(
                infoDictionary: info,
                isUITesting: false
            )
        )

        XCTAssertFalse(configuration.shouldStartUpdater)
        XCTAssertNil(configuration.publicEDKey)
    }

    func testRepositoryConfigurationKeepsSignedManualInstallPolicy() throws {
        let root = repositoryRoot()
        let infoData = try Data(
            contentsOf: root.appendingPathComponent("Configuration/Info.plist")
        )
        let object = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        )
        let info = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(info["SUFeedURL"] as? String, "$(SPARKLE_FEED_URL)")
        XCTAssertEqual(
            info["SUPublicEDKey"] as? String,
            "$(SPARKLE_PUBLIC_ED_KEY)"
        )
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(
            info["SUEnableInstallerLauncherService"] as? Bool,
            true
        )
    }

    func testSandboxKeepsExistingPermissionsAndAddsSparkleMachLookups()
        throws {
        let root = repositoryRoot()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "Configuration/MeetingNotes.entitlements"
            )
        )
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let entitlements = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(
            entitlements["com.apple.security.device.audio-input"] as? Bool,
            true
        )
        XCTAssertEqual(
            entitlements["com.apple.security.network.client"] as? Bool,
            true
        )
        XCTAssertEqual(
            entitlements[
                "com.apple.security.temporary-exception.mach-lookup.global-name"
            ] as? [String],
            [
                "$(PRODUCT_BUNDLE_IDENTIFIER)-spks",
                "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"
            ]
        )
    }

    func testProjectKeepsWhisperKitAndFluidAudioWhenAddingSparkle() throws {
        let root = repositoryRoot()
        let project = try String(
            contentsOf: root.appendingPathComponent(
                "MeetingNotes.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("productName = WhisperKit;"))
        XCTAssertTrue(project.contains("productName = FluidAudio;"))
        XCTAssertTrue(project.contains("productName = Sparkle;"))
        XCTAssertTrue(
            project.contains(
                "https://github.com/sparkle-project/Sparkle"
            )
        )
    }

    func testProjectUsesOneValidEdDSAPublicKeyAcrossConfigurations()
        throws {
        let root = repositoryRoot()
        let project = try String(
            contentsOf: root.appendingPathComponent(
                "MeetingNotes.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let expression = try NSRegularExpression(
            pattern: #"SPARKLE_PUBLIC_ED_KEY = \"([^\"]+)\";"#
        )
        let matches = expression.matches(
            in: project,
            range: NSRange(project.startIndex..., in: project)
        )
        let keys = try matches.map { match in
            guard let range = Range(match.range(at: 1), in: project) else {
                throw SparkleUpdateConfigurationTestError.invalidMatch
            }
            return String(project[range])
        }

        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1)
        let publicKey = try XCTUnwrap(keys.first)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
        XCTAssertFalse(publicKey.contains("$("))
    }

    private func updateInfo(
        channel: String,
        feed: String
    ) -> [String: Any] {
        [
            "MeetingNotesUpdateChannel": channel,
            "MeetingNotesUpdatesEnabled": "YES",
            "SUFeedURL": feed,
            "SUPublicEDKey": "test-public-key"
        ]
    }

    private func repositoryRoot(
        file: StaticString = #filePath
    ) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum SparkleUpdateConfigurationTestError: Error {
    case invalidMatch
}
