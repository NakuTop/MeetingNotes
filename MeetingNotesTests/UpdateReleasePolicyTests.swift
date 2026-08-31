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

    func testPublishingWorkflowOffersAnIsolatedCommunityUnsignedMode()
        throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let inputs = try section(
            in: workflow,
            startingWith: "on:",
            endingBefore: "permissions:"
        )

        XCTAssertTrue(inputs.contains("distribution_mode:"))
        XCTAssertTrue(inputs.contains("- developer-id"))
        XCTAssertTrue(inputs.contains("- community-unsigned"))
        XCTAssertTrue(
            workflow.contains(
                "REQUESTED_DISTRIBUTION_MODE: ${{ inputs.distribution_mode }}"
            )
        )
        XCTAssertTrue(
            workflow.contains(
                "PUBLISH UNSIGNED stable $REQUESTED_VERSION ($REQUESTED_BUILD)"
            )
        )
        XCTAssertTrue(
            workflow.contains(
                "community-unsigned only supports the stable channel"
            )
        )
    }

    func testDeveloperIDSecretsAndCredentialsAreConditionallyIsolated()
        throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let sparkleSecrets = try section(
            in: workflow,
            startingWith: "      - name: Require Sparkle signing secret",
            endingBefore: "      - name: Require Developer ID release secrets"
        )
        let developerSecrets = try section(
            in: workflow,
            startingWith: "      - name: Require Developer ID release secrets",
            endingBefore: "      - name: Refuse an existing release"
        )
        let developerCredentials = try section(
            in: workflow,
            startingWith: "      - name: Prepare temporary Developer ID and notary credentials",
            endingBefore: "      - name: Build selected distribution"
        )
        let developerCondition =
            "if: inputs.distribution_mode == 'developer-id'"

        XCTAssertTrue(
            sparkleSecrets.contains("require_secret SPARKLE_ED_PRIVATE_KEY")
        )
        XCTAssertFalse(sparkleSecrets.contains("DEVELOPER_ID_P12_BASE64"))
        XCTAssertTrue(developerSecrets.contains(developerCondition))
        XCTAssertTrue(developerCredentials.contains(developerCondition))
    }

    func testCommunityUnsignedReleaseIsUniqueWarnedAndAlwaysPrerelease()
        throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )

        XCTAssertTrue(
            workflow.contains(
                "RELEASE_TAG=v${REQUESTED_VERSION}-unsigned-build${REQUESTED_BUILD}"
            )
        )
        XCTAssertTrue(
            workflow.contains(
                "ARTIFACT_NAME=MeetingNotes-${REQUESTED_VERSION}-build${REQUESTED_BUILD}-unsigned.dmg"
            )
        )
        XCTAssertTrue(workflow.contains("PRERELEASE=true"))
        XCTAssertTrue(
            workflow.contains(
                "社区免费分发版本，使用临时签名，未经 Apple Developer ID 签名或公证"
            )
        )
    }

    func testSelectedDistributionUsesOnlyItsDedicatedValidator() throws {
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )
        let validation = try section(
            in: workflow,
            startingWith: "      - name: Validate release artifact",
            endingBefore: "      - name: Retain validated artifact for audit"
        )

        XCTAssertTrue(
            validation.contains(
                "if [[ \"$REQUESTED_DISTRIBUTION_MODE\" == \"developer-id\" ]]"
            )
        )
        XCTAssertTrue(
            validation.contains("./Scripts/validate_update_release.sh")
        )
        XCTAssertTrue(
            validation.contains(
                "./Scripts/validate_unsigned_update_release.sh"
            )
        )
        XCTAssertTrue(
            validation.contains("SPARKLE_UPDATE_PUBLISHABLE=YES")
        )
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
            "TeamIdentifier=",
            "@executable_path/../Frameworks",
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

    func testPublishableDecisionRunsAfterNotarizationAndStapling()
        throws {
        let packager = try repositoryText(
            "Scripts/build_and_package.sh"
        )
        let notarizationAcceptedIndex = try XCTUnwrap(
            packager.range(of: "NOTARIZATION_STATUS=\"accepted\"")
        ).lowerBound
        let staplerPassedIndex = try XCTUnwrap(
            packager.range(of: "STAPLER=\"PASS\"")
        ).lowerBound
        let publishableIndex = try XCTUnwrap(
            packager.range(of: "PUBLISHABLE=YES")
        ).lowerBound

        XCTAssertGreaterThan(publishableIndex, notarizationAcceptedIndex)
        XCTAssertGreaterThan(publishableIndex, staplerPassedIndex)
    }

    func testPackagerRejectsAStandaloneAppWithoutSparkleRunpath()
        throws {
        let packager = try repositoryText(
            "Scripts/build_and_package.sh"
        )
        let requiredChecks = [
            "APP_EXECUTABLE=",
            "otool -L \"$APP_EXECUTABLE\"",
            "@rpath/Sparkle.framework/Versions/B/Sparkle",
            "otool -l \"$APP_EXECUTABLE\"",
            "@executable_path/../Frameworks"
        ]

        for check in requiredChecks {
            XCTAssertTrue(
                packager.contains(check),
                "Missing standalone launch gate: \(check)"
            )
        }
    }

    func testAdHocPackageDoesNotEnableTeamBasedLibraryValidation()
        throws {
        let packager = try repositoryText(
            "Scripts/build_and_package.sh"
        )

        XCTAssertTrue(packager.contains("RUNTIME_SIGN_FLAGS=()"))
        XCTAssertTrue(
            packager.contains("RUNTIME_SIGN_FLAGS=(-o runtime)")
        )
        XCTAssertTrue(
            packager.contains(
                "${RUNTIME_SIGN_FLAGS[@]+\"${RUNTIME_SIGN_FLAGS[@]}\"}"
            )
        )
        XCTAssertTrue(
            packager.contains(
                "ad-hoc package unexpectedly enables hardened runtime"
            )
        )
    }

    func testReleasePipelinePinsSparkle296Everywhere() throws {
        let projectYAML = try repositoryText("project.yml")
        let project = try repositoryText(
            "MeetingNotes.xcodeproj/project.pbxproj"
        )
        let resolved = try repositoryText(
            "MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/"
                + "swiftpm/Package.resolved"
        )
        let workflow = try repositoryText(
            ".github/workflows/publish-update.yml"
        )

        XCTAssertTrue(projectYAML.contains("exactVersion: 2.9.6"))
        XCTAssertTrue(project.contains("version = 2.9.6;"))
        XCTAssertNotNil(
            resolved.range(
                of: #"\"identity\" : \"sparkle\"[\s\S]*?\"version\" : \"2\.9\.6\""#,
                options: .regularExpression
            )
        )
        XCTAssertTrue(workflow.contains("SPARKLE_VERSION: 2.9.6"))

        let distributionSHA = try firstCapture(
            pattern: #"SPARKLE_DISTRIBUTION_SHA256: ([0-9a-f]{64})"#,
            in: workflow
        )
        XCTAssertEqual(
            distributionSHA,
            "52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
        )
    }

    func testStableReleaseIdentityIs120Build16() throws {
        let projectYAML = try repositoryText("project.yml")
        let project = try repositoryText(
            "MeetingNotes.xcodeproj/project.pbxproj"
        )
        let packager = try repositoryText(
            "Scripts/build_and_package.sh"
        )
        let baseSettings = try section(
            in: projectYAML,
            startingWith: "settings:\n  base:",
            endingBefore: "packages:"
        )

        XCTAssertTrue(baseSettings.contains("CURRENT_PROJECT_VERSION: 16"))
        XCTAssertTrue(baseSettings.contains("MARKETING_VERSION: 1.2.0"))
        XCTAssertTrue(baseSettings.contains("MEETINGNOTES_DISPLAY_NAME: 会议记录"))
        XCTAssertTrue(
            projectYAML.contains(
                "PRODUCT_BUNDLE_IDENTIFIER: com.shenminghao.MeetingNotes"
            )
        )
        XCTAssertNotNil(
            project.range(
                of: #"/\* Release \*/ = \{isa = XCBuildConfiguration;[\s\S]*?CURRENT_PROJECT_VERSION = 16;[\s\S]*?MARKETING_VERSION = 1\.2\.0;[\s\S]*?MEETINGNOTES_DISPLAY_NAME = \"会议记录\";[\s\S]*?PRODUCT_BUNDLE_IDENTIFIER = com\.shenminghao\.MeetingNotes;"#,
                options: .regularExpression
            )
        )
        XCTAssertTrue(
            packager.contains("EXPECTED_VERSION=\"1.2.0\"")
        )
        XCTAssertTrue(packager.contains("EXPECTED_BUILD=\"16\""))
    }

    func testPackagerExpandsAndVerifiesFinalSparkleEntitlements()
        throws {
        let packager = try repositoryText(
            "Scripts/build_and_package.sh"
        )
        let requiredChecks = [
            "EXPANDED_ENTITLEMENTS=",
            "Configuration/MeetingNotes.entitlements",
            ":com.apple.security.temporary-exception.mach-lookup.global-name:0",
            "$EXPECTED_BUNDLE_ID-spks",
            ":com.apple.security.temporary-exception.mach-lookup.global-name:1",
            "$EXPECTED_BUNDLE_ID-spki",
            ":com.apple.security.get-task-allow",
            "--entitlements \"$EXPANDED_ENTITLEMENTS\"",
            "get-task-allow entitlement must be absent",
            "APPLE_DISTRIBUTABLE=NO",
            "APPLE_DISTRIBUTABLE=YES",
            "echo \"APPLE_DISTRIBUTABLE=$APPLE_DISTRIBUTABLE\""
        ]

        for check in requiredChecks {
            XCTAssertTrue(
                packager.contains(check),
                "Missing processed-entitlement gate: \(check)"
            )
        }
    }

    func testUnsignedValidatorIsSeparateAndFailClosed() throws {
        let relativePath =
            "Scripts/validate_unsigned_update_release.sh"
        let validatorURL = repositoryRoot().appendingPathComponent(
            relativePath
        )
        let exists = FileManager.default.fileExists(
            atPath: validatorURL.path
        )

        XCTAssertTrue(exists, "Missing dedicated unsigned validator")
        guard exists else { return }

        let validator = try repositoryText(relativePath)
        let requiredChecks = [
            "configuration must be Release",
            "hdiutil verify",
            "codesign --verify --deep --strict",
            "Signature=adhoc",
            "TeamIdentifier=not set",
            "Authority=Developer ID Application:",
            "Timestamp=",
            "xcrun stapler validate",
            "spctl --assess --type execute",
            "@rpath/Sparkle.framework/Versions/B/Sparkle",
            "@executable_path/../Frameworks",
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.network.client",
            "com.apple.security.get-task-allow",
            "-spks",
            "-spki",
            "sparkle:edSignature",
            "sparkle:version",
            "sparkle:shortVersionString",
            "sparkle:hardwareRequirements",
            "Curve25519.Signing.PublicKey",
            "APPLE_DISTRIBUTABLE=NO",
            "SPARKLE_UPDATE_PUBLISHABLE=YES"
        ]

        for check in requiredChecks {
            XCTAssertTrue(
                validator.contains(check),
                "Missing unsigned release gate: \(check)"
            )
        }

        let signedValidator = try repositoryText(
            "Scripts/validate_update_release.sh"
        )
        XCTAssertTrue(
            signedValidator.contains("Developer ID Application:")
        )
        XCTAssertTrue(signedValidator.contains("xcrun stapler validate"))
        XCTAssertTrue(signedValidator.contains("PUBLISHABLE=YES"))
        XCTAssertFalse(
            signedValidator.contains("SPARKLE_UPDATE_PUBLISHABLE=YES")
        )
    }

    func testReleaseValidatorsPassExecutableBeforeLipoArchitectureCheck()
        throws {
        for path in [
            "Scripts/validate_update_release.sh",
            "Scripts/validate_unsigned_update_release.sh"
        ] {
            let validator = try repositoryText(path)

            XCTAssertTrue(
                validator.contains(
                    "lipo \"$EXECUTABLE\" -verify_arch arm64"
                ),
                "Invalid lipo argument order in \(path)"
            )
            XCTAssertFalse(
                validator.contains(
                    "lipo -verify_arch arm64 \"$EXECUTABLE\""
                ),
                "Executable would be parsed as an architecture in \(path)"
            )
        }
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
