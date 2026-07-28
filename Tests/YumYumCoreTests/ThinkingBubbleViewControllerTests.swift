import AppKit
import Testing
@testable import YumYumApp

@Suite
struct ThinkingBubbleViewControllerTests {
    @Test
    @MainActor
    func appliesLightSurfaceAndDarkForeground() throws {
        let controller = ThinkingBubbleViewController()
        controller.loadView()
        controller.applyTheme(.light)
        let label = try #require(textField(in: controller.view))
        let backgroundColor = try #require(controller.view.layer?.backgroundColor)
        let background = try #require(NSColor(cgColor: backgroundColor))
            .usingColorSpace(.deviceRGB)
        let foreground = try #require(label.textColor?.usingColorSpace(.deviceRGB))

        #expect(try #require(background?.redComponent) > 0.9)
        #expect(try #require(background?.greenComponent) > 0.9)
        #expect(try #require(background?.blueComponent) > 0.9)
        #expect(try #require(background?.alphaComponent) >= 0.9)
        #expect(foreground.redComponent < 0.2)
        #expect(foreground.greenComponent < 0.2)
        #expect(foreground.blueComponent < 0.2)
    }

    @MainActor
    private func textField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        return view.subviews.lazy.compactMap(textField).first
    }
}
