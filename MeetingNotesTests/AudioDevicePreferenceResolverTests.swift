import XCTest
@testable import MeetingNotes

final class AudioDevicePreferenceResolverTests: XCTestCase {
    func testPreferredConnectedInputWins() {
        let builtIn = input(id: "built-in", isSystemDefault: true)
        let usb = input(id: "usb")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: "usb",
                devices: [builtIn, usb]
            ),
            .preferred(usb)
        )
    }

    func testMissingInputFallsBackToSystemDefaultAndPreservesPreferredID() {
        let builtIn = input(id: "built-in", isSystemDefault: true)

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: "missing",
                devices: [builtIn]
            ),
            .fallback(
                selected: builtIn,
                unavailablePreferredID: "missing"
            )
        )
    }

    func testSuspendedPreferredInputFallsBackToUsableDevice() {
        let suspended = input(id: "usb", isSuspended: true)
        let available = input(id: "built-in")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: "usb",
                devices: [suspended, available]
            ),
            .fallback(
                selected: available,
                unavailablePreferredID: "usb"
            )
        )
    }

    func testNoUsableInputIsUnavailable() {
        let disconnected = input(id: "disconnected", isConnected: false)
        let suspended = input(id: "suspended", isSuspended: true)

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: "missing",
                devices: [disconnected, suspended]
            ),
            .unavailable
        )
    }

    func testPreferredConnectedOutputWins() {
        let display = output(id: "display", isSystemDefault: true)
        let headphones = output(id: "headphones")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: "headphones",
                devices: [display, headphones]
            ),
            .preferred(headphones)
        )
    }

    func testMissingOutputFallsBackToSystemDefaultAndPreservesPreferredID() {
        let display = output(id: "display", isSystemDefault: true)

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: "missing",
                devices: [display]
            ),
            .fallback(
                selected: display,
                unavailablePreferredID: "missing"
            )
        )
    }

    func testDisconnectedPreferredOutputFallsBackToUsableDevice() {
        let disconnected = output(id: "headphones", isConnected: false)
        let available = output(id: "display")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: "headphones",
                devices: [disconnected, available]
            ),
            .fallback(
                selected: available,
                unavailablePreferredID: "headphones"
            )
        )
    }

    func testNoUsableOutputIsUnavailable() {
        let disconnected = output(id: "headphones", isConnected: false)

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: nil,
                devices: [disconnected]
            ),
            .unavailable
        )
    }

    func testSystemDefaultInputIsSelectedWithoutPreference() {
        let first = input(id: "usb")
        let builtIn = input(id: "built-in", isSystemDefault: true)

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: nil,
                devices: [first, builtIn]
            ),
            .systemDefault(builtIn)
        )
    }

    func testSystemDefaultOutputIsSelectedWithoutPreference() {
        let first = output(id: "headphones")
        let display = output(id: "display", isSystemDefault: true)

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: nil,
                devices: [first, display]
            ),
            .systemDefault(display)
        )
    }

    func testFirstUsableInputIsSelectedDeterministicallyWithoutDefault() {
        let disconnected = input(id: "disconnected", isConnected: false)
        let firstUsable = input(id: "usb")
        let secondUsable = input(id: "built-in")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: nil,
                devices: [disconnected, firstUsable, secondUsable]
            ),
            .firstUsable(firstUsable)
        )
    }

    func testFirstUsableOutputIsSelectedDeterministicallyWithoutDefault() {
        let disconnected = output(id: "disconnected", isConnected: false)
        let firstUsable = output(id: "headphones")
        let secondUsable = output(id: "display")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: nil,
                devices: [disconnected, firstUsable, secondUsable]
            ),
            .firstUsable(firstUsable)
        )
    }

    func testUnusableSystemDefaultInputIsSkippedForFirstUsableInput() {
        let suspendedDefault = input(
            id: "default",
            isSuspended: true,
            isSystemDefault: true
        )
        let firstUsable = input(id: "usb")
        let secondUsable = input(id: "built-in")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveInput(
                preferredID: nil,
                devices: [suspendedDefault, firstUsable, secondUsable]
            ),
            .firstUsable(firstUsable)
        )
    }

    func testUnusableSystemDefaultOutputIsSkippedForFirstUsableOutput() {
        let disconnectedDefault = output(
            id: "default",
            isConnected: false,
            isSystemDefault: true
        )
        let firstUsable = output(id: "headphones")
        let secondUsable = output(id: "display")

        XCTAssertEqual(
            AudioDevicePreferenceResolver.resolveOutput(
                preferredID: nil,
                devices: [disconnectedDefault, firstUsable, secondUsable]
            ),
            .firstUsable(firstUsable)
        )
    }

    func testInputIsUsableOnlyWhenConnectedAndNotSuspended() {
        XCTAssertTrue(input(id: "usable").isUsable)
        XCTAssertFalse(input(id: "disconnected", isConnected: false).isUsable)
        XCTAssertFalse(input(id: "suspended", isSuspended: true).isUsable)
    }

    func testInputInUseByAnotherApplicationRemainsUsable() {
        XCTAssertTrue(
            input(
                id: "in-use",
                isInUseByAnotherApplication: true
            ).isUsable
        )
    }

    func testOutputIsUsableOnlyWhenConnected() {
        XCTAssertTrue(output(id: "usable").isUsable)
        XCTAssertFalse(output(id: "disconnected", isConnected: false).isUsable)
    }

    private func input(
        id: String,
        isConnected: Bool = true,
        isSuspended: Bool = false,
        isInUseByAnotherApplication: Bool = false,
        isSystemDefault: Bool = false
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: id,
            manufacturer: "Test",
            isConnected: isConnected,
            isSuspended: isSuspended,
            isInUseByAnotherApplication: isInUseByAnotherApplication,
            isSystemDefault: isSystemDefault
        )
    }

    private func output(
        id: String,
        isConnected: Bool = true,
        isSystemDefault: Bool = false
    ) -> AudioOutputDevice {
        AudioOutputDevice(
            id: id,
            name: id,
            isConnected: isConnected,
            isSystemDefault: isSystemDefault
        )
    }
}
