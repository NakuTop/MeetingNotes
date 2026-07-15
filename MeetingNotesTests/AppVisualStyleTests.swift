import XCTest
@testable import MeetingNotes

final class AppVisualStyleTests: XCTestCase {
    func testLiquidGlassStartsAtMacOS26() {
        XCTAssertEqual(
            AppVisualPolicy.treatment(forMajorVersion: 25),
            .material
        )
        XCTAssertEqual(
            AppVisualPolicy.treatment(forMajorVersion: 26),
            .liquidGlass
        )
    }

    func testReducedMotionRemovesScaleAndSpring() {
        XCTAssertEqual(
            AppVisualPolicy.motion(reduceMotion: true),
            AppMotionProfile(duration: 0.12, scale: 1, usesSpring: false)
        )
        XCTAssertEqual(
            AppVisualPolicy.motion(reduceMotion: false),
            AppMotionProfile(
                duration: 0.24,
                scale: 0.985,
                usesSpring: true
            )
        )
    }
}
