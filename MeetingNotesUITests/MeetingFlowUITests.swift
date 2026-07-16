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

        let windowGlassSurface = app.descendants(matching: .any)[
            "app.windowGlassSurface"
        ].firstMatch
        XCTAssertTrue(windowGlassSurface.waitForExistence(timeout: 5))
        keepScreenshot(named: "01-home", of: app)
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
        keepScreenshot(named: "02-floating-recorder", of: app)

        app.buttons["floating.pause"].click()
        XCTAssertTrue(waitForLabel("继续", on: app.buttons["floating.pause"]))
        assertExactlyFourFloatingControls(in: app)

        app.buttons["floating.pause"].click()
        XCTAssertTrue(waitForLabel("暂停", on: app.buttons["floating.pause"]))
        assertExactlyFourFloatingControls(in: app)

        app.buttons["floating.bookmark"].click()
        XCTAssertTrue(
            app.staticTexts["meeting.bookmark"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        let stop = app.buttons["floating.stop"]
        stop.click()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["meeting.summarizeArchive"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["meeting.bookmark"].firstMatch.exists)

        let returnHome = app.buttons["meeting.returnHome"]
        XCTAssertTrue(returnHome.waitForExistence(timeout: 5))
        let historyMeeting = app.descendants(matching: .any)[
            "meeting.historyRow"
        ].firstMatch
        XCTAssertTrue(historyMeeting.waitForExistence(timeout: 5))
        keepScreenshot(named: "03-meeting-detail", of: app)
        returnHome.click()

        XCTAssertTrue(
            app.buttons["meeting.start.offline"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["meeting.start.online"].exists)
        XCTAssertTrue(historyMeeting.waitForExistence(timeout: 5))
        keepScreenshot(named: "04-returned-home", of: app)
    }

    func testSettingsConnectionButtonsShowSuccessfulResults() {
        let app = launchApp()
        XCTAssertTrue(
            app.buttons["meeting.start.offline"]
                .waitForExistence(timeout: 5)
        )
        app.activate()
        app.menuBars.menuBarItems["MeetingNotes"].click()
        app.menuItems["Settings…"].click()

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
        keepScreenshot(named: "05-settings", of: app)
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

        XCTAssertTrue(
            waitForButton(
                identifier: "meeting.summarizeArchive",
                label: "正在总结",
                in: app,
                timeout: 5
            )
        )
        XCTAssertTrue(
            waitForButton(
                identifier: "meeting.summarizeArchive",
                label: "正在归档",
                in: app,
                timeout: 8
            )
        )
        XCTAssertTrue(
            waitForButton(
                identifier: "meeting.summarizeArchive",
                label: "已归档",
                in: app,
                timeout: 8
            )
        )
        XCTAssertTrue(
            app.links["在 Notion 中打开"].waitForExistence(timeout: 5)
        )
        keepScreenshot(named: "06-archived-detail", of: app)
    }

    func testMeetingManagementMenusAndRename() {
        let app = launchApp()
        finishOfflineMeeting(in: app)

        let historyRow = app.descendants(matching: .any)[
            "meeting.historyRow"
        ].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))

        historyRow.rightClick()
        XCTAssertTrue(
            app.descendants(matching: .any)["meeting.context.rename"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["meeting.context.pin"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["meeting.context.delete"].exists
        )

        app.descendants(matching: .any)["meeting.context.rename"].click()
        let renameField = app.textFields["meeting.rename.field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        XCTAssertEqual(renameField.value as? String, "未命名会议")
        replaceText(in: renameField, with: "侧栏重命名会议")
        app.buttons["meeting.rename.save"].click()
        XCTAssertTrue(
            app.staticTexts["侧栏重命名会议"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        historyRow.rightClick()
        let pin = app.descendants(matching: .any)["meeting.context.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["置顶会议"].exists)
        pin.click()
        XCTAssertTrue(waitForValueContaining("已置顶", on: historyRow))

        historyRow.rightClick()
        let unpin = app.descendants(matching: .any)["meeting.context.pin"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["取消置顶"].exists)
        unpin.click()
        XCTAssertTrue(waitForValueContaining("未置顶", on: historyRow))
        XCTAssertFalse((historyRow.value as? String)?.contains("已置顶") ?? true)

        historyRow.rightClick()
        let repin = app.descendants(matching: .any)["meeting.context.pin"]
        XCTAssertTrue(repin.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["置顶会议"].exists)
        app.typeKey(.escape, modifierFlags: [])

        let detailRename = app.buttons["meeting.detail.rename"]
        XCTAssertTrue(detailRename.waitForExistence(timeout: 3))
        let summaryAction = app.buttons["meeting.summarizeArchive"]
        XCTAssertTrue(summaryAction.isEnabled)
        detailRename.click()
        let detailRenameField = app.textFields["meeting.detail.renameField"]
        XCTAssertTrue(detailRenameField.waitForExistence(timeout: 3))
        XCTAssertFalse(summaryAction.isEnabled)
        app.buttons["meeting.detail.renameCancel"].click()
        XCTAssertTrue(detailRename.waitForExistence(timeout: 3))
        XCTAssertTrue(summaryAction.isEnabled)

        detailRename.click()
        XCTAssertTrue(detailRenameField.waitForExistence(timeout: 3))
        replaceText(in: detailRenameField, with: "详情重命名会议")
        app.buttons["meeting.detail.renameSave"].click()
        XCTAssertTrue(
            app.staticTexts["详情重命名会议"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        historyRow.rightClick()
        app.descendants(matching: .any)["meeting.context.delete"].click()
        let cancelDeletion = app.buttons["meeting.delete.cancel"]
        XCTAssertTrue(cancelDeletion.waitForExistence(timeout: 3))
        XCTAssertTrue(historyRow.exists)
        cancelDeletion.click()
        XCTAssertTrue(historyRow.waitForExistence(timeout: 3))

        historyRow.rightClick()
        app.descendants(matching: .any)["meeting.context.delete"].click()
        let confirmDeletion = app.buttons["meeting.delete.confirm"]
        XCTAssertTrue(confirmDeletion.waitForExistence(timeout: 3))
        confirmDeletion.click()
        XCTAssertTrue(historyRow.waitForNonExistence(timeout: 5))
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        return app
    }

    private func finishOfflineMeeting(in app: XCUIApplication) {
        let start = app.buttons["meeting.start.offline"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()

        let stop = app.buttons["floating.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.click()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["meeting.summarizeArchive"]
                .waitForExistence(timeout: 5)
        )
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
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

    private func keepScreenshot(
        named name: String,
        of app: XCUIApplication
    ) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func waitForValueContaining(
        _ text: String,
        on element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForButton(
        identifier: String,
        label: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        app.buttons
            .matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@",
                    identifier,
                    label
                )
            )
            .firstMatch
            .waitForExistence(timeout: timeout)
    }
}
