import Foundation
import XCTest

final class UpdateReleasePolicyTests: XCTestCase {
    func testPublishingWorkflowIsManualOnly() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let triggers = try section(
            in: workflow,
            startingWith: "on:",
            endingBefore: "permissions:"
        )

        XCTAssertTrue(triggers.contains("workflow_dispatch:"))
        XCTAssertFalse(triggers.contains("\n  push:"))
        XCTAssertFalse(triggers.contains("\n  pull_request:"))
        XCTAssertFalse(triggers.contains("schedule:"))
    }

    func testPublishingWorkflowPinsThirdPartyExecutionByCommit() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )

        XCTAssertNotNil(
            workflow.range(
                of: #"actions/checkout@[0-9a-f]{40}"#,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(
            workflow.range(
                of: #"actions/upload-artifact@[0-9a-f]{40}"#,
                options: .regularExpression
            )
        )
    }

    func testPublishingWorkflowUsesTheEmbeddedSparklePublicKey() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let project = try repositoryText(
            "MeetingNotes.xcodeproj/project.pbxproj"
        )
        let workflowKey = try firstCapture(
            pattern: #"SPARKLE_PUBLIC_ED_KEY: ([A-Za-z0-9+/=]+)"#,
            in: workflow
        )
        let projectKey = try firstCapture(
            pattern: #"SPARKLE_PUBLIC_ED_KEY = \"([A-Za-z0-9+/=]+)\";"#,
            in: project
        )

        XCTAssertEqual(workflowKey, projectKey)
        XCTAssertEqual(Data(base64Encoded: workflowKey)?.count, 32)
    }

    func testPublishingWorkflowKeepsBetaAndStableIsolated() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )

        XCTAssertTrue(
            workflow.contains("FEED_PATH=updates/beta/appcast.xml")
        )
        XCTAssertTrue(workflow.contains("PRERELEASE=true"))
        XCTAssertTrue(
            workflow.contains("FEED_PATH=updates/stable/appcast.xml")
        )
        XCTAssertTrue(workflow.contains("PRERELEASE=false"))
        XCTAssertTrue(
            workflow.contains(
                "com.shenminghao.MeetingNotes.beta"
            )
        )
        XCTAssertTrue(
            workflow.contains("com.shenminghao.MeetingNotes")
        )
    }

    func testPublishingWorkflowRequiresAllReleaseCredentials() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let requiredSecrets = [
            "DEVELOPER_ID_P12_BASE64",
            "DEVELOPER_ID_P12_PASSWORD",
            "DEVELOPMENT_TEAM",
            "APPLE_NOTARY_KEY_ID",
            "APPLE_NOTARY_ISSUER_ID",
            "APPLE_NOTARY_PRIVATE_KEY",
            "SPARKLE_ED_PRIVATE_KEY"
        ]

        for secret in requiredSecrets {
            XCTAssertTrue(
                workflow.contains("secrets.\(secret)"),
                "Missing protected secret \(secret)"
            )
            XCTAssertTrue(
                workflow.contains("require_secret \(secret)"),
                "Missing fail-closed check for \(secret)"
            )
        }
    }

    func testValidationFinishesBeforeReleaseOrFeedMutation() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let validateIndex = try XCTUnwrap(
            workflow.range(of: "name: Validate release artifact")
        ).lowerBound
        let releaseIndex = try XCTUnwrap(
            workflow.range(of: "name: Create GitHub Release")
        ).lowerBound
        let feedIndex = try XCTUnwrap(
            workflow.range(of: "name: Publish selected appcast feed")
        ).lowerBound

        XCTAssertLessThan(validateIndex, releaseIndex)
        XCTAssertLessThan(validateIndex, feedIndex)
    }

    func testSparklePrivateKeyUsesSecretStdinAndNotRepositoryFile()
        throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )

        XCTAssertTrue(
            workflow.contains(
                "SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"
            )
        )
        XCTAssertTrue(
            workflow.contains("generate_appcast")
                && workflow.contains("--ed-key-file -")
        )
        XCTAssertTrue(
            workflow.contains(
                "printf '%s' \"$SPARKLE_ED_PRIVATE_KEY\" |"
            )
        )
        XCTAssertTrue(workflow.contains("--embed-release-notes"))
        XCTAssertFalse(workflow.contains("sparkle-private-key"))
        XCTAssertFalse(workflow.contains("SPARKLE_ED_PRIVATE_KEY >"))
    }

    func testReleaseValidatorContainsDistributionSafetyGates() throws {
        let validator = try repositoryText(
            "Scripts/validate_update_release.sh"
        )
        let requiredChecks = [
            "Developer ID Application:",
            "Timestamp=",
            "flags=0x10000",
            "codesign --verify --deep --strict",
            "spctl --assess",
            "xcrun stapler validate",
            "hdiutil verify",
            "sparkle:edSignature",
            "sparkle:version",
            "sparkle:shortVersionString",
            "sparkle:hardwareRequirements",
            "Curve25519.Signing.PublicKey",
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.network.client",
            "-spks",
            "-spki"
        ]

        for check in requiredChecks {
            XCTAssertTrue(
                validator.contains(check),
                "Missing release gate: \(check)"
            )
        }
    }

    func testAdHocPackageIsExplicitlyNonPublishable() throws {
        let packager = try repositoryText(
            "Scripts/build_and_package.sh"
        )

        XCTAssertTrue(packager.contains("PUBLISHABLE=NO"))
        XCTAssertTrue(packager.contains("PUBLISHABLE=YES"))
        XCTAssertTrue(
            packager.contains("NOTARIZATION_STATUS=\"accepted\"")
        )
    }

    private func repositoryText(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func section(
        in text: String,
        startingWith start: String,
        endingBefore end: String
    ) throws -> String {
        let startIndex = try XCTUnwrap(text.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(
            text.range(of: end, range: startIndex..<text.endIndex)?.lowerBound
        )
        return String(text[startIndex..<endIndex])
    }

    private func firstCapture(
        pattern: String,
        in text: String
    ) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            )
        )
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return String(text[range])
    }

    private func repositoryRoot(
        file: StaticString = #filePath
    ) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
