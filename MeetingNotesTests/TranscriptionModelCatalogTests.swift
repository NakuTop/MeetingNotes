import XCTest
@testable import MeetingNotes

final class TranscriptionModelCatalogTests: XCTestCase {
    func testBalancedDescriptorAndDisplayName() {
        let descriptor = TranscriptionModelCatalog.descriptor(for: .balanced)

        XCTAssertEqual(TranscriptionQualityMode.balanced.displayName, "平衡")
        XCTAssertEqual(descriptor.mode, .balanced)
        XCTAssertEqual(
            descriptor.modelID,
            "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page"
        )
        XCTAssertEqual(descriptor.directoryName, "balanced")
        XCTAssertEqual(descriptor.detail, "默认，速度和资源占用更均衡")
    }

    func testHighAccuracyDescriptorAndDisplayName() {
        let descriptor = TranscriptionModelCatalog.descriptor(for: .highAccuracy)

        XCTAssertEqual(
            TranscriptionQualityMode.highAccuracy.displayName,
            "高精度"
        )
        XCTAssertEqual(descriptor.mode, .highAccuracy)
        XCTAssertEqual(
            descriptor.modelID,
            "openai_whisper-large-v3-v20240930_626MB"
        )
        XCTAssertEqual(descriptor.directoryName, "high-accuracy")
        XCTAssertEqual(descriptor.detail, "更高多语言精度，下载和处理时间更长")
    }
}
