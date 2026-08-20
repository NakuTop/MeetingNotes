import CoreAudio
import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testLoadReadsPersistedTranscriptionQualityMode() throws {
        let fixture = try makeFixture()
        fixture.settings.transcriptionQualityMode = .highAccuracy

        fixture.viewModel.load()

        XCTAssertEqual(
            fixture.viewModel.selectedTranscriptionQualityMode,
            .highAccuracy
        )
    }

    func testSavePersistsSelectedTranscriptionQualityMode() async throws {
        let fixture = try makeFixture()
        fixture.viewModel.selectedTranscriptionQualityMode = .highAccuracy

        let saved = await fixture.viewModel.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(
            fixture.settings.transcriptionQualityMode,
            .highAccuracy
        )
    }

    func testTranscriptionQualityDraftDoesNotApplyUntilSaveSucceeds() async throws {
        let fixture = try makeFixture()
        fixture.settings.transcriptionQualityMode = .balanced
        let appliedModel = TranscriptionModelViewModel(
            preparer: SettingsModelPreparerStub(),
            selectedMode: fixture.settings.transcriptionQualityMode
        )
        fixture.viewModel.load()

        fixture.viewModel.selectedTranscriptionQualityMode = .highAccuracy

        XCTAssertEqual(appliedModel.selectedMode, .balanced)
        XCTAssertEqual(fixture.settings.transcriptionQualityMode, .balanced)

        if await fixture.viewModel.save() {
            appliedModel.selectedMode =
                fixture.viewModel.selectedTranscriptionQualityMode
        }

        XCTAssertEqual(appliedModel.selectedMode, .highAccuracy)
        XCTAssertEqual(fixture.settings.transcriptionQualityMode, .highAccuracy)
    }

    func testSaveRechecksRecordingAndWritesNothingWhenMeetingBecameActive() async throws {
        let recordingActivity = MutableSettingsRecordingActivityStub()
        let fixture = try makeFixture(recordingActivity: recordingActivity)
        let appliedModel = TranscriptionModelViewModel(
            preparer: SettingsModelPreparerStub(),
            selectedMode: .balanced
        )
        fixture.settings.deepSeekModel = "saved-model"
        fixture.settings.notionParentPageURL = "saved-page"
        fixture.settings.isNotionArchivingEnabled = true
        fixture.settings.isSpeakerDiarizationEnabled = false
        fixture.settings.transcriptionQualityMode = .balanced
        fixture.settings.preferredInputDeviceID = "saved-input"
        fixture.settings.preferredOutputDeviceID = "saved-output"
        fixture.viewModel.load()
        await fixture.viewModel.refreshAudioControlAvailability()
        XCTAssertFalse(fixture.viewModel.areTranscriptionControlsDisabled)

        fixture.viewModel.deepSeekAPIKeyInput = "new-deepseek-key"
        fixture.viewModel.notionTokenInput = "new-notion-token"
        fixture.viewModel.selectedModel = "new-model"
        fixture.viewModel.notionParentPageURL = "new-page"
        fixture.viewModel.isNotionArchivingEnabled = false
        fixture.viewModel.isSpeakerDiarizationEnabled = true
        fixture.viewModel.selectedTranscriptionQualityMode = .highAccuracy
        fixture.viewModel.selectedInputDeviceID = "new-input"
        fixture.viewModel.selectedOutputDeviceID = "new-output"
        await recordingActivity.setActive(true)

        let saved = await fixture.viewModel.save()
        if saved {
            appliedModel.selectedMode =
                fixture.viewModel.selectedTranscriptionQualityMode
        }

        XCTAssertFalse(saved)
        XCTAssertEqual(appliedModel.selectedMode, .balanced)
        XCTAssertTrue(fixture.viewModel.areTranscriptionControlsDisabled)
        XCTAssertEqual(
            fixture.viewModel.saveState,
            .failed(message: "会议录音进行中，无法保存设置。")
        )
        XCTAssertNil(
            try fixture.credentials.value(for: .deepSeekAPIKey)
        )
        XCTAssertNil(
            try fixture.credentials.value(for: .notionToken)
        )
        XCTAssertEqual(fixture.settings.deepSeekModel, "saved-model")
        XCTAssertEqual(fixture.settings.notionParentPageURL, "saved-page")
        XCTAssertTrue(fixture.settings.isNotionArchivingEnabled)
        XCTAssertFalse(fixture.settings.isSpeakerDiarizationEnabled)
        XCTAssertEqual(fixture.settings.transcriptionQualityMode, .balanced)
        XCTAssertEqual(
            fixture.settings.preferredInputDeviceID,
            "saved-input"
        )
        XCTAssertEqual(
            fixture.settings.preferredOutputDeviceID,
            "saved-output"
        )
    }

    func testTranscriptionControlsFollowRecordingActivityAvailability() async throws {
        for isActive in [true, false] {
            let fixture = try makeFixture(
                recordingActivity: SettingsRecordingActivityStub(
                    isActive: isActive
                )
            )

            await fixture.viewModel.refreshAudioControlAvailability()

            XCTAssertEqual(
                fixture.viewModel.areTranscriptionControlsDisabled,
                isActive
            )
        }
    }

    func testOnlyActiveCaptureStatesBlockTranscriptionQualityControls() {
        for state in [
            RecordingState.preparing,
            .recording,
            .paused,
            .finalizing
        ] {
            XCTAssertTrue(
                state.blocksCaptureSettingsChanges,
                "Expected \(state) to block transcription controls"
            )
        }

        for state in RecordingState.allCases where ![
            .preparing,
            .recording,
            .paused,
            .finalizing
        ].contains(state) {
            XCTAssertFalse(
                state.blocksCaptureSettingsChanges,
                "Expected \(state) to allow transcription controls"
            )
        }
    }

    func testLoadReadsPreferredAudioDeviceIDsSynchronously() throws {
        let fixture = try makeFixture()
        fixture.settings.preferredInputDeviceID = "saved-input"
        fixture.settings.preferredOutputDeviceID = "saved-output"

        fixture.viewModel.load()

        XCTAssertEqual(
            fixture.viewModel.selectedInputDeviceID,
            "saved-input"
        )
        XCTAssertEqual(
            fixture.viewModel.selectedOutputDeviceID,
            "saved-output"
        )
    }

    func testSavePersistsAudioDeviceIDsAndExistingPreferences() async throws {
        let fixture = try makeFixture()
        fixture.viewModel.selectedInputDeviceID = "input-123"
        fixture.viewModel.selectedOutputDeviceID = "output-456"
        fixture.viewModel.isNotionArchivingEnabled = false
        fixture.viewModel.isSpeakerDiarizationEnabled = true

        let saved = await fixture.viewModel.save()

        XCTAssertTrue(saved)

        XCTAssertEqual(
            fixture.settings.preferredInputDeviceID,
            "input-123"
        )
        XCTAssertEqual(
            fixture.settings.preferredOutputDeviceID,
            "output-456"
        )
        XCTAssertFalse(fixture.settings.isNotionArchivingEnabled)
        XCTAssertTrue(fixture.settings.isSpeakerDiarizationEnabled)
    }

    func testRefreshLoadsSnapshotAndResolvesPreferredDevices() async throws {
        let input = makeInputDevice(
            id: "preferred-input",
            name: "USB 麦克风"
        )
        let output = makeOutputDevice(
            id: "preferred-output",
            name: "显示器扬声器"
        )
        let snapshot = AudioDeviceSnapshot(
            inputs: [input],
            outputs: [output]
        )
        let fixture = try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(snapshot: snapshot)
        )
        fixture.settings.preferredInputDeviceID = input.id
        fixture.settings.preferredOutputDeviceID = output.id
        fixture.viewModel.load()

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertEqual(fixture.viewModel.audioDevices, snapshot)
        XCTAssertEqual(
            fixture.viewModel.resolvedInputDevice,
            .preferred(input)
        )
        XCTAssertEqual(
            fixture.viewModel.resolvedOutputDevice,
            .preferred(output)
        )
        XCTAssertNil(fixture.viewModel.audioDeviceMessage)
        XCTAssertFalse(fixture.viewModel.isRefreshingAudioDevices)
    }

    func testAudioControlsAreDisabledWhenMeetingIsRecording() async throws {
        let fixture = try makeFixture(
            recordingActivity: SettingsRecordingActivityStub(isActive: true)
        )

        await fixture.viewModel.refreshAudioControlAvailability()

        XCTAssertTrue(fixture.viewModel.areAudioControlsDisabled)
    }

    func testAudioControlsRemainEnabledWhenMeetingIsInactive() async throws {
        let fixture = try makeFixture(
            recordingActivity: SettingsRecordingActivityStub(isActive: false)
        )

        await fixture.viewModel.refreshAudioControlAvailability()

        XCTAssertFalse(fixture.viewModel.areAudioControlsDisabled)
    }

    func testRefreshFallsBackButPreservesMissingPreferredDeviceIDs() async throws {
        let input = makeInputDevice(
            id: "system-input",
            name: "内置麦克风",
            isSystemDefault: true
        )
        let output = makeOutputDevice(
            id: "system-output",
            name: "内置扬声器",
            isSystemDefault: true
        )
        let fixture = try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(
                    inputs: [input],
                    outputs: [output]
                )
            )
        )
        fixture.settings.preferredInputDeviceID = "missing-input"
        fixture.settings.preferredOutputDeviceID = "missing-output"
        fixture.viewModel.load()

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertEqual(
            fixture.viewModel.resolvedInputDevice,
            .fallback(
                selected: input,
                unavailablePreferredID: "missing-input"
            )
        )
        XCTAssertEqual(
            fixture.viewModel.resolvedOutputDevice,
            .fallback(
                selected: output,
                unavailablePreferredID: "missing-output"
            )
        )
        XCTAssertEqual(
            fixture.viewModel.selectedInputDeviceID,
            "missing-input"
        )
        XCTAssertEqual(
            fixture.viewModel.selectedOutputDeviceID,
            "missing-output"
        )
        XCTAssertEqual(
            fixture.settings.preferredInputDeviceID,
            "missing-input"
        )
        XCTAssertEqual(
            fixture.settings.preferredOutputDeviceID,
            "missing-output"
        )
        XCTAssertEqual(
            fixture.viewModel.audioDeviceMessage,
            """
            已保存的麦克风不可用，已临时使用“内置麦克风”。
            已保存的扬声器不可用，已临时使用“内置扬声器”。
            """
        )
    }

    func testRefreshIdentifiesUnavailableInputAndOutput() async throws {
        let fixture = try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(inputs: [], outputs: [])
            )
        )

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertEqual(fixture.viewModel.resolvedInputDevice, .unavailable)
        XCTAssertEqual(fixture.viewModel.resolvedOutputDevice, .unavailable)
        XCTAssertEqual(
            fixture.viewModel.audioDeviceMessage,
            """
            没有可用的麦克风。
            没有可用的扬声器。
            """
        )
    }

    func testRefreshErrorRetainsPriorAudioStateAndShowsReadableMessage() async throws {
        let input = makeInputDevice(id: "input-123", name: "会议麦克风")
        let output = makeOutputDevice(id: "output-456", name: "会议扬声器")
        let snapshot = AudioDeviceSnapshot(
            inputs: [input],
            outputs: [output]
        )
        let catalog = SequencedAudioDeviceCatalog(
            results: [
                .success(snapshot),
                .failure(.readFailed)
            ]
        )
        let fixture = try makeFixture(audioDeviceCatalog: catalog)
        fixture.settings.preferredInputDeviceID = input.id
        fixture.settings.preferredOutputDeviceID = output.id
        fixture.viewModel.load()
        await fixture.viewModel.refreshAudioDevices()
        let previousInputResolution =
            fixture.viewModel.resolvedInputDevice
        let previousOutputResolution =
            fixture.viewModel.resolvedOutputDevice

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertEqual(fixture.viewModel.audioDevices, snapshot)
        XCTAssertEqual(
            fixture.viewModel.selectedInputDeviceID,
            input.id
        )
        XCTAssertEqual(
            fixture.viewModel.selectedOutputDeviceID,
            output.id
        )
        XCTAssertEqual(
            fixture.viewModel.resolvedInputDevice,
            previousInputResolution
        )
        XCTAssertEqual(
            fixture.viewModel.resolvedOutputDevice,
            previousOutputResolution
        )
        XCTAssertEqual(
            fixture.viewModel.audioDeviceMessage,
            "无法读取音频设备，请稍后重试。"
        )
        XCTAssertFalse(fixture.viewModel.isRefreshingAudioDevices)
    }

    func testConcurrentRefreshCoalescesIntoSingleFollowUpCatalogCall()
        async throws {
        let catalog = QueuedBlockingAudioDeviceCatalog()
        let fixture = try makeFixture(audioDeviceCatalog: catalog)
        let firstRefresh = Task {
            await fixture.viewModel.refreshAudioDevices()
        }
        await catalog.waitUntilCallCount(1)

        await fixture.viewModel.refreshAudioDevices()

        let initialCallCount = await catalog.callCount()
        XCTAssertEqual(initialCallCount, 1)
        XCTAssertTrue(fixture.viewModel.isRefreshingAudioDevices)

        await catalog.finish(
            call: 1,
            with: AudioDeviceSnapshot(inputs: [], outputs: [])
        )
        await catalog.waitUntilCallCount(2)

        let coalescedCallCount = await catalog.callCount()
        XCTAssertEqual(coalescedCallCount, 2)
        await catalog.finish(
            call: 2,
            with: AudioDeviceSnapshot(inputs: [], outputs: [])
        )
        await firstRefresh.value

        XCTAssertFalse(fixture.viewModel.isRefreshingAudioDevices)
    }

    func testAudioDeviceChangesRefreshOnlyWhileSettingsAreVisible()
        async throws {
        let initial = AudioDeviceSnapshot(inputs: [], outputs: [])
        let changed = AudioDeviceSnapshot(
            inputs: [makeInputDevice(id: "usb-mic", name: "USB 麦克风")],
            outputs: []
        )
        let catalog = DeviceChangeAudioDeviceCatalog(
            snapshots: [initial, changed]
        )
        let observer = SettingsAudioDeviceChangeObserver()
        let fixture = try makeFixture(
            audioDeviceCatalog: catalog,
            audioDeviceChangeObserver: observer
        )
        fixture.viewModel.audioSettingsDidAppear()
        await fixture.viewModel.refreshAudioDevices()

        observer.sendChange()
        await catalog.waitUntilCallCount(2)

        XCTAssertEqual(fixture.viewModel.audioDevices, changed)
        XCTAssertEqual(observer.startCount, 1)

        fixture.viewModel.audioSettingsDidDisappear()
        observer.sendChange()
        for _ in 0..<10 {
            await Task.yield()
        }

        let callCount = await catalog.callCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(observer.stopCount, 1)
    }

    func testAudioDeviceChangeDuringRefreshQueuesAnotherSnapshot()
        async throws {
        let changed = AudioDeviceSnapshot(
            inputs: [makeInputDevice(id: "new-mic", name: "新麦克风")],
            outputs: []
        )
        let catalog = QueuedBlockingAudioDeviceCatalog()
        let observer = SettingsAudioDeviceChangeObserver()
        let fixture = try makeFixture(
            audioDeviceCatalog: catalog,
            audioDeviceChangeObserver: observer
        )
        fixture.viewModel.audioSettingsDidAppear()
        let initialRefresh = Task {
            await fixture.viewModel.refreshAudioDevices()
        }
        await catalog.waitUntilCallCount(1)

        observer.sendChange()
        await Task.yield()
        await catalog.finish(
            call: 1,
            with: AudioDeviceSnapshot(inputs: [], outputs: [])
        )
        await catalog.waitUntilCallCount(2)
        await catalog.finish(call: 2, with: changed)
        await initialRefresh.value

        XCTAssertEqual(fixture.viewModel.audioDevices, changed)
        let callCount = await catalog.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testCloseAndReopenDuringRefreshDiscardsOldSessionResult()
        async throws {
        let stale = AudioDeviceSnapshot(
            inputs: [makeInputDevice(id: "stale-mic", name: "旧麦克风")],
            outputs: []
        )
        let current = AudioDeviceSnapshot(
            inputs: [makeInputDevice(id: "current-mic", name: "当前麦克风")],
            outputs: []
        )
        let catalog = QueuedBlockingAudioDeviceCatalog()
        let fixture = try makeFixture(audioDeviceCatalog: catalog)
        fixture.viewModel.audioSettingsDidAppear()
        let oldRefresh = Task {
            await fixture.viewModel.refreshAudioDevices()
        }
        await catalog.waitUntilCallCount(1)

        fixture.viewModel.audioSettingsDidDisappear()
        fixture.viewModel.audioSettingsDidAppear()
        let reopenedRefresh = Task {
            await fixture.viewModel.refreshAudioDevices()
        }
        await Task.yield()
        await catalog.finish(call: 1, with: stale)
        await catalog.waitUntilCallCount(2)

        XCTAssertNotEqual(fixture.viewModel.audioDevices, stale)

        await catalog.finish(call: 2, with: current)
        await oldRefresh.value
        await reopenedRefresh.value

        XCTAssertEqual(fixture.viewModel.audioDevices, current)
        let callCount = await catalog.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testInputTestPublishesLiveMetricsThenCompletes() async throws {
        let tester = StreamingSettingsSignalTester()
        let fixture = try makeFixture(audioInputTester: tester)
        let task = Task { await fixture.viewModel.testSelectedInput() }
        await tester.waitUntilStarted()

        await tester.publish(audibleDiagnosticMetrics(sampleCount: 48_000))

        guard case let .testing(metrics) =
                fixture.viewModel.audioInputTestState else {
            return XCTFail("Expected live input metrics")
        }
        XCTAssertEqual(metrics?.sampleCount, 48_000)
        XCTAssertEqual(metrics?.level, .audible)

        await tester.finish(audibleDiagnosticMetrics())
        await task.value
        XCTAssertEqual(
            fixture.viewModel.audioInputTestState,
            .completed(audibleDiagnosticMetrics())
        )
    }

    func testOutputTestTransitionsThroughTestingAndSuccess() async throws {
        let tester = BlockingSettingsOutputTester()
        let fixture = try makeFixture(audioOutputTester: tester)
        let task = Task { await fixture.viewModel.testSelectedOutput() }
        await tester.waitUntilStarted()

        XCTAssertEqual(fixture.viewModel.audioOutputTestState, .testing)

        await tester.finish()
        await task.value
        XCTAssertEqual(
            fixture.viewModel.audioOutputTestState,
            .succeeded(message: "测试音已播放")
        )
    }

    func testSmartDiagnosticCannotStartTwice() async throws {
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let factory = SettingsDiagnosticCoordinatorFactoryStub(
            coordinator: coordinator
        )
        let fixture = try makeFixture(
            diagnosticCoordinatorFactory: factory
        )

        await fixture.viewModel.startSmartDiagnostic()
        await fixture.viewModel.startSmartDiagnostic()

        let makeCount = await factory.makeCount
        XCTAssertEqual(makeCount, 1)
        XCTAssertEqual(
            fixture.viewModel.audioDiagnosticState,
            .awaitingOutputConfirmation
        )
    }

    func testSmartDiagnosticCannotStartDuringMeeting() async throws {
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let factory = SettingsDiagnosticCoordinatorFactoryStub(
            coordinator: coordinator
        )
        let fixture = try makeFixture(
            recordingActivity: SettingsRecordingActivityStub(isActive: true),
            diagnosticCoordinatorFactory: factory
        )

        await fixture.viewModel.startSmartDiagnostic()

        let makeCount = await factory.makeCount
        XCTAssertEqual(makeCount, 0)
        XCTAssertEqual(
            fixture.viewModel.audioDiagnosticState,
            .failed(local: nil, message: "录音进行中无法运行音频诊断。")
        )
    }

    func testRecordingBecomingActiveCancelsRunningInputTest() async throws {
        let recordingActivity = MutableSettingsRecordingActivityStub()
        let inputTester = StreamingSettingsSignalTester()
        let fixture = try makeFixture(
            recordingActivity: recordingActivity,
            audioInputTester: inputTester
        )

        let inputTask = Task {
            await fixture.viewModel.testSelectedInput()
        }
        await inputTester.waitUntilStarted()
        await recordingActivity.setActive(true)

        await fixture.viewModel.refreshAudioControlAvailability()
        await inputTask.value

        XCTAssertTrue(fixture.viewModel.areAudioControlsDisabled)
        XCTAssertEqual(fixture.viewModel.audioInputTestState, .idle)
    }

    func testAudioOperationsAreMutuallyExclusiveInViewModel() async throws {
        let inputTester = StreamingSettingsSignalTester()
        let outputTester = CountingSettingsOutputTester()
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let factory = SettingsDiagnosticCoordinatorFactoryStub(
            coordinator: coordinator
        )
        let fixture = try makeFixture(
            audioInputTester: inputTester,
            audioOutputTester: outputTester,
            diagnosticCoordinatorFactory: factory
        )
        let inputTask = Task {
            await fixture.viewModel.testSelectedInput()
        }
        await inputTester.waitUntilStarted()

        await fixture.viewModel.testSelectedOutput()
        await fixture.viewModel.startSmartDiagnostic()

        let outputPlayCount = await outputTester.playCount
        let coordinatorMakeCount = await factory.makeCount
        XCTAssertEqual(outputPlayCount, 0)
        XCTAssertEqual(coordinatorMakeCount, 0)
        XCTAssertEqual(fixture.viewModel.audioOutputTestState, .idle)
        XCTAssertEqual(fixture.viewModel.audioDiagnosticState, .idle)
        await fixture.viewModel.cancelAudioDiagnostic()
        await inputTask.value
    }

    func testSettingsDisappearanceCancelsRunningAudioOperation() async throws {
        let inputTester = StreamingSettingsSignalTester()
        let fixture = try makeFixture(audioInputTester: inputTester)
        let inputTask = Task {
            await fixture.viewModel.testSelectedInput()
        }
        await inputTester.waitUntilStarted()

        fixture.viewModel.audioSettingsDidDisappear()
        await inputTask.value

        XCTAssertEqual(fixture.viewModel.audioInputTestState, .idle)
    }

    func testSettingsDisappearanceCannotResurrectStartingDiagnostic()
        async throws {
        let catalog = BlockingAudioDeviceCatalog()
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let factory = SettingsDiagnosticCoordinatorFactoryStub(
            coordinator: coordinator
        )
        let fixture = try makeFixture(
            audioDeviceCatalog: catalog,
            diagnosticCoordinatorFactory: factory
        )
        let diagnosticTask = Task {
            await fixture.viewModel.startSmartDiagnostic()
        }
        await catalog.waitUntilStarted()

        fixture.viewModel.audioSettingsDidDisappear()
        await catalog.finish(
            with: AudioDeviceSnapshot(inputs: [], outputs: [])
        )
        await diagnosticTask.value

        XCTAssertEqual(fixture.viewModel.audioDiagnosticState, .idle)
        let makeCount = await factory.makeCount
        XCTAssertEqual(makeCount, 0)
    }

    func testSettingsDisappearanceInvalidatesOperationWaitingForStatus()
        async throws {
        let recordingActivity = BlockingSettingsRecordingActivityStub()
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let factory = SettingsDiagnosticCoordinatorFactoryStub(
            coordinator: coordinator
        )
        let fixture = try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(inputs: [], outputs: [])
            ),
            recordingActivity: recordingActivity,
            diagnosticCoordinatorFactory: factory
        )
        let diagnosticTask = Task {
            await fixture.viewModel.startSmartDiagnostic()
        }
        await recordingActivity.waitUntilStarted()

        fixture.viewModel.audioSettingsDidDisappear()
        await recordingActivity.finish(isActive: false)
        await diagnosticTask.value

        XCTAssertEqual(fixture.viewModel.audioDiagnosticState, .idle)
        let makeCount = await factory.makeCount
        XCTAssertEqual(makeCount, 0)
    }

    func testOutputConfirmationStopsWhenRecordingBecomesActive() async throws {
        let recordingActivity = MutableSettingsRecordingActivityStub()
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let fixture = try makeDiagnosticFixture(
            recordingActivity: recordingActivity,
            coordinator: coordinator
        )
        await fixture.viewModel.startSmartDiagnostic()
        await recordingActivity.setActive(true)

        await fixture.viewModel.confirmOutputWasAudible(true)
        await coordinator.waitUntilCancelCount(1)

        XCTAssertTrue(fixture.viewModel.areAudioControlsDisabled)
        XCTAssertEqual(fixture.viewModel.audioDiagnosticState, .idle)
        let cancelCount = await coordinator.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testDiagnosticShowsLocalPreviewBeforeManualUpload() async throws {
        let explainer = SettingsDiagnosticExplainerStub(
            result: .success(
                AudioDiagnosticExplanation(
                    issue: "AI 问题",
                    solution: "AI 方案",
                    source: .deepSeek
                )
            )
        )
        let fixture = try makeDiagnosticFixture(explainer: explainer)

        await fixture.viewModel.startSmartDiagnostic()
        await fixture.viewModel.confirmOutputWasAudible(true)

        guard case let .readyForUpload(preview) =
                fixture.viewModel.audioDiagnosticState else {
            return XCTFail("Expected upload preview")
        }
        XCTAssertEqual(preview.primaryIssue, .microphoneNoFrames)
        XCTAssertEqual(
            preview.localIssue,
            AudioDiagnosticIssueCode.microphoneNoFrames.localIssue
        )
        XCTAssertTrue(preview.allowlistedJSON.contains("USB 麦克风"))
        XCTAssertFalse(preview.allowlistedJSON.contains("api-key"))
        let callCount = await explainer.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testDiagnosticUploadRequiresKeyAndKeepsLocalPreview() async throws {
        let fixture = try makeDiagnosticFixture()
        await fixture.viewModel.startSmartDiagnostic()
        await fixture.viewModel.confirmOutputWasAudible(false)

        await fixture.viewModel.sendDiagnosticToDeepSeek()

        guard case let .failed(local, message) =
                fixture.viewModel.audioDiagnosticState else {
            return XCTFail("Expected missing-key failure")
        }
        XCTAssertNotNil(local)
        XCTAssertEqual(message, "请输入 DeepSeek API Key，或先保存已有 Key。")
    }

    func testDiagnosticTimeoutReportRemainsUploadableToDeepSeek()
        async throws {
        let explainer = SettingsDiagnosticExplainerStub(
            result: .success(
                AudioDiagnosticExplanation(
                    issue: "AI 问题",
                    solution: "AI 方案",
                    source: .deepSeek
                )
            )
        )
        let timeoutReport = AudioDiagnosticReport(
            primaryIssue: .microphoneDiagnosticTimedOut,
            supportingIssues: [],
            facts: AudioDiagnosticFacts(
                microphonePermission: .authorized,
                screenPermission: .authorized,
                inputDeviceAvailable: true,
                outputToneWasScheduled: true,
                userHeardOutputTone: true,
                microphoneMetrics: nil,
                systemAudioMetrics: nil,
                historicalPlaybackFailed: false,
                microphoneTestOutcome: .timedOut,
                systemAudioTestOutcome: .notRun
            )
        )
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: timeoutReport
        )
        let fixture = try makeDiagnosticFixture(
            coordinator: coordinator,
            explainer: explainer
        )
        try fixture.credentials.save(
            "test-key",
            for: .deepSeekAPIKey
        )

        await fixture.viewModel.startSmartDiagnostic()
        await fixture.viewModel.confirmOutputWasAudible(true)

        guard case let .readyForUpload(preview) =
                fixture.viewModel.audioDiagnosticState else {
            return XCTFail("Expected timeout preview")
        }
        XCTAssertEqual(preview.primaryIssue, .microphoneDiagnosticTimedOut)
        XCTAssertEqual(
            preview.localIssue,
            AudioDiagnosticIssueCode.microphoneDiagnosticTimedOut.localIssue
        )
        XCTAssertTrue(preview.allowlistedJSON.contains("microphoneTestOutcome"))
        XCTAssertTrue(preview.allowlistedJSON.contains("\"timedOut\""))

        await fixture.viewModel.sendDiagnosticToDeepSeek()

        guard case let .completed(presentation) =
                fixture.viewModel.audioDiagnosticState else {
            return XCTFail("Expected DeepSeek completion")
        }
        XCTAssertEqual(presentation.issue, "AI 问题")
        XCTAssertEqual(presentation.local.primaryIssue, .microphoneDiagnosticTimedOut)
        let callCount = await explainer.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testDiagnosticUploadUsesCurrentKeyAndSelectedModel() async throws {
        let explainer = SettingsDiagnosticExplainerStub(
            result: .success(
                AudioDiagnosticExplanation(
                    issue: "麦克风路由异常",
                    solution: "重新选择麦克风后测试。",
                    source: .deepSeek
                )
            )
        )
        let fixture = try makeDiagnosticFixture(explainer: explainer)
        fixture.viewModel.deepSeekAPIKeyInput = "current-api-key"
        fixture.viewModel.selectedModel = "deepseek-reasoner"
        await fixture.viewModel.startSmartDiagnostic()
        await fixture.viewModel.confirmOutputWasAudible(true)

        await fixture.viewModel.sendDiagnosticToDeepSeek()

        let calls = await explainer.calls
        XCTAssertEqual(calls.map(\.apiKey), ["current-api-key"])
        XCTAssertEqual(calls.map(\.model), ["deepseek-reasoner"])
        guard case let .completed(presentation) =
                fixture.viewModel.audioDiagnosticState else {
            return XCTFail("Expected completed presentation")
        }
        XCTAssertEqual(presentation.issue, "麦克风路由异常")
        XCTAssertEqual(presentation.local.primaryIssue, .microphoneNoFrames)
    }

    func testDeepSeekFailureLeavesLocalDiagnosisVisible() async throws {
        let fixture = try makeDiagnosticFixture(
            explainer: SettingsDiagnosticExplainerStub(
                result: .failure(DeepSeekClientError.timeout)
            )
        )
        try fixture.credentials.save("saved-key", for: .deepSeekAPIKey)
        await fixture.viewModel.startSmartDiagnostic()
        await fixture.viewModel.confirmOutputWasAudible(true)

        await fixture.viewModel.sendDiagnosticToDeepSeek()

        guard case let .failed(local, message) =
                fixture.viewModel.audioDiagnosticState else {
            return XCTFail("Expected explain failure")
        }
        XCTAssertEqual(local?.primaryIssue, .microphoneNoFrames)
        XCTAssertTrue(message.contains("本地诊断仍可用"))
    }

    func testCancelReturnsDiagnosticToIdleAndCleansCoordinator() async throws {
        let coordinator = SettingsDiagnosticCoordinatorStub(
            report: settingsDiagnosticReport(.microphoneNoFrames)
        )
        let fixture = try makeFixture(
            diagnosticCoordinatorFactory:
                SettingsDiagnosticCoordinatorFactoryStub(
                    coordinator: coordinator
                )
        )
        await fixture.viewModel.startSmartDiagnostic()

        await fixture.viewModel.cancelAudioDiagnostic()
        await coordinator.waitUntilCancelCount(1)

        XCTAssertEqual(fixture.viewModel.audioDiagnosticState, .idle)
        let cancelCount = await coordinator.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelReturnsBeforeBlockedDiagnosticCleanupAndGatesReuse()
        async throws {
        let coordinator = BlockingCancellationSettingsDiagnosticCoordinator()
        let factory = SettingsDiagnosticCoordinatorFactoryStub(
            coordinator: coordinator
        )
        let outputTester = CountingSettingsOutputTester()
        let fixture = try makeFixture(
            audioOutputTester: outputTester,
            diagnosticCoordinatorFactory: factory
        )
        await fixture.viewModel.startSmartDiagnostic()
        let confirmationTask = Task { @MainActor in
            await fixture.viewModel.confirmOutputWasAudible(true)
        }
        await coordinator.waitUntilContinueStarted()

        let cancelReturned = expectation(description: "cancel returned")
        let cancelTask = Task { @MainActor in
            await fixture.viewModel.cancelAudioDiagnostic()
            cancelReturned.fulfill()
        }
        await fulfillment(of: [cancelReturned], timeout: 0.5)
        await coordinator.waitUntilContinueCancellationWasRequested()
        await coordinator.waitUntilCleanupStarted()

        XCTAssertEqual(fixture.viewModel.audioDiagnosticState, .idle)
        await fixture.viewModel.testSelectedOutput()
        await fixture.viewModel.startSmartDiagnostic()
        let outputPlayCountDuringCleanup = await outputTester.playCount
        let makeCountDuringCleanup = await factory.makeCount
        XCTAssertEqual(outputPlayCountDuringCleanup, 0)
        XCTAssertEqual(makeCountDuringCleanup, 1)

        coordinator.releaseCleanup()
        await coordinator.waitUntilCleanupFinished()
        await confirmationTask.value
        await cancelTask.value

        for _ in 0..<1_000 {
            await fixture.viewModel.startSmartDiagnostic()
            if await factory.makeCount == 2 { break }
            await Task.yield()
        }
        let finalMakeCount = await factory.makeCount
        XCTAssertEqual(finalMakeCount, 2)
        XCTAssertEqual(
            fixture.viewModel.audioDiagnosticState,
            .awaitingOutputConfirmation
        )
    }

    func testSpeakerDiarizationPreferenceDefaultsOffAndLoadsAndSaves() async throws {
        let fixture = try makeFixture()

        fixture.viewModel.load()

        XCTAssertFalse(fixture.viewModel.isSpeakerDiarizationEnabled)

        fixture.viewModel.isSpeakerDiarizationEnabled = true
        let saved = await fixture.viewModel.save()
        XCTAssertTrue(saved)
        fixture.viewModel.isSpeakerDiarizationEnabled = false
        fixture.viewModel.load()

        XCTAssertTrue(fixture.settings.isSpeakerDiarizationEnabled)
        XCTAssertTrue(fixture.viewModel.isSpeakerDiarizationEnabled)
    }

    func testNotionArchivingPreferenceLoadsAndSaves() async throws {
        let fixture = try makeFixture()
        fixture.settings.isNotionArchivingEnabled = false

        fixture.viewModel.load()

        XCTAssertFalse(fixture.viewModel.isNotionArchivingEnabled)

        fixture.viewModel.isNotionArchivingEnabled = true
        let saved = await fixture.viewModel.save()
        XCTAssertTrue(saved)
        fixture.viewModel.isNotionArchivingEnabled = false
        fixture.viewModel.load()

        XCTAssertTrue(fixture.settings.isNotionArchivingEnabled)
        XCTAssertTrue(fixture.viewModel.isNotionArchivingEnabled)
    }

    func testSaveWritesSecretsToCredentialStoreAndNonSecretsToSettings() async throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.deepSeekAPIKeyInput = "  sk-deepseek-123456  "
        viewModel.notionTokenInput = "secret_notion_987654"
        viewModel.selectedModel = "deepseek-reasoner"
        viewModel.notionParentPageURL = " https://www.notion.so/Parent-1234567890abcdef1234567890abcdef "

        let saved = await viewModel.save()

        XCTAssertTrue(saved)

        XCTAssertEqual(
            try fixture.credentials.value(for: .deepSeekAPIKey),
            "sk-deepseek-123456"
        )
        XCTAssertEqual(
            try fixture.credentials.value(for: .notionToken),
            "secret_notion_987654"
        )
        XCTAssertEqual(fixture.settings.deepSeekModel, "deepseek-reasoner")
        XCTAssertEqual(
            fixture.settings.notionParentPageURL,
            "https://www.notion.so/Parent-1234567890abcdef1234567890abcdef"
        )
        XCTAssertEqual(viewModel.deepSeekAPIKeyInput, "")
        XCTAssertEqual(viewModel.notionTokenInput, "")
        XCTAssertEqual(
            viewModel.deepSeekCredential,
            .saved(maskedValue: CredentialMask.mask("sk-deepseek-123456"))
        )
        XCTAssertEqual(
            viewModel.notionCredential,
            .saved(maskedValue: CredentialMask.mask("secret_notion_987654"))
        )
    }

    func testReloadShowsOnlyMaskedPresenceAndNeverHydratesSecretInputs() throws {
        let fixture = try makeFixture()
        try fixture.credentials.save(
            "secret-key-must-not-return",
            for: .deepSeekAPIKey
        )
        try fixture.credentials.save(
            "secret-token-must-not-return",
            for: .notionToken
        )

        fixture.viewModel.load()

        XCTAssertEqual(fixture.viewModel.deepSeekAPIKeyInput, "")
        XCTAssertEqual(fixture.viewModel.notionTokenInput, "")
        XCTAssertEqual(
            fixture.viewModel.deepSeekCredential,
            .saved(maskedValue: CredentialMask.mask("secret-key-must-not-return"))
        )
        XCTAssertEqual(
            fixture.viewModel.notionCredential,
            .saved(maskedValue: CredentialMask.mask("secret-token-must-not-return"))
        )
    }

    func testDeepSeekConnectionPrefersCurrentInputAndUpdatesModelList() async throws {
        let tester = RecordingDeepSeekTester(
            result: .success(["deepseek-chat", "deepseek-reasoner"])
        )
        let fixture = try makeFixture(deepSeekTester: tester)
        try fixture.credentials.save("saved-key", for: .deepSeekAPIKey)
        fixture.viewModel.deepSeekAPIKeyInput = "current-key"
        fixture.viewModel.selectedModel = "unknown-model"

        await fixture.viewModel.testDeepSeekConnection()

        let testedAPIKeys = await tester.apiKeys()
        XCTAssertEqual(testedAPIKeys, ["current-key"])
        XCTAssertEqual(
            fixture.viewModel.availableModels,
            ["deepseek-chat", "deepseek-reasoner"]
        )
        XCTAssertEqual(fixture.viewModel.selectedModel, "deepseek-chat")
        XCTAssertEqual(
            fixture.viewModel.deepSeekConnection,
            .succeeded(message: "连接成功，发现 2 个模型")
        )
    }

    func testDeepSeekConnectionFallsBackToSavedKey() async throws {
        let tester = RecordingDeepSeekTester(
            result: .success(["deepseek-chat"])
        )
        let fixture = try makeFixture(deepSeekTester: tester)
        try fixture.credentials.save("saved-key", for: .deepSeekAPIKey)

        await fixture.viewModel.testDeepSeekConnection()

        let testedAPIKeys = await tester.apiKeys()
        XCTAssertEqual(testedAPIKeys, ["saved-key"])
    }

    func testNotionConnectionValidatesTokenAndPageAndShowsParentTitle() async throws {
        let parentID = try XCTUnwrap(
            UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef")
        )
        let tester = RecordingNotionTester(
            result: .success(
                NotionConnectionResult(
                    userID: "bot-id",
                    userName: "Meeting Bot",
                    parentPage: NotionPageReference(
                        id: parentID.uuidString,
                        url: "https://www.notion.so/parent"
                    ),
                    parentPageTitle: "团队会议库"
                )
            )
        )
        let fixture = try makeFixture(notionTester: tester)
        fixture.viewModel.notionTokenInput = "current-notion-token"
        fixture.viewModel.notionParentPageURL =
            "https://www.notion.so/Team-1234567890abcdef1234567890abcdef"

        await fixture.viewModel.testNotionConnection()

        let calls = await tester.calls()
        XCTAssertEqual(calls.map(\.token), ["current-notion-token"])
        XCTAssertEqual(calls.map(\.parentPageID), [parentID])
        XCTAssertEqual(
            fixture.viewModel.notionConnection,
            .succeeded(message: "连接成功：团队会议库")
        )
    }

    func testClearDeletesCredentialsIndependently() throws {
        let fixture = try makeFixture()
        try fixture.credentials.save("deepseek", for: .deepSeekAPIKey)
        try fixture.credentials.save("notion", for: .notionToken)
        fixture.viewModel.load()

        fixture.viewModel.clearDeepSeekCredential()

        XCTAssertNil(try fixture.credentials.value(for: .deepSeekAPIKey))
        XCTAssertEqual(
            try fixture.credentials.value(for: .notionToken),
            "notion"
        )
        XCTAssertEqual(fixture.viewModel.deepSeekCredential, .missing)

        fixture.viewModel.clearNotionCredential()

        XCTAssertNil(try fixture.credentials.value(for: .notionToken))
        XCTAssertEqual(fixture.viewModel.notionCredential, .missing)
    }

    func testConnectionPreventsDuplicateClicksAndErrorsNeverContainSecret() async throws {
        let tester = BlockingDeepSeekTester()
        let fixture = try makeFixture(deepSeekTester: tester)
        let secret = "must-never-appear-in-errors"
        fixture.viewModel.deepSeekAPIKeyInput = secret

        let first = Task {
            await fixture.viewModel.testDeepSeekConnection()
        }
        await tester.waitUntilStarted()
        let duplicate = Task {
            await fixture.viewModel.testDeepSeekConnection()
        }
        await duplicate.value
        let callCount = await tester.callCount()
        XCTAssertEqual(callCount, 1)

        await tester.finish(with: .failure(DeepSeekClientError.unauthorized))
        await first.value

        guard case let .failed(message) = fixture.viewModel.deepSeekConnection else {
            return XCTFail("Expected a failed connection state")
        }
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(message.contains("API Key"))
    }

    func testLoadReadsFrequentSpeakerNamesAndClearsDraft() throws {
        let fixture = try makeFixture()
        fixture.settings.frequentSpeakerNames = ["张三", "李四"]
        fixture.viewModel.newSpeakerName = "旧草稿"

        fixture.viewModel.load()

        XCTAssertEqual(
            fixture.viewModel.frequentSpeakerNames,
            ["张三", "李四"]
        )
        XCTAssertEqual(fixture.viewModel.newSpeakerName, "")
    }

    func testAddFrequentSpeakerNamePersistsAndMergesLatestStore() throws {
        let fixture = try makeFixture()
        fixture.settings.frequentSpeakerNames = ["张三"]
        fixture.viewModel.load()
        fixture.settings.rememberSpeakerName("王五")

        fixture.viewModel.newSpeakerName = " 李四 "
        fixture.viewModel.addFrequentSpeakerName()
        fixture.viewModel.newSpeakerName = "张三"
        fixture.viewModel.addFrequentSpeakerName()

        XCTAssertEqual(
            fixture.viewModel.frequentSpeakerNames,
            ["张三", "王五", "李四"]
        )
        XCTAssertEqual(
            fixture.settings.frequentSpeakerNames,
            ["张三", "王五", "李四"]
        )
        XCTAssertEqual(fixture.viewModel.newSpeakerName, "")
    }

    func testSavingOtherSettingsKeepsNameRememberedAfterLoad() async throws {
        let fixture = try makeFixture()
        fixture.settings.frequentSpeakerNames = ["张三"]
        fixture.viewModel.load()
        fixture.settings.rememberSpeakerName("李四")
        fixture.viewModel.selectedModel = "updated-model"

        let saved = await fixture.viewModel.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.settings.deepSeekModel, "updated-model")
        XCTAssertEqual(
            fixture.settings.frequentSpeakerNames,
            ["张三", "李四"]
        )
        XCTAssertEqual(
            fixture.viewModel.frequentSpeakerNames,
            ["张三", "李四"]
        )
    }

    func testRemoveFrequentSpeakerNamePersistsImmediately() throws {
        let fixture = try makeFixture()
        fixture.settings.frequentSpeakerNames = ["张三", "李四"]
        fixture.viewModel.load()

        fixture.viewModel.removeFrequentSpeakerName("张三")

        XCTAssertEqual(fixture.viewModel.frequentSpeakerNames, ["李四"])
        XCTAssertEqual(fixture.settings.frequentSpeakerNames, ["李四"])
    }

    func testRefreshAudioDevicesUsesFreshRuntimeSnapshotForRecoveringMessage()
        async throws {
        let runtime = SettingsMicrophoneRuntimeStub(
            snapshot: MicrophoneRuntimeSnapshot(
                status: .recovering,
                telemetry: MicrophoneCaptureTelemetry()
            )
        )
        let fixture = try makeFixture(
            microphoneRuntime: runtime
        )

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertTrue(fixture.viewModel.isMicrophoneRecovering)
        XCTAssertTrue(
            fixture.viewModel.audioDeviceMessage?
                .contains("正在重新连接麦克风") == true
        )
    }

    func testCoreAudioFallbackActiveRequiresActualRuntimeCapture()
        async throws {
        let coreAudioOnly = AudioInputDevice(
            id: "ca:mic",
            name: "USB Mic",
            manufacturer: "Test",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true,
            coreAudioUID: "mic",
            coreAudioDeviceID: AudioDeviceID(42),
            inputChannelCount: 1,
            isCoreAudioAvailable: true
        )
        let runtime = SettingsMicrophoneRuntimeStub(
            snapshot: MicrophoneRuntimeSnapshot()
        )
        let fixture = try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(
                    inputs: [coreAudioOnly],
                    outputs: []
                )
            ),
            microphoneRuntime: runtime
        )

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertEqual(
            fixture.viewModel.resolvedInputCapture?
                .usesCoreAudioFallback,
            true
        )
        XCTAssertFalse(
            fixture.viewModel.isCoreAudioFallbackActive
        )
    }

    func testCoreAudioFallbackActiveWhenRuntimeActuallyUsesFallback()
        async throws {
        let coreAudioOnly = AudioInputDevice(
            id: "ca:mic",
            name: "USB Mic",
            manufacturer: "Test",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true,
            coreAudioUID: "mic",
            coreAudioDeviceID: AudioDeviceID(42),
            inputChannelCount: 1,
            isCoreAudioAvailable: true
        )
        var telemetry = MicrophoneCaptureTelemetry()
        telemetry.captureStarted = true
        telemetry.captureBackend = .coreAudioFallback
        let runtime = SettingsMicrophoneRuntimeStub(
            snapshot: MicrophoneRuntimeSnapshot(
                status: .fallbackActive,
                telemetry: telemetry
            )
        )
        let fixture = try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(
                    inputs: [coreAudioOnly],
                    outputs: []
                )
            ),
            microphoneRuntime: runtime
        )

        await fixture.viewModel.refreshAudioDevices()

        XCTAssertTrue(fixture.viewModel.isCoreAudioFallbackActive)
    }

    private func makeFixture(
        deepSeekTester: any DeepSeekConnectionTesting = RecordingDeepSeekTester(
            result: .success([])
        ),
        notionTester: any NotionConnectionTesting = RecordingNotionTester(
            result: .failure(NotionClientError.transport)
        ),
        audioDeviceCatalog: any AudioDeviceDiscovering =
            StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(inputs: [], outputs: [])
            ),
        audioDeviceChangeObserver: any AudioDeviceChangeObserving =
            SettingsAudioDeviceChangeObserver(),
        recordingActivity: any AudioDiagnosticRecordingActivityChecking =
            SettingsRecordingActivityStub(isActive: false),
        audioInputTester: any AudioDiagnosticSignalTesting =
            SettingsSignalTesterStub(),
        audioOutputTester: any AudioOutputTesting =
            SettingsOutputTesterStub(),
        diagnosticCoordinatorFactory:
            any AudioDiagnosticCoordinatorCreating =
                SettingsDiagnosticCoordinatorFactoryStub(
                    coordinator: SettingsDiagnosticCoordinatorStub(
                        report: settingsDiagnosticReport(.captureHealthy)
                    )
                ),
        diagnosticExplainer: any AudioDiagnosticExplanationRequesting =
            SettingsDiagnosticExplainerStub(
                result: .failure(DeepSeekClientError.transport)
            ),
        diagnosticEnvironment:
            any AudioDiagnosticEnvironmentInfoProviding =
                SettingsDiagnosticEnvironmentStub(),
        microphoneRuntime: (any MicrophoneRuntimeReporting)? = nil
    ) throws -> Fixture {
        let suiteName = "SettingsViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let credentials = InMemoryCredentialStore()
        let settings = AppSettingsStore(defaults: defaults)
        return Fixture(
            viewModel: SettingsViewModel(
                credentialStore: credentials,
                settingsStore: settings,
                deepSeekTester: deepSeekTester,
                notionTester: notionTester,
                audioDeviceCatalog: audioDeviceCatalog,
                audioDeviceChangeObserver: audioDeviceChangeObserver,
                recordingActivity: recordingActivity,
                audioInputTester: audioInputTester,
                audioOutputTester: audioOutputTester,
                diagnosticCoordinatorFactory: diagnosticCoordinatorFactory,
                diagnosticExplainer: diagnosticExplainer,
                diagnosticEnvironment: diagnosticEnvironment,
                microphoneRuntime: microphoneRuntime
            ),
            credentials: credentials,
            settings: settings
        )
    }

    private func makeDiagnosticFixture(
        recordingActivity: any AudioDiagnosticRecordingActivityChecking =
            SettingsRecordingActivityStub(isActive: false),
        coordinator: SettingsDiagnosticCoordinatorStub? = nil,
        explainer: SettingsDiagnosticExplainerStub =
            SettingsDiagnosticExplainerStub(
                result: .failure(DeepSeekClientError.transport)
            )
    ) throws -> Fixture {
        let input = makeInputDevice(
            id: "input",
            name: "USB 麦克风",
            isSystemDefault: false
        )
        let output = makeOutputDevice(
            id: "output",
            name: "显示器音频",
            isSystemDefault: true
        )
        return try makeFixture(
            audioDeviceCatalog: StaticAudioDeviceCatalog(
                snapshot: AudioDeviceSnapshot(
                    inputs: [input],
                    outputs: [output]
                )
            ),
            recordingActivity: recordingActivity,
            diagnosticCoordinatorFactory:
                SettingsDiagnosticCoordinatorFactoryStub(
                    coordinator: coordinator
                        ?? SettingsDiagnosticCoordinatorStub(
                            report: settingsDiagnosticReport(
                                .microphoneNoFrames
                            )
                        )
                ),
            diagnosticExplainer: explainer
        )
    }

    private struct Fixture {
        let viewModel: SettingsViewModel
        let credentials: InMemoryCredentialStore
        let settings: AppSettingsStore
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: String] = [:]

    func value(for key: CredentialKey) throws -> String? {
        values[key]
    }

    func save(_ value: String, for key: CredentialKey) throws {
        values[key] = value
    }

    func delete(_ key: CredentialKey) throws {
        values[key] = nil
    }
}

