import XCTest

@MainActor
final class MeetingFlowUITests: XCTestCase {
    func testHomeHasExactlyTwoMeetingEntries() {
        let app = launchApp()
        XCTAssertTrue(
            app.buttons["meeting.start.offline"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["meeting.start.online"].exists)
        let entries = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "meeting.start."
            )
        )
        XCTAssertEqual(entries.count, 2)
    }

    func testFloatingRecorderAlwaysHasFourControlsAndBookmarkPersists() {
        let app = launchApp()
        let start = app.buttons["meeting.start.offline"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        XCTAssertTrue(
            app.buttons["floating.pause"].waitForExistence(timeout: 5)
        )
        assertExactlyFourFloatingControls(in: app)

        app.buttons["floating.pause"].click()
        XCTAssertTrue(waitForLabel("继续", on: app.buttons["floating.pause"]))
        assertExactlyFourFloatingControls(in: app)

        app.buttons["floating.pause"].click()
        XCTAssertTrue(waitForLabel("暂停", on: app.buttons["floating.pause"]))
        assertExactlyFourFloatingControls(in: app)

        app.buttons["floating.bookmark"].click()
        XCTAssertTrue(
            app.otherElements["meeting.bookmark"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        app.buttons["floating.stop"].click()
        XCTAssertTrue(
            app.buttons["meeting.summarizeArchive"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.otherElements["meeting.bookmark"].firstMatch.exists)
    }

    func testSettingsConnectionButtonsShowSuccessfulResults() {
        let app = launchApp()
        XCTAssertTrue(
            app.buttons["meeting.start.offline"]
                .waitForExistence(timeout: 5)
        )
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let deepSeek = app.buttons["settings.deepseek.testConnection"]
        let notion = app.buttons["settings.notion.testConnection"]
        XCTAssertTrue(deepSeek.waitForExistence(timeout: 5))
        XCTAssertTrue(notion.exists)

        deepSeek.click()
        XCTAssertTrue(
            app.staticTexts["连接成功，发现 2 个模型"]
                .waitForExistence(timeout: 5)
        )

        notion.click()
        XCTAssertTrue(
            app.staticTexts["连接成功：UI 测试父页面"]
                .waitForExistence(timeout: 5)
        )
    }

    func testSummarizeAndArchiveShowsBothStagesThenNotionLink() {
        let app = launchApp()
        let start = app.buttons["meeting.start.offline"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        XCTAssertTrue(
            app.buttons["floating.stop"].waitForExistence(timeout: 5)
        )
        app.buttons["floating.stop"].click()

        let action = app.buttons["meeting.summarizeArchive"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()

        XCTAssertTrue(waitForLabel("正在总结", on: action, timeout: 5))
        XCTAssertTrue(waitForLabel("正在归档", on: action, timeout: 8))
        XCTAssertTrue(waitForLabel("已归档", on: action, timeout: 8))
        XCTAssertTrue(
            app.links["在 Notion 中打开"].waitForExistence(timeout: 5)
        )
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        return app
    }

    private func assertExactlyFourFloatingControls(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let controls = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "floating."
            )
        )
        XCTAssertEqual(controls.count, 4, file: file, line: line)
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }
}
