import AppKit
import Foundation
import Testing
import YumYumCore
@testable import YumYumApp

@Suite
struct AppThemeTests {
    @Test
    func savesLoadsAndDefaultsToDark() throws {
        let suite = try #require(UserDefaults(suiteName: #function))
        suite.removePersistentDomain(forName: #function)

        #expect(AppTheme.load(defaults: suite) == .dark)
        suite.set("invalid", forKey: AppTheme.defaultsKey)
        #expect(AppTheme.load(defaults: suite) == .dark)

        AppTheme.light.save(defaults: suite)
        #expect(AppTheme.load(defaults: suite) == .light)
        AppTheme.dark.save(defaults: suite)
        #expect(AppTheme.load(defaults: suite) == .dark)
    }

    @Test
    func lightPaletteIsOpaqueWhiteAndDarkPaletteIsUnchanged() {
        #expect(AppTheme.light.palette.surface == NSColor(calibratedWhite: 1, alpha: 1))
        #expect(AppTheme.light.palette.secondarySurface == NSColor(calibratedWhite: 0.97, alpha: 1))
        #expect(AppTheme.light.palette.text == NSColor(calibratedWhite: 0.10, alpha: 0.94))
        #expect(AppTheme.light.palette.secondaryText == NSColor(calibratedWhite: 0.28, alpha: 1))
        #expect(AppTheme.light.palette.border == NSColor(calibratedWhite: 0, alpha: 0.14))
        #expect(AppTheme.light.palette.shadow == NSColor(calibratedWhite: 0, alpha: 0.16))
        #expect(AppTheme.dark.palette.surface == NSColor(calibratedWhite: 0.14, alpha: 0.96))
        #expect(AppTheme.dark.palette.secondarySurface == NSColor(calibratedWhite: 0.25, alpha: 0.92))
        #expect(AppTheme.dark.palette.userMessage == NSColor(
            calibratedRed: 0.35,
            green: 0.65,
            blue: 1,
            alpha: 0.24
        ))
        #expect(AppTheme.dark.palette.text == NSColor(calibratedWhite: 1.00, alpha: 0.94))
        #expect(AppTheme.dark.palette.error == NSColor(
            calibratedRed: 1,
            green: 0.38,
            blue: 0.42,
            alpha: 1
        ))
        for theme in AppTheme.allCases {
            let primary = theme.palette.primaryAction
            let secondary = theme.palette.secondaryAction
            let primaryHSB = hsb(primary)
            let secondaryHSB = hsb(secondary)

            #expect(primary != secondary)
            #expect(warmChannels(primary))
            #expect(warmChannels(secondary))
            #expect(primaryHSB.saturation > secondaryHSB.saturation)
            #expect(hueDistance(primaryHSB.hue, secondaryHSB.hue) < 0.08)
            #expect(abs(primaryHSB.brightness - secondaryHSB.brightness) < 0.22)
            #expect(contrastRatio(primary, .white) >= 4.5)
            #expect(contrastRatio(
                secondary,
                theme == .light ? theme.palette.text : .white
            ) >= 4.5)
        }
    }

    @Test
    @MainActor
    func openChatAppliesThemeWithoutReplacingContentOrScrollPosition() throws {
        let controller = QuickMenuViewController()
        controller.loadView()
        controller.render(
            state: ChatBubbleState(
                draftText: "draft",
                draftAttachments: [
                    ChatDraftAttachment(
                        url: URL(fileURLWithPath: "/tmp/theme.txt"),
                        isTemporary: false
                    ),
                ],
                messages: [
                    ChatMessage(role: .user, text: "question"),
                    ChatMessage(role: .assistant, text: "**answer**"),
                ]
            ),
            canRetry: true,
            agentNotice: nil
        )
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(of: controller.view, as: NSScrollView.self).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 12))
        let origin = scroll.contentView.bounds.origin
        controller.applyTheme(.light)
        let lightColors = layerBackgroundColors(in: controller.view)

        controller.applyTheme(.dark)

        #expect(layerBackgroundColors(in: controller.view) != lightColors)
        #expect(scroll.contentView.bounds.origin == origin)
        let text = descendants(of: controller.view, as: NSTextField.self)
            .map(\.stringValue)
        #expect(text.contains("draft"))
        #expect(text.contains("question"))
        #expect(text.contains("answer"))
    }

    @Test
    @MainActor
    func themesMarkdownErrorDisabledAndLayerBackedRows() throws {
        let controller = QuickMenuViewController()
        controller.loadView()
        controller.render(
            state: ChatBubbleState(
                draftText: "",
                draftAttachments: [
                    ChatDraftAttachment(
                        url: URL(fileURLWithPath: "/tmp/theme.txt"),
                        isTemporary: false
                    ),
                ],
                messages: [
                    ChatMessage(role: .user, text: "question"),
                    ChatMessage(role: .assistant, text: "**answer**"),
                ],
                phase: .failed("failed")
            ),
            canRetry: false,
            agentNotice: nil
        )

        controller.applyTheme(.light)

        let fields = descendants(of: controller.view, as: NSTextField.self)
        let markdown = try #require(fields.first { $0.stringValue == "answer" })
        let error = try #require(
            fields.first { $0.accessibilityLabel() == "YumYum 상태" }
        )
        let send = try #require(
            descendants(of: controller.view, as: NSButton.self)
                .first { $0.title == "보내기" }
        )
        let markdownColor = markdown.attributedStringValue.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        #expect(markdownColor == AppTheme.light.palette.text)
        #expect(error.textColor == AppTheme.light.palette.error)
        #expect(error.textColor != AppTheme.light.palette.secondaryText)
        #expect(layerBackgroundColors(in: controller.view).contains(
            AppTheme.light.palette.secondarySurface.cgColor
        ))
        #expect(layerBackgroundColors(in: controller.view).contains(
            AppTheme.light.palette.userMessage.cgColor
        ))
        controller.render(
            state: ChatBubbleState(
                draftText: "busy",
                phase: .sending(UUID())
            ),
            canRetry: false,
            agentNotice: nil
        )
        #expect(!send.isEnabled)
    }

    @Test
    @MainActor
    func responseThemesIndependentSurfacesWithoutReplacingScrollState() throws {
        let controller = ResponseBubbleViewController()
        controller.loadView()
        controller.render(PetResponseContent(
            fullText: String(repeating: "response\n", count: 80),
            displayText: String(repeating: "response\n", count: 80),
            isExcerpt: false,
            showsOpenChat: true
        ))
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try #require(
            descendants(of: controller.view, as: NSScrollView.self).first
        )
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 16))
        let origin = scroll.contentView.bounds.origin

        controller.applyTheme(.light)

        let inline = try #require(descendants(of: controller.view, as: NSView.self).first {
            $0.identifier?.rawValue == "response-inline-action-surface"
        })
        let detail = try #require(descendants(of: controller.view, as: NSView.self).first {
            $0.identifier?.rawValue == "response-detail-action-surface"
        })
        #expect(controller.view.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(layerBackgroundColors(in: inline).contains(
            AppTheme.light.palette.primaryAction.cgColor
        ))
        #expect(layerBackgroundColors(in: detail).contains(
            AppTheme.light.palette.secondaryAction.cgColor
        ))
        #expect(scroll.contentView.bounds.origin == origin)

        controller.applyTheme(.dark)
        #expect(layerBackgroundColors(in: inline).contains(
            AppTheme.dark.palette.primaryAction.cgColor
        ))
        #expect(layerBackgroundColors(in: detail).contains(
            AppTheme.dark.palette.secondaryAction.cgColor
        ))
        #expect(scroll.contentView.bounds.origin == origin)
    }

    @MainActor
    private func descendants<T: NSView>(
        of view: NSView,
        as type: T.Type
    ) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants(of: $0, as: type) }
    }

    @MainActor
    private func layerBackgroundColors(in view: NSView) -> [CGColor] {
        [view.layer?.backgroundColor].compactMap { $0 }
            + view.subviews.flatMap(layerBackgroundColors)
    }

    private func hsb(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: nil
        )
        return (hue, saturation, brightness)
    }

    private func warmChannels(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return rgb.redComponent > rgb.greenComponent
            && rgb.greenComponent > rgb.blueComponent
    }

    private func hueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    private func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