private actor RecordingDeepSeekTester: DeepSeekConnectionTesting {
    private let result: Result<[String], Error>
    private var recordedAPIKeys: [String] = []

    init(result: Result<[String], Error>) {
        self.result = result
    }

    func testConnection(apiKey: String) async throws -> [String] {
        recordedAPIKeys.append(apiKey)
        return try result.get()
    }

    func apiKeys() -> [String] {
        recordedAPIKeys
    }
}

private actor RecordingNotionTester: NotionConnectionTesting {
    struct Call: Equatable, Sendable {
        let token: String
        let parentPageID: UUID
    }

    private let result: Result<NotionConnectionResult, Error>
    private var recordedCalls: [Call] = []

    init(result: Result<NotionConnectionResult, Error>) {
        self.result = result
    }

    func testConnection(
        token: String,
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        recordedCalls.append(Call(token: token, parentPageID: parentPageID))
        return try result.get()
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

private actor BlockingDeepSeekTester: DeepSeekConnectionTesting {
    private var started = false
    private var calls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<[String], Error>?

    func testConnection(apiKey: String) async throws -> [String] {
        _ = apiKey
        calls += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls
    }

    func finish(with result: Result<[String], Error>) {
        guard let resultContinuation else { return }
        self.resultContinuation = nil
        resultContinuation.resume(with: result)
    }
}

private final class SettingsMicrophoneRuntimeStub:
    MicrophoneRuntimeReporting,
    @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotValue: MicrophoneRuntimeSnapshot

    init(snapshot: MicrophoneRuntimeSnapshot) {
        snapshotValue = snapshot
    }

    func runtimeSnapshot() async -> MicrophoneRuntimeSnapshot {
        lock.withLock { snapshotValue }
    }
}

private struct StaticAudioDeviceCatalog: AudioDeviceDiscovering {
    let snapshotValue: AudioDeviceSnapshot

    init(snapshot: AudioDeviceSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot() async throws -> AudioDeviceSnapshot {
        snapshotValue
    }
}

private enum TestAudioDeviceCatalogError: Error, Sendable {
    case readFailed
}

private actor SequencedAudioDeviceCatalog: AudioDeviceDiscovering {
    private var results:
        [Result<AudioDeviceSnapshot, TestAudioDeviceCatalogError>]

    init(
        results: [Result<AudioDeviceSnapshot, TestAudioDeviceCatalogError>]
    ) {
        self.results = results
    }

    func snapshot() async throws -> AudioDeviceSnapshot {
        guard !results.isEmpty else {
            throw TestAudioDeviceCatalogError.readFailed
        }
        return try results.removeFirst().get()
    }
}

private actor BlockingAudioDeviceCatalog: AudioDeviceDiscovering {
    private var calls = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation:
        CheckedContinuation<AudioDeviceSnapshot, Never>?

    func snapshot() async throws -> AudioDeviceSnapshot {
        calls += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls
    }

    func finish(with snapshot: AudioDeviceSnapshot) {
        guard let resultContinuation else { return }
        self.resultContinuation = nil
        resultContinuation.resume(returning: snapshot)
    }
}

private actor DeviceChangeAudioDeviceCatalog: AudioDeviceDiscovering {
    private let snapshots: [AudioDeviceSnapshot]
    private var calls = 0
    private var callWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(snapshots: [AudioDeviceSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot() async throws -> AudioDeviceSnapshot {
        let snapshot = snapshots[min(calls, snapshots.count - 1)]
        calls += 1
        let ready = callWaiters.filter { calls >= $0.target }
        callWaiters.removeAll { calls >= $0.target }
        ready.forEach { $0.continuation.resume() }
        return snapshot
    }

    func waitUntilCallCount(_ target: Int) async {
        guard calls < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func callCount() -> Int {
        calls
    }
}

private actor QueuedBlockingAudioDeviceCatalog: AudioDeviceDiscovering {
    private var calls = 0
    private var resultContinuations:
        [Int: CheckedContinuation<AudioDeviceSnapshot, Never>] = [:]
    private var callWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func snapshot() async throws -> AudioDeviceSnapshot {
        calls += 1
        let call = calls
        let ready = callWaiters.filter { calls >= $0.target }
        callWaiters.removeAll { calls >= $0.target }
        ready.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { continuation in
            resultContinuations[call] = continuation
        }
    }

    func waitUntilCallCount(_ target: Int) async {
        guard calls < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func finish(call: Int, with snapshot: AudioDeviceSnapshot) {
        resultContinuations.removeValue(forKey: call)?.resume(
            returning: snapshot
        )
    }

    func callCount() -> Int {
        calls
    }
}

@MainActor
private final class SettingsAudioDeviceChangeObserver:
    AudioDeviceChangeObserving {
    private var handler: (@Sendable () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler: @escaping @Sendable () -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func sendChange() {
        handler?()
    }
}

private struct SettingsRecordingActivityStub:
    AudioDiagnosticRecordingActivityChecking {
    let isActive: Bool

    func isRecordingActive() async -> Bool {
        isActive
    }
}

private actor SettingsModelPreparerStub: TranscriptionModelPreparing {
    func prepare() async throws {}
}

private actor MutableSettingsRecordingActivityStub:
    AudioDiagnosticRecordingActivityChecking {
    private var isActive = false

    func isRecordingActive() async -> Bool {
        isActive
    }

    func setActive(_ isActive: Bool) {
        self.isActive = isActive
    }
}

private actor BlockingSettingsRecordingActivityStub:
    AudioDiagnosticRecordingActivityChecking {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func isRecordingActive() async -> Bool {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(isActive: Bool) {
        continuation?.resume(returning: isActive)
        continuation = nil
    }
}

private struct SettingsSignalTesterStub: AudioDiagnosticSignalTesting {
    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        _ = duration
        return audibleDiagnosticMetrics()
    }

    func cancel() async {}
}

private actor StreamingSettingsSignalTester: AudioDiagnosticSignalTesting {
    private var updateHandler:
        (@Sendable (AudioSignalMetrics) async -> Void)?
    private var continuation:
        CheckedContinuation<AudioSignalMetrics, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func testSignal(duration: TimeInterval) async throws -> AudioSignalMetrics {
        try await testSignal(duration: duration) { _ in }
    }

    func testSignal(
        duration: TimeInterval,
        onMetrics: @escaping @Sendable (AudioSignalMetrics) async -> Void
    ) async throws -> AudioSignalMetrics {
        _ = duration
        updateHandler = onMetrics
        hasStarted = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() async {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func publish(_ metrics: AudioSignalMetrics) async {
        await updateHandler?(metrics)
    }

    func finish(_ metrics: AudioSignalMetrics) {
        continuation?.resume(returning: metrics)
        continuation = nil
    }
}

private struct SettingsOutputTesterStub: AudioOutputTesting {
    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        AudioOutputTestResult(
            wasScheduled: true,
            duration: duration,
            outputDeviceID: nil
        )
    }

    func stop() async {}
}

private actor CountingSettingsOutputTester: AudioOutputTesting {
    private(set) var playCount = 0

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        playCount += 1
        return AudioOutputTestResult(
            wasScheduled: true,
            duration: duration,
            outputDeviceID: nil
        )
    }

    func stop() async {}
}

private actor BlockingSettingsOutputTester: AudioOutputTesting {
    private var continuation:
        CheckedContinuation<AudioOutputTestResult, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        hasStarted = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func finish() {
        continuation?.resume(
            returning: AudioOutputTestResult(
                wasScheduled: true,
                duration: 1,
                outputDeviceID: nil
            )
        )
        continuation = nil
    }
}

private actor SettingsDiagnosticCoordinatorStub:
    AudioDiagnosticCoordinating {
    private var current: AudioDiagnosticCoordinatorState = .idle
    private let report: AudioDiagnosticReport
    private(set) var cancelCount = 0
    private var cancelWaiters: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(report: AudioDiagnosticReport) {
        self.report = report
    }

    func prepare() async throws {
        current = .awaitingOutputConfirmation
    }

    func continueAfterOutputConfirmation(heardTone: Bool) async throws {
        _ = heardTone
        current = .testingMicrophone
        await Task.yield()
        current = .testingSystemAudio
        await Task.yield()
        current = .readyForUpload(report)
    }

    func cancel() async {
        cancelCount += 1
        let readyWaiters = cancelWaiters.filter { $0.target <= cancelCount }
        cancelWaiters.removeAll { $0.target <= cancelCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        current = .failed("cancelled")
    }

    func waitUntilCancelCount(_ target: Int) async {
        guard cancelCount < target else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append((target, continuation))
        }
    }

    func currentState() async -> AudioDiagnosticCoordinatorState {
        current
    }
}

private actor SettingsDiagnosticCoordinatorFactoryStub:
    AudioDiagnosticCoordinatorCreating {
    let coordinator: any AudioDiagnosticCoordinating
    private(set) var makeCount = 0

    init(coordinator: any AudioDiagnosticCoordinating) {
        self.coordinator = coordinator
    }

    func makeCoordinator() async -> any AudioDiagnosticCoordinating {
        makeCount += 1
        return coordinator
    }
}

private actor BlockingCancellationSettingsDiagnosticCoordinator:
    AudioDiagnosticCoordinating {
    private let continueOperation =
        CancellationAwareSettingsDiagnosticOperation()
    private let cleanupStarted = SettingsDiagnosticTestSignal()
    private let cleanupRelease = SettingsDiagnosticTestSignal()
    private let cleanupFinished = SettingsDiagnosticTestSignal()
    private var current: AudioDiagnosticCoordinatorState = .idle

    func prepare() async throws {
        current = .awaitingOutputConfirmation
    }

    func continueAfterOutputConfirmation(heardTone: Bool) async throws {
        _ = heardTone
        current = .testingMicrophone
        do {
            try await continueOperation.run()
        } catch {
            current = .failed("cancelled")
            throw error
        }
    }

    func cancel() async {
        cleanupStarted.signal()
        await cleanupRelease.wait()
        current = .failed("cancelled")
        cleanupFinished.signal()
    }

    func currentState() async -> AudioDiagnosticCoordinatorState {
        current
    }

    func waitUntilContinueStarted() async {
        await continueOperation.waitUntilStarted()
    }

    func waitUntilContinueCancellationWasRequested() async {
        await continueOperation.waitUntilCancellationWasRequested()
    }

    func waitUntilCleanupStarted() async {
        await cleanupStarted.wait()
    }

    nonisolated func releaseCleanup() {
        cleanupRelease.signal()
    }

    func waitUntilCleanupFinished() async {
        await cleanupFinished.wait()
    }
}

private final class CancellationAwareSettingsDiagnosticOperation:
    @unchecked Sendable {
    private let lock = NSLock()
    private let started = SettingsDiagnosticTestSignal()
    private let cancellationRequested = SettingsDiagnosticTestSignal()
    private var continuation: CheckedContinuation<Void, any Error>?

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }
                started.signal()
            }
        } onCancel: {
            cancellationRequested.signal()
            let continuation = lock.withLock { () -> CheckedContinuation<
                Void,
                any Error
            >? in
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func waitUntilCancellationWasRequested() async {
        await cancellationRequested.wait()
    }
}

private final class SettingsDiagnosticTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let currentWaiters = lock.withLock { () -> [CheckedContinuation<
            Void,
            Never
        >] in
            guard !isSignaled else { return [] }
            isSignaled = true
            let currentWaiters = waiters
            waiters.removeAll()
            return currentWaiters
        }
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !isSignaled else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor SettingsDiagnosticExplainerStub:
    AudioDiagnosticExplanationRequesting {
    struct Call: Sendable, Equatable {
        let apiKey: String
        let model: String
    }

    let result: Result<AudioDiagnosticExplanation, Error>
    private(set) var calls: [Call] = []

    init(result: Result<AudioDiagnosticExplanation, Error>) {
        self.result = result
    }

    func requestExplanation(
        apiKey: String,
        report: AudioDiagnosticReport,
        metadata: AudioDiagnosticUploadMetadata,
        model: String
    ) async throws -> AudioDiagnosticExplanation {
        _ = report
        _ = metadata
        calls.append(Call(apiKey: apiKey, model: model))
        return try result.get()
    }

    var callCount: Int {
        calls.count
    }
}

private struct SettingsDiagnosticEnvironmentStub:
    AudioDiagnosticEnvironmentInfoProviding {
    func environmentInfo() -> AudioDiagnosticEnvironmentInfo {
        AudioDiagnosticEnvironmentInfo(
            appVersion: "1.0",
            hardwareModel: "MacBook Pro M5",
            macOSVersion: "26.5"
        )
    }
}

private func settingsDiagnosticReport(
    _ issue: AudioDiagnosticIssueCode
) -> AudioDiagnosticReport {
    AudioDiagnosticReport(
        primaryIssue: issue,
        supportingIssues: [],
        facts: AudioDiagnosticFacts(
            microphonePermission: .authorized,
            screenPermission: .authorized,
            inputDeviceAvailable: true,
            outputToneWasScheduled: true,
            userHeardOutputTone: true,
            microphoneMetrics: audibleDiagnosticMetrics(),
            systemAudioMetrics: audibleDiagnosticMetrics(),
            historicalPlaybackFailed: false,
            microphoneTestOutcome: .succeeded,
            systemAudioTestOutcome: .succeeded
        )
    )
}

private func audibleDiagnosticMetrics(
    sampleCount: Int = 144_000
) -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: sampleCount,
        rms: 0.1,
        peak: 0.2,
        observationDuration: Double(sampleCount) / 48_000,
        sampleRate: 48_000,
        channelCount: 1,
        level: .audible
    )
}

private func makeInputDevice(
    id: String,
    name: String,
    isConnected: Bool = true,
    isSuspended: Bool = false,
    isSystemDefault: Bool = false
) -> AudioInputDevice {
    AudioInputDevice(
        id: id,
        name: name,
        manufacturer: "Test",
        isConnected: isConnected,
        isSuspended: isSuspended,
        isInUseByAnotherApplication: false,
        isSystemDefault: isSystemDefault
    )
}

private func makeOutputDevice(
    id: String,
    name: String,
    isConnected: Bool = true,
    isSystemDefault: Bool = false
) -> AudioOutputDevice {
    AudioOutputDevice(
        id: id,
        name: name,
        isConnected: isConnected,
        isSystemDefault: isSystemDefault
    )
}
