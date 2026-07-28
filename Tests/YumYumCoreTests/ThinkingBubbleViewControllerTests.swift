import AppKit
import Testing
@testable import YumYumApp

@Suite
struct ThinkingBubbleViewControllerTests {
    @Test
    @MainActor
    func usesBlackForeground() throws {
        let controller = ThinkingBubbleViewController()
        controller.loadView()
        let label = try #require(textField(in: controller.view))
        label.textColor = .white

        controller.loadView()

        #expect(label.textColor == .black)
    }

    @MainActor
    private func textField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        return view.subviews.lazy.compactMap(textField).first
    }
}
