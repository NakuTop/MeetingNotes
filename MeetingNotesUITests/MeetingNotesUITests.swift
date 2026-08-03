import XCTest

@MainActor
final class MeetingDocumentsUITests: XCTestCase {
    func testDocumentSliderSwitchesByClickAndDragWithoutManualArchiveChoice() {
        installDocumentsPermissionDenialMonitor()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment["MEETING_NOTES_UI_DOCUMENTS"] = "1"
        app.launch()
        addTeardownBlock { @MainActor in
            if app.state != .notRunning {
                app.terminate()
            }
        }

        let historyRow = app.descendants(matching: .any)[
            "meeting.historyRow"
        ].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        historyRow.click()

        let mode = app.descendants(matching: .any)[
            "meeting.documents.mode"
        ].firstMatch
        let summary = app.buttons["meeting.documents.mode.summary"]
        let detailed = app.buttons["meeting.documents.mode.detailed"]
        let generate = app.buttons["meeting.documents.generate"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "meeting.documents.mode."
                )
            ).count,
            2
        )
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(detailed.exists)
        XCTAssertTrue(generate.exists)
        XCTAssertEqual(generate.label, "重新生成重点总结")
        XCTAssertTrue(app.staticTexts["UI 双模式重点总结"].exists)

        detailed.click()
        XCTAssertTrue(
            app.staticTexts["UI 双模式完整纪要"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertEqual(generate.label, "重新生成完整纪要")

        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: mode.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)
                )
            )
        XCTAssertTrue(
            app.staticTexts["UI 双模式重点总结"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertEqual(generate.label, "重新生成重点总结")

        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: mode.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
                )
            )
        XCTAssertTrue(
            app.staticTexts["UI 双模式完整纪要"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertEqual(generate.label, "重新生成完整纪要")

        XCTAssertFalse(app.staticTexts["两者"].exists)
        XCTAssertFalse(app.buttons["meeting.summarizeArchive"].exists)
        XCTAssertFalse(app.buttons["选择归档内容"].exists)
    }
}
