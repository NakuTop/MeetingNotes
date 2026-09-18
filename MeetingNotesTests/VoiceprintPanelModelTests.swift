import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
private final class VoiceprintNoNetwork: SummarizeAndArchiving, MeetingTitleUpdating {
    func execute(meetingID: UUID) async throws { XCTFail("Voiceprint flow must not upload") }
    func updateTitle(meetingID: UUID, title: String) async throws { XCTFail("Voiceprint flow must not upload") }
}

@MainActor
final class VoiceprintPanelModelTests: XCTestCase {
    private final class SaveSwitch { var fails = false }
    private var pcm: [Float] { [Float](repeating: 0.1, count: 80_000) }
    private func settings() -> AppSettingsStore {
        let suite = "VoiceprintPanelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettingsStore(defaults: defaults)
    }
    private func reader() -> VoiceprintClipReader {
        .init(reader: VoiceprintTestReader([.init(samples: pcm, startingAt: 0)]))
    }

    func testSettingsAreOptInAndRapidToggleHonorsLatestValue() async throws {
        let settings = settings()
        XCTAssertFalse(settings.localVoiceprintsEnabled)
        let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor())
        let model = VoiceprintPanelModel(library: library, reader: reader(), settings: settings,
                                        selection: nil) { _ in XCTFail(); return false }
        model.setEnabled(true)
        model.setEnabled(false)
        model.load()
        await model.operation?.value // waits for the most recent configuration update
        XCTAssertFalse(model.enabled)
        do { _ = try await library.suggest(samples: pcm); XCTFail() }
        catch { XCTAssertEqual(error as? VoiceprintError, .disabled) }
    }

    func testManagementOnlyPanelCanDeleteExistingDataWithoutEnablingOrMatching() async throws {
        let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "之前录入的人", samples: pcm, consent: true)
        await library.setEnabled(false)
        let model = VoiceprintPanelModel(library: library, reader: reader(), settings: settings(),
            selection: nil) { _ in XCTFail("Data management must never assign an identity"); return false }
        model.load()
        await model.operation?.value
        XCTAssertFalse(model.enabled)
        XCTAssertEqual(model.profiles.count, 1)
        model.enrollmentName = "不应录入"
        model.enrollmentConsent = true
        model.enroll()
        model.match()
        XCTAssertNil(model.operation)
        XCTAssertNil(model.suggestion)
        model.delete(try XCTUnwrap(model.profiles.first))
        await model.operation?.value
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertFalse(model.enabled)
    }

    func testSuggestionRequiresExplicitClickAndNeverAutomaticallyAppliesName() async throws {
        let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "测试姓名", samples: pcm, consent: true)
        let settings = settings()
        settings.localVoiceprintsEnabled = true
        var names: [String] = []
        let model = VoiceprintPanelModel(library: library, reader: reader(), settings: settings,
            selection: .init(meetingID: UUID(), start: 0, end: 5, canEnroll: false)) { names.append($0); return true }
        model.match()
        await model.operation?.value
        XCTAssertEqual(model.suggestion?.name, "测试姓名")
        XCTAssertTrue(names.isEmpty)
        model.confirmSuggestion()
        await model.operation?.value
        XCTAssertEqual(names, ["测试姓名"])
        XCTAssertNil(model.suggestion)
        model.confirmSuggestion()
        XCTAssertEqual(names.count, 1)
    }

    func testCancelOrDisableDiscardsLateMatchWithoutUIOrIdentityMutation() async throws {
        for disable in [false, true] {
            let store = VoiceprintTestStore()
            try store.save([.init(id: UUID(), name: "不应应用", modelID: VoiceprintEmbedding.currentModelID,
                embedding: [Float](repeating: 1, count: 256), speechSeconds: 5, createdAt: .now)])
            let extractor = VoiceprintBlockedExtractor()
            let library = LocalVoiceprintLibrary(store: store, extractor: extractor, enabled: true)
            let settings = settings()
            settings.localVoiceprintsEnabled = true
            let model = VoiceprintPanelModel(library: library, reader: reader(), settings: settings,
                selection: .init(meetingID: UUID(), start: 0, end: 5, canEnroll: false)) { _ in XCTFail(); return false }
            model.match()
            let task = model.operation
            await extractor.waitUntilEntered()
            if disable { model.setEnabled(false) } else { model.cancel() }
            let message = model.message
            await extractor.release()
            await task?.value
            XCTAssertNil(model.suggestion)
            XCTAssertFalse(model.isWorking)
            XCTAssertEqual(model.message, message, "Old completion must not change current UI")
        }
    }

    func testDeletedSuggestionCannotBeConfirmed() async throws {
        let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor(), enabled: true)
        try await library.enroll(name: "已删除", samples: pcm, consent: true)
        let settings = settings()
        settings.localVoiceprintsEnabled = true
        let model = VoiceprintPanelModel(library: library, reader: reader(), settings: settings,
            selection: .init(meetingID: UUID(), start: 0, end: 5, canEnroll: false)) { _ in XCTFail(); return false }
        model.match()
        await model.operation?.value
        XCTAssertNotNil(model.suggestion)
        try await library.deleteAll()
        model.confirmSuggestion()
        await model.operation?.value
        XCTAssertNil(model.suggestion)
        XCTAssertNotNil(model.message)
    }

    func testConfirmedNameChangesOnlySelectedUnknownTurnAndSurvivesFailedSave() async throws {
        for failSave in [false, true] {
            let control = SaveSwitch()
            let repository = try MeetingRepository.inMemory(contextSaver: {
                if control.fails { throw VoiceprintError.storageUnavailable }; try $0.save()
            })
            let id = try repository.createMeeting(mode: .offline, startedAt: .now)
            for index in 0..<2 {
                try repository.appendTranscript(meetingID: id, start: Double(index * 5),
                    end: Double(index * 5 + 5), text: "保持原始文字")
            }
            try repository.finalizeMeeting(id: id, endedAt: .now, activeDuration: 10)
            let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor(), enabled: true)
            try await library.enroll(name: "明确确认", samples: pcm, consent: true)
            let settings = settings()
            settings.localVoiceprintsEnabled = true
            let noNetwork = VoiceprintNoNetwork()
            let viewModel = MeetingDetailViewModel(meetingID: id, repository: repository, settingsStore: settings,
                action: noNetwork, titleUpdater: noNetwork, voiceprintLibrary: library, voiceprintReader: reader())
            let entry = try XCTUnwrap(repository.canonicalTranscripts(meetingID: id).first)
            let panel = try XCTUnwrap(viewModel.voiceprintPanel(for: .init(entry: entry)))
            XCTAssertFalse(try XCTUnwrap(panel.selection).canEnroll)
            panel.match()
            await panel.operation?.value
            XCTAssertNil(try repository.transcripts(meetingID: id).first?.speakerID)
            control.fails = failSave
            panel.confirmSuggestion()
            await panel.operation?.value
            let rows = try repository.transcripts(meetingID: id)
            XCTAssertNil(rows[1].speakerID)
            XCTAssertEqual(rows.map(\.text), ["保持原始文字", "保持原始文字"])
            if failSave {
                XCTAssertNil(rows[0].speakerID)
                XCTAssertTrue(try repository.speakerDisplayNames(meetingID: id).isEmpty)
            } else {
                XCTAssertEqual(rows[0].attributionStatus, .manuallyAssigned)
                XCTAssertEqual(try repository.speakerDisplayNames(meetingID: id)[rows[0].speakerID!], "明确确认")
            }
        }
    }

    func testEnrollmentRequiresFinishedCleanExplicitlyAssignedTurn() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now)
        try repository.appendTranscript(meetingID: id, start: 0, end: 5, text: "测试")
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        let library = LocalVoiceprintLibrary(store: VoiceprintTestStore(), extractor: VoiceprintTestExtractor())
        let noNetwork = VoiceprintNoNetwork()
        let viewModel = MeetingDetailViewModel(meetingID: id, repository: repository, settingsStore: settings(),
            action: noNetwork, titleUpdater: noNetwork, voiceprintLibrary: library, voiceprintReader: reader())
        let entry = try XCTUnwrap(repository.canonicalTranscripts(meetingID: id).first)
        let target = MeetingTranscriptEditTarget(entry: entry)
        XCTAssertNil(viewModel.voiceprintPanel(for: target)?.selection)
        try repository.finalizeMeeting(id: id, endedAt: .now, activeDuration: 5)
        row.attributionStatus = .overlapping
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [row.id], speakerID: nil, createNew: true)
        XCTAssertFalse(try XCTUnwrap(viewModel.voiceprintPanel(for: target)?.selection).canEnroll)
        XCTAssertFalse(try XCTUnwrap(viewModel.voiceprintPanel(for: target)?.selection).canMatch)
        row.automaticSpeakerStatusRawValue = nil
        XCTAssertTrue(try XCTUnwrap(viewModel.voiceprintPanel(for: target)?.selection).canEnroll)
        row.sourceEvidence = .possibleEcho
        XCTAssertFalse(try XCTUnwrap(viewModel.voiceprintPanel(for: target)?.selection).canEnroll)
    }
}
