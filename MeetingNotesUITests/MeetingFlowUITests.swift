import AVFoundation
import AppKit
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
        let elapsed = app.descendants(matching: .any)[
            "floating.elapsed"
        ].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 3))
        let initialElapsed = accessibleText(of: elapsed)
        XCTAssertTrue(
            waitForAccessibleTextToChange(
                from: initialElapsed,
                on: elapsed,
                timeout: 2.5
            ),
            "悬浮录音时间应在录音期间持续更新"
        )
        let liveTranscript = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "UI 测试会议转录"
            )
        ).firstMatch
        XCTAssertTrue(
            liveTranscript.waitForExistence(timeout: 5),
            "录音未结束时应在会议详情中显示已完成的转录分段"
        )
        XCTAssertFalse(
            app.staticTexts["暂无转录"].exists,
            "实时转录出现后不应继续显示空状态"
        )
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
            app.buttons["meeting.documents.generate"]
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

    func testPartialArchiveSpeakerRenameAndFrequentNameSettings() {
        let app = launchApp(
            environment: ["MEETING_NOTES_UI_SPEAKER_ARCHIVE": "1"]
        )
        let partialHistoryRow = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "meeting.historyRow",
                "部分归档会议"
            )
        ).firstMatch
        XCTAssertTrue(partialHistoryRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabelContaining(
                "尚未同步到 Notion",
                on: partialHistoryRow
            )
        )
        let speakerHistoryRow = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "meeting.historyRow",
                "说话人标签会议"
            )
        ).firstMatch
        XCTAssertTrue(speakerHistoryRow.waitForExistence(timeout: 5))
        speakerHistoryRow.click()

        let detailScroll = app.scrollViews["meeting.detail"]
        let roomTwoSelector = app.buttons[
            "meeting.transcripts.speaker.room-2"
        ]
        scrollUntilHittable(roomTwoSelector, in: detailScroll)
        XCTAssertTrue(roomTwoSelector.waitForExistence(timeout: 3))
        let selectorButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "meeting.transcripts.speaker."
            )
        )
        XCTAssertEqual(selectorButtons.count, 2)
        roomTwoSelector.click()
        let historicalName = app.buttons["张三"]
        XCTAssertTrue(historicalName.waitForExistence(timeout: 3))
        historicalName.click()
        app.buttons["speaker.editor.save"].click()

        XCTAssertTrue(waitForLabel("张三", on: roomTwoSelector))
        let firstRoomTwoTurn = app.descendants(matching: .any)[
            "meeting.transcripts.turn.5000"
        ].firstMatch
        XCTAssertTrue(firstRoomTwoTurn.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForLabelContaining("张三", on: firstRoomTwoTurn))
        let laterRoomTwoTurn = app.descendants(matching: .any)[
            "meeting.transcripts.turn.20000"
        ].firstMatch
        scrollUntilHittable(laterRoomTwoTurn, in: detailScroll)
        XCTAssertTrue(laterRoomTwoTurn.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForLabelContaining("张三", on: laterRoomTwoTurn))

        openSettings(in: app)
        let settingsScroll = app.scrollViews["settings.scroll"]
        let newName = app.textFields["settings.speakers.newName"]
        scrollUntilHittable(newName, in: settingsScroll)
        XCTAssertTrue(newName.isHittable)
        replaceText(in: newName, with: "王老师")
        app.buttons["settings.speakers.add"].click()
        let remove = app.buttons["删除 王老师"]
        scrollUntilHittable(remove, in: settingsScroll)
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.click()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
    }

    func testEditsAutosaveAndReplaceCurrentMeeting() {
        let app = launchApp(
            environment: ["MEETING_NOTES_UI_MEETING_EDITING": "1"]
        )
        let currentMeeting = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "meeting.historyRow",
                "原界面可编辑会议"
            )
        ).firstMatch
        XCTAssertTrue(currentMeeting.waitForExistence(timeout: 5))
        currentMeeting.click()

        let detail = app.scrollViews["meeting.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["总结与同步"].exists)
        let summaryMode = app.buttons["meeting.documents.mode.summary"]
        let detailedMode = app.buttons["meeting.documents.mode.detailed"]
        XCTAssertTrue(summaryMode.exists)
        XCTAssertTrue(detailedMode.exists)
        let transcriptDisclosure = app.descendants(matching: .any)[
            "meeting.transcripts.disclosure"
        ].firstMatch
        XCTAssertTrue(transcriptDisclosure.exists)
        XCTAssertTrue(
            transcriptDisclosure.label.contains("完整转录内容")
        )
        XCTAssertTrue(app.staticTexts["书签"].exists)
        XCTAssertFalse(app.buttons["meeting.editMode"].exists)
        XCTAssertFalse(app.buttons["meeting.documents.save"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "meeting.replacement.toolbar"
            ].firstMatch.exists
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "meeting.documents.editor"
            ].firstMatch.exists
        )
        XCTAssertFalse(app.staticTexts["书签洞察"].exists)

        let summaryTask = app.descendants(matching: .any)[
            "meeting.summary.action.0.task"
        ].firstMatch
        let summaryOwner = app.descendants(matching: .any)[
            "meeting.summary.action.0.owner"
        ].firstMatch
        scrollUntilHittable(summaryTask, in: detail)
        XCTAssertTrue(summaryTask.isHittable)
        XCTAssertTrue(summaryOwner.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(summaryTask.frame.height, 24)
        XCTAssertGreaterThan(
            summaryOwner.frame.height,
            24,
            "task=\(summaryTask.frame) owner=\(summaryOwner.frame) detail=\(detail.frame)"
        )
        XCTAssertLessThanOrEqual(
            summaryOwner.frame.maxX,
            detail.frame.maxX + 1
        )

        for _ in 0..<14 where !detailedMode.isHittable {
            detail.scroll(byDeltaX: 0, deltaY: 90)
        }
        XCTAssertTrue(detailedMode.isHittable)
        detailedMode.click()
        let firstLongSpeaker = app.descendants(matching: .any)[
            "meeting.minutes.section.0.speaker.0"
        ].firstMatch
        let secondLongSpeaker = app.descendants(matching: .any)[
            "meeting.minutes.section.0.speaker.1"
        ].firstMatch
        scrollUntilHittable(firstLongSpeaker, in: detail)
        XCTAssertTrue(firstLongSpeaker.isHittable)
        XCTAssertTrue(secondLongSpeaker.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(
            firstLongSpeaker.frame.height,
            20,
            "first=\(firstLongSpeaker.frame) second=\(secondLongSpeaker.frame) detail=\(detail.frame)"
        )
        XCTAssertGreaterThan(
            secondLongSpeaker.frame.height,
            20,
            "first=\(firstLongSpeaker.frame) second=\(secondLongSpeaker.frame) detail=\(detail.frame)"
        )
        XCTAssertLessThanOrEqual(
            secondLongSpeaker.frame.maxX,
            detail.frame.maxX + 1
        )

        for _ in 0..<14 where !summaryMode.isHittable {
            detail.scroll(byDeltaX: 0, deltaY: 90)
        }
        XCTAssertTrue(summaryMode.isHittable)
        summaryMode.click()

        let transcript = app.descendants(matching: .any)[
            "meeting.transcripts.text.0"
        ].firstMatch
        scrollUntilHittable(transcript, in: detail)
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        XCTAssertEqual(accessibleText(of: transcript), "王明跟进王明任务")
        replaceText(
            in: transcript,
            with: "王明跟进王明任务，人工修正"
        )
        XCTAssertEqual(
            accessibleText(of: transcript),
            "王明跟进王明任务，人工修正"
        )
        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.edits.saveStatus",
                label: "已保存到本机",
                in: app,
                timeout: 5
            )
        )
        let transcriptTurn = app.descendants(matching: .any)[
            "meeting.transcripts.turn.0"
        ].firstMatch
        scrollUntilHittable(transcriptTurn, in: detail)
        XCTAssertTrue(transcriptTurn.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitForLabelContaining("人工修正", on: transcriptTurn),
            "label=\(transcriptTurn.label)"
        )

        let summaryOverview = app.descendants(matching: .any)[
            "meeting.summary.overview"
        ].firstMatch
        scrollUntilHittable(summaryOverview, in: detail)
        XCTAssertTrue(summaryOverview.waitForExistence(timeout: 3))
        replaceText(
            in: summaryOverview,
            with: "王明确认范围，人工修正"
        )

        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.edits.saveStatus",
                label: "已保存到本机",
                in: app,
                timeout: 5
            )
        )
        XCTAssertFalse(app.buttons["meeting.documents.save"].exists)

        scrollUntilHittable(transcript, in: detail)
        transcript.rightClick()
        let replaceSameText = app.menuItems["替换本会议相同文字…"]
        XCTAssertTrue(replaceSameText.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.menuItems["Copy"].exists
                || app.menuItems["拷贝"].exists
                || app.menuItems["复制"].exists
        )
        replaceSameText.click()

        let search = app.textFields["meeting.replacement.search"]
        let replacement = app.textFields["meeting.replacement.replacement"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(
            accessibleText(of: search),
            "王明跟进王明任务，人工修正"
        )
        replaceText(in: search, with: "王明")
        replaceText(in: replacement, with: "王敏")
        app.buttons["meeting.replacement.preview"].click()

        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.replacement.count.transcript",
                label: "完整转录：2 处",
                in: app,
                timeout: 3
            )
        )
        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.replacement.count.speaker",
                label: "说话人：1 处",
                in: app,
                timeout: 3
            )
        )
        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.replacement.count.summary",
                label: "重点总结：6 处",
                in: app,
                timeout: 3
            )
        )
        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.replacement.count.minutes",
                label: "完整纪要：8 处",
                in: app,
                timeout: 3
            )
        )
        app.buttons["meeting.replacement.cancel"].click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            waitForValueContaining("王明", on: transcript, timeout: 3)
        )

        transcript.rightClick()
        let replaceSameTextAgain = app.menuItems["替换本会议相同文字…"]
        XCTAssertTrue(replaceSameTextAgain.waitForExistence(timeout: 3))
        replaceSameTextAgain.click()
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        replaceText(in: search, with: "王明")
        replaceText(in: replacement, with: "王敏")
        app.buttons["meeting.replacement.preview"].click()
        let confirm = app.buttons["meeting.replacement.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.click()

        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            waitForValueContaining("王敏", on: transcript, timeout: 5)
        )
        XCTAssertFalse(accessibleText(of: transcript).contains("王明"))
        scrollUntilHittable(summaryOverview, in: detail)
        XCTAssertTrue(
            waitForValueContaining("王敏", on: summaryOverview, timeout: 5)
        )

        app.buttons["meeting.returnHome"].click()
        let isolatedMeeting = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "meeting.historyRow",
                "隔离会议（不应修改）"
            )
        ).firstMatch
        XCTAssertTrue(isolatedMeeting.waitForExistence(timeout: 5))
        isolatedMeeting.click()
        let isolatedDetail = app.scrollViews["meeting.detail"]
        XCTAssertTrue(isolatedDetail.waitForExistence(timeout: 5))
        let isolatedTranscript = app.descendants(matching: .any)[
            "meeting.transcripts.text.0"
        ].firstMatch
        scrollUntilHittable(isolatedTranscript, in: isolatedDetail)
        XCTAssertTrue(isolatedTranscript.waitForExistence(timeout: 5))
        XCTAssertEqual(
            accessibleText(of: isolatedTranscript),
            "王明跟进王明任务"
        )
        XCTAssertFalse(accessibleText(of: isolatedTranscript).contains("王敏"))
    }

    func testSettingsAudioDiagnosticsExposeAccessibleWorkflow() {
        let app = launchApp()
        XCTAssertTrue(
            app.buttons["meeting.start.offline"]
                .waitForExistence(timeout: 5)
        )
        openSettings(in: app)

        let inputPicker = app.descendants(matching: .any)[
            "settings.audio.inputPicker"
        ].firstMatch
        let inputTest = app.buttons["settings.audio.inputTest"]
        let outputPicker = app.descendants(matching: .any)[
            "settings.audio.outputPicker"
        ].firstMatch
        let outputTest = app.buttons["settings.audio.outputTest"]
        let smartDiagnostic = app.buttons["settings.audio.smartDiagnostic"]

        XCTAssertTrue(inputPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(inputTest.exists)
        XCTAssertTrue(outputPicker.exists)
        XCTAssertTrue(outputTest.exists)
        XCTAssertTrue(smartDiagnostic.exists)

        inputTest.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.audio.inputLevel"]
                .firstMatch
                .waitForExistence(timeout: 3)
        )
        let cancel = app.buttons["settings.audio.cancel"]
        XCTAssertTrue(cancel.exists)
        cancel.click()

        smartDiagnostic.click()
        let heardYes = app.buttons["settings.audio.outputHeardYes"]
        let heardNo = app.buttons["settings.audio.outputHeardNo"]
        XCTAssertTrue(heardYes.waitForExistence(timeout: 3))
        XCTAssertTrue(heardNo.exists)
        XCTAssertTrue(cancel.exists)

        heardYes.click()
        let preview = app.descendants(matching: .any)[
            "settings.audio.preview"
        ].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let send = app.buttons["settings.audio.sendToDeepSeek"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)

        let previewConsent = app.checkBoxes[
            "settings.audio.previewConsent"
        ]
        XCTAssertTrue(previewConsent.exists)
        previewConsent.click()
        XCTAssertTrue(send.isEnabled)
    }

    func testGenerateSummaryThenExplicitSyncShowsNotionLink() {
        let app = launchApp()
        let start = app.buttons["meeting.start.offline"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        XCTAssertTrue(
            app.buttons["floating.stop"].waitForExistence(timeout: 5)
        )
        app.buttons["floating.stop"].click()

        let action = app.buttons["meeting.documents.generate"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "生成重点总结")
        action.click()

        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.documents.notionSyncStatus",
                label: "尚未同步",
                in: app,
                timeout: 8
            )
        )
        let sync = app.buttons["meeting.documents.syncNotion"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.click()
        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.documents.notionSyncStatus",
                label: "正在同步",
                in: app,
                timeout: 3
            )
        )
        XCTAssertTrue(
            waitForStaticText(
                identifier: "meeting.documents.notionSyncStatus",
                label: "已同步",
                in: app,
                timeout: 8
            )
        )
        XCTAssertTrue(
            app.links["在 Notion 中打开"].waitForExistence(timeout: 5)
        )
        keepScreenshot(named: "06-synced-detail", of: app)
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
        renameField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForLabelContaining("侧栏重命名会议", on: historyRow))
        let detailTitle = app.staticTexts["meeting.detail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("侧栏重命名会议", on: detailTitle))

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
        let summaryAction = app.buttons["meeting.documents.generate"]
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
        detailRenameField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("详情重命名会议", on: detailTitle))
        XCTAssertTrue(waitForLabelContaining("详情重命名会议", on: historyRow))

        detailRename.click()
        XCTAssertTrue(detailRenameField.waitForExistence(timeout: 3))
        replaceText(in: detailRenameField, with: "按 Esc 取消的草稿")
        detailRenameField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(detailRenameField.waitForNonExistence(timeout: 3))
        XCTAssertTrue(waitForValue("详情重命名会议", on: detailTitle))
        XCTAssertTrue(waitForLabelContaining("详情重命名会议", on: historyRow))
        XCTAssertEqual(historyRow.value as? String, "未置顶")

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

    func testSlowArchivedRenameCanBeCancelledAndRetried() {
        let app = launchApp(
            environment: ["MEETING_NOTES_UI_SLOW_RENAME": "1"]
        )
        let historyRow = app.descendants(matching: .any)[
            "meeting.historyRow"
        ].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabelContaining("慢速归档会议", on: historyRow))
        historyRow.click()

        let detailTitle = app.staticTexts["meeting.detail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("慢速归档会议", on: detailTitle))

        historyRow.rightClick()
        app.descendants(matching: .any)["meeting.context.rename"].click()
        let sheetField = app.textFields["meeting.rename.field"]
        XCTAssertTrue(sheetField.waitForExistence(timeout: 3))
        replaceText(in: sheetField, with: "不应保存的侧栏草稿")
        app.buttons["meeting.rename.save"].click()

        let sheetCancel = app.buttons["meeting.rename.cancel"]
        XCTAssertTrue(sheetCancel.exists)
        XCTAssertTrue(sheetCancel.isEnabled)
        XCTAssertTrue(waitForDisabled(sheetField))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheetField.waitForNonExistence(timeout: 1))
        assertStaysAbsent(sheetField, for: 5.5)
        XCTAssertTrue(waitForValue("慢速归档会议", on: detailTitle))
        XCTAssertTrue(waitForLabelContaining("慢速归档会议", on: historyRow))
        XCTAssertFalse(
            app.staticTexts["无法重命名会议，请稍后重试。"].exists
        )

        historyRow.rightClick()
        app.descendants(matching: .any)["meeting.context.rename"].click()
        XCTAssertTrue(sheetField.waitForExistence(timeout: 3))
        replaceText(in: sheetField, with: "取消后重试成功")
        sheetField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("取消后重试成功", on: detailTitle, timeout: 8))
        XCTAssertTrue(
            waitForLabelContaining("取消后重试成功", on: historyRow, timeout: 8)
        )

        let detailRename = app.buttons["meeting.detail.rename"]
        XCTAssertTrue(detailRename.waitForExistence(timeout: 3))
        detailRename.click()
        let detailField = app.textFields["meeting.detail.renameField"]
        XCTAssertTrue(detailField.waitForExistence(timeout: 3))
        replaceText(in: detailField, with: "不应保存的详情草稿")
        app.buttons["meeting.detail.renameSave"].click()

        let detailCancel = app.buttons["meeting.detail.renameCancel"]
        XCTAssertTrue(detailCancel.exists)
        XCTAssertTrue(detailCancel.isEnabled)
        XCTAssertTrue(waitForDisabled(detailField))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(detailField.waitForNonExistence(timeout: 1))
        assertStaysAbsent(detailField, for: 5.5)
        XCTAssertTrue(waitForValue("取消后重试成功", on: detailTitle))
        XCTAssertTrue(waitForLabelContaining("取消后重试成功", on: historyRow))
        XCTAssertFalse(
            app.descendants(matching: .any)["meeting.detail.renameError"].exists
        )
    }

    func testLocalRecordingPlayer() throws {
        let meetingID = UUID()
        let app = launchApp(
            environment: [
                "MEETING_NOTES_UI_AUDIO_PLAYER": "1",
                "MEETING_NOTES_UI_AUDIO_PLAYER_MEETING_ID":
                    meetingID.uuidString
            ]
        )
        try makeAudioPlayerFixture(for: meetingID, app: app)
        let historyRow = app.descendants(matching: .any)[
            "meeting.historyRow"
        ].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabelContaining("可播放录音会议", on: historyRow))
        historyRow.click()

        let player = app.descendants(matching: .any)[
            "meeting.audioPlayer"
        ].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 8))

        let toggle = app.buttons["meeting.audioPlayer.toggle"]
        let waveform = app.sliders["meeting.audioPlayer.waveform"]
        let currentTime = app.staticTexts["meeting.audioPlayer.currentTime"]
        let duration = app.staticTexts["meeting.audioPlayer.duration"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(waveform.waitForExistence(timeout: 5))
        XCTAssertTrue(currentTime.waitForExistence(timeout: 5))
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(accessibleText(of: currentTime), "00:00")
        XCTAssertEqual(accessibleText(of: duration), "00:08")

        toggle.click()
        XCTAssertTrue(waitForLabel("暂停播放", on: toggle))

        toggle.click()
        XCTAssertTrue(waitForLabel("播放录音", on: toggle))
        let pausedTime = timeInSeconds(accessibleText(of: currentTime))
        assertTimeStays(pausedTime, on: currentTime, for: 0.75)

        waveform.click()
        let focusedTime = timeInSeconds(accessibleText(of: currentTime))
        waveform.typeKey(.rightArrow, modifierFlags: [])
        let expectedTime = min(8, focusedTime + 5)
        XCTAssertTrue(
            waitForTime(
                expectedTime,
                tolerance: 1,
                on: currentTime,
                timeout: 2
            ),
            "Accessibility seek should advance about five seconds from pause"
        )
        XCTAssertTrue(waitForLabel("播放录音", on: toggle))
        keepScreenshot(named: "07-local-recording-player", of: app)
    }

    func testPlayerPreparesWhenOpenMeetingBecomesPlayable() throws {
        let meetingID = UUID()
        let triggerURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "MeetingNotes-UITesting-Trigger-\(UUID().uuidString)"
            )
        let app = launchApp(
            environment: [
                "MEETING_NOTES_UI_AUDIO_PLAYER_MEETING_ID":
                    meetingID.uuidString,
                "MEETING_NOTES_UI_AUDIO_PLAYER_LIFECYCLE_TRIGGER":
                    triggerURL.path
            ],
            temporaryArtifacts: [
                triggerURL,
                triggerURL.appendingPathExtension("pending")
            ]
        )
        try makeAudioPlayerFixture(for: meetingID, app: app)
        let historyRow = app.descendants(matching: .any)[
            "meeting.historyRow"
        ].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabelContaining("录音即将完成会议", on: historyRow)
        )
        historyRow.click()

        let player = app.descendants(matching: .any)[
            "meeting.audioPlayer"
        ].firstMatch
        XCTAssertFalse(player.exists)
        XCTAssertTrue(app.staticTexts["正在录制"].waitForExistence(timeout: 3))

        try writeTriggerAtomically(to: triggerURL)

        XCTAssertTrue(player.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.buttons["meeting.audioPlayer.toggle"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            accessibleText(
                of: app.staticTexts["meeting.audioPlayer.duration"]
            ),
            "00:08"
        )
    }

    private func launchApp(
        environment: [String: String] = [:],
        temporaryArtifacts: [URL] = []
    ) -> XCUIApplication {
        continueAfterFailure = false
        installDocumentsPermissionDenialMonitor()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment = environment
        app.launch()
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.shenminghao.MeetingNotes"
        )
        XCTAssertEqual(candidates.count, 1, "Expected one launched test app")
        var cleanupURLs = temporaryArtifacts.map(\.standardizedFileURL)
        if let processID = candidates.first?.processIdentifier {
            cleanupURLs.append(recordingsRoot(for: processID))
        }
        addTeardownBlock { @MainActor in
            if app.state != .notRunning {
                app.terminate()
            }
            for url in cleanupURLs {
                guard Self.isSafeTemporaryArtifact(url) else {
                    XCTFail(
                        "Refusing to delete unrecognized UI test path: \(url.path)"
                    )
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
        return app
    }

    private func openSettings(in app: XCUIApplication) {
        app.activate()
        app.menuBars.menuBarItems["MeetingNotes"].click()
        app.menuItems["Settings…"].click()
    }

    private func recordingsRoot(for processID: pid_t) -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "MeetingNotes-UITesting-\(processID)",
                isDirectory: true
            )
    }

    private func makeAudioPlayerFixture(
        for meetingID: UUID,
        app: XCUIApplication
    ) throws {
        let processID = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.shenminghao.MeetingNotes"
            ).first?.processIdentifier,
            "Unable to capture launched app PID"
        )
        let directory = recordingsRoot(for: processID)
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sampleRate = 16_000.0
        let frameCount = Int(sampleRate * 8)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channel = buffer.floatChannelData?.pointee else {
            XCTFail("Unable to allocate UI test audio buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        channel.initialize(repeating: 0, count: frameCount)

        let fileName = "segment-0001.caf"
        let audioFile = try AVAudioFile(
            forWriting: directory.appendingPathComponent(fileName),
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try audioFile.write(from: buffer)
        audioFile.close()

        let manifest: [String: Any] = [
            "version": 1,
            "sampleRate": sampleRate,
            "channelCount": 1,
            "segments": [[
                "fileName": fileName,
                "startTime": 0,
                "endTime": 8,
                "frameCount": frameCount,
                "isComplete": true
            ]]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private nonisolated static func isSafeTemporaryArtifact(
        _ url: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent().path == "/tmp" else {
            return false
        }

        let name = standardized.lastPathComponent
        let rootPrefix = "MeetingNotes-UITesting-"
        if name.hasPrefix(rootPrefix) {
            let suffix = name.dropFirst(rootPrefix.count)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                return true
            }
        }

        let triggerPrefix = "MeetingNotes-UITesting-Trigger-"
        let triggerName = standardized.pathExtension == "pending"
            ? standardized.deletingPathExtension().lastPathComponent
            : name
        guard triggerName.hasPrefix(triggerPrefix) else { return false }
        let uuid = String(triggerName.dropFirst(triggerPrefix.count))
        return UUID(uuidString: uuid) != nil
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
            app.buttons["meeting.documents.generate"]
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

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForDisabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForLabelContaining(
        _ text: String,
        on element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func assertStaysAbsent(
        _ element: XCUIElement,
        for duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: element
        )
        expectation.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: duration),
            .completed,
            file: file,
            line: line
        )
    }

    private func waitForStaticText(
        identifier: String,
        label expectedText: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        app.staticTexts
            .matching(
                NSPredicate(
                    format: "identifier == %@ AND (label == %@ OR value == %@)",
                    identifier,
                    expectedText,
                    expectedText
                )
            )
            .firstMatch
            .waitForExistence(timeout: timeout)
    }

    private func waitForAccessibleTextToChange(
        from initialText: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if accessibleText(of: element) != initialText {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement
    ) {
        for _ in 0..<14 where !element.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -90)
        }
    }

    private func waitForTime(
        _ expectedSeconds: Int,
        tolerance: Int,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let current = timeInSeconds(accessibleText(of: element))
            if abs(current - expectedSeconds) <= tolerance {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func assertTimeStays(
        _ expectedSeconds: Int,
        on element: XCUIElement,
        for duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            XCTAssertEqual(
                timeInSeconds(accessibleText(of: element)),
                expectedSeconds,
                file: file,
                line: line
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    private func writeTriggerAtomically(to url: URL) throws {
        let temporaryURL = url.appendingPathExtension("pending")
        try Data("finish".utf8).write(to: temporaryURL, options: .atomic)
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func timeInSeconds(_ value: String) -> Int {
        value.split(separator: ":").reduce(0) { partial, component in
            partial * 60 + (Int(component) ?? 0)
        }
    }

    private func accessibleText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }
}

@MainActor
extension XCTestCase {
    func installDocumentsPermissionDenialMonitor() {
        addUIInterruptionMonitor(
            withDescription: "拒绝 UI 测试 Runner 访问文稿"
        ) { alert in
            let text = alert.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "MeetingNotesUITests-Runner",
                    "文稿"
                )
            ).firstMatch
            let deny = alert.buttons["不允许"]
            guard text.exists, deny.exists else { return false }
            deny.click()
            return true
        }
    }
}
