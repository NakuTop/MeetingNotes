import Foundation
import XCTest

/// Source contracts only: these checks never launch a window or claim GUI acceptance.
final class SimpleSpeakerWorkflowContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testMeetingOffersSingleAutomaticRetryWithoutReviewOrEnrollmentWorkflow() throws {
        let view = try source("MeetingNotes/Views/MeetingDetailView.swift")
        XCTAssertTrue(view.contains("startSpeakerDiarizationRetry(speakerCount: .automatic)"))
        XCTAssertEqual(view.components(separatedBy: "meeting.speakerDiarization.retry\"").count - 1, 1)
        for removed in ["MeetingSpeakerReviewView(", "VoiceprintLibraryView(", "speakerCount: .exact",
                        "speakerCount: .range", "speakerCountLabel", "onVoiceprint:"] {
            XCTAssertFalse(view.contains(removed), removed)
        }
        XCTAssertTrue(view.contains("viewModel.assignSpeaker(to:"))
        XCTAssertTrue(view.contains("viewModel.renameSpeaker("))
    }

    func testDirectLabelMenuKeepsAssignmentRenameAndRestoreWithoutExtraReviewSteps() throws {
        let view = try source("MeetingNotes/Views/TranscriptView.swift")
        XCTAssertTrue(view.contains("onAssignSpeaker?(editTarget, option.speakerID, false)"))
        XCTAssertTrue(view.contains("onAssignSpeaker?(editTarget, nil, true)"))
        XCTAssertTrue(view.contains("onAssignSpeaker?(editTarget, nil, false)"))
        XCTAssertTrue(view.contains("beginEditing(speakerID: speakerID, badge: speakerBadge)"))
        XCTAssertFalse(view.contains("onVoiceprint"))
        XCTAssertFalse(view.contains("确认候选"))
        XCTAssertFalse(view.contains("hint.reason.label"))
    }

    func testSettingsRetainsExistingDataManagementBehindCollapsedDisclosure() throws {
        let view = try source("MeetingNotes/Views/SettingsView.swift")
        let app = try source("MeetingNotes/App/MeetingNotesApp.swift")
        let container = try source("MeetingNotes/App/AppContainer.swift")
        XCTAssertTrue(view.contains("自动识别说话人"))
        XCTAssertTrue(view.contains("DisclosureGroup(\"高级数据管理\")"))
        XCTAssertTrue(view.contains("voiceprintPanel = makeVoiceprintManagementPanel()"))
        XCTAssertTrue(view.contains("VoiceprintLibraryView(model: panel)"))
        XCTAssertTrue(app.contains("container.makeVoiceprintManagementPanel"))
        XCTAssertTrue(container.contains("selection: nil, onConfirmName: { _ in false }"))
        XCTAssertFalse(view.contains("试验功能"))
        XCTAssertFalse(view.contains("默认关闭，所有分离"))
    }
}
