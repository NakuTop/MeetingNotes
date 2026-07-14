import Foundation

@MainActor
final class FloatingPanelPresenter: RecordingPanelPresenting {
    private let controller: FloatingPanelController

    init(controller: FloatingPanelController) {
        self.controller = controller
    }

    func show() async {
        controller.setPaused(false)
        controller.show()
    }

    func hide() async {
        controller.hide()
    }

    func setPaused(_ isPaused: Bool) {
        controller.setPaused(isPaused)
    }
}
