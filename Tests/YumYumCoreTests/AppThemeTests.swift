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
    func lightResponseDisablesVibrancyWithoutReplacingScrollState() throws {
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

        let effect = try #require(
            descendants(of: controller.view, as: NSView.self).first {
                $0.identifier?.rawValue == "YumYumGlassBackground"
            }
        )
        #expect(effect.isHidden)
        #expect(controller.view.layer?.backgroundColor
            == AppTheme.light.palette.surface.cgColor)
        #expect(scroll.contentView.bounds.origin == origin)

        controller.applyTheme(.dark)
        #expect(!effect.isHidden)
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
}
