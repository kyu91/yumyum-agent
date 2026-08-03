import AppKit
import Foundation
import SwiftUI
import Testing
import YumYumCore
@testable import YumYumApp

extension AppGlobalStateTests {
@Suite
@MainActor
struct AppThemeTests {
    @Test
    @MainActor
    func registeredSettingsWindowUpdatesInBothDirections() {
        let previousLanguage = AppText.language
        defer { AppText.setLanguage(previousLanguage) }
        _ = NSApplication.shared
        let window = NSWindow()
        defer {
            window.contentViewController = nil
            window.orderOut(nil)
        }
        let appDelegate = YumYumAppDelegate()
        let hostingController = NSHostingController(
            rootView: MainWindowRegistrationViewRepresentable(appDelegate: appDelegate)
        )
        window.contentViewController = hostingController
        hostingController.view.layoutSubtreeIfNeeded()

        #expect(window.appearance?.name == AppTheme.dark.appearance?.name)

        appDelegate.setTheme(.light)
        #expect(window.appearance?.name == AppTheme.light.appearance?.name)

        appDelegate.setTheme(.dark)
        #expect(window.appearance?.name == AppTheme.dark.appearance?.name)
    }

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
    func chatPaletteIsWarmDistinctAndReadable() {
        let light = AppTheme.light.palette
        let dark = AppTheme.dark.palette

        #expect(light.surface == NSColor(calibratedWhite: 1, alpha: 1))
        #expect(light.secondarySurface == NSColor(calibratedWhite: 0.97, alpha: 1))
        #expect(light.text == NSColor(calibratedWhite: 0.10, alpha: 0.94))
        #expect(light.secondaryText == NSColor(calibratedWhite: 0.28, alpha: 1))
        #expect(light.border == NSColor(calibratedWhite: 0, alpha: 0.14))
        #expect(light.shadow == NSColor(calibratedWhite: 0, alpha: 0.16))
        #expect(dark.surface == NSColor(calibratedWhite: 0.14, alpha: 0.96))
        #expect(dark.secondarySurface == NSColor(calibratedWhite: 0.25, alpha: 0.92))
        #expect(dark.text == NSColor(calibratedWhite: 1.00, alpha: 0.94))
        #expect(dark.secondaryText == NSColor(calibratedWhite: 1.00, alpha: 0.68))
        #expect(dark.border == NSColor(calibratedWhite: 1.00, alpha: 0.18))
        #expect(dark.shadow == .clear)
        #expect(warmChannels(light.chatCanvas))
        #expect(warmChannels(light.assistantMessage))
        #expect(warmChannels(light.userMessage))
        #expect(warmChannels(light.composerSurface))
        #expect(warmChannels(light.auxiliarySurface))
        #expect(contrastRatio(light.chatText, light.assistantMessage) >= 4.5)
        #expect(contrastRatio(light.chatText, light.userMessage) >= 4.5)
        #expect(contrastRatio(light.chatSecondaryText, light.chatCanvas) >= 4.5)
        #expect(warmChannels(dark.chatCanvas))
        #expect(warmChannels(dark.assistantMessage))
        #expect(warmChannels(dark.userMessage))
        #expect(warmChannels(dark.composerSurface))
        #expect(warmChannels(dark.auxiliarySurface))
        #expect(contrastRatio(dark.chatText, dark.assistantMessage) >= 4.5)
        #expect(contrastRatio(dark.chatText, dark.userMessage) >= 4.5)
        #expect(contrastRatio(dark.chatSecondaryText, dark.chatCanvas) >= 4.5)

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
        #expect(descendants(of: controller.view, as: NSButton.self)
            .first { $0.title == "재시도" }?.isHidden == false)
    }

    @Test
    @MainActor
    func emptyChatUpdatesThemeBothDirectionsWithoutReplacingDraftOrScroll() throws {
        let controller = QuickMenuViewController()
        controller.loadView()
        controller.render(
            state: ChatBubbleState(draftText: "preserved draft"),
            canRetry: false,
            agentNotice: nil
        )
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(of: controller.view, as: NSScrollView.self).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 3))
        let origin = scroll.contentView.bounds.origin
        let empty = try #require(
            descendants(of: controller.view, as: NSTextField.self)
                .first { $0.accessibilityLabel() == "아직 대화가 없습니다" }
        )
        let composer = try #require(
            descendants(of: controller.view, as: NSTextField.self)
                .first { $0.accessibilityLabel() == "대화 메시지" }
        )

        controller.applyTheme(.light)
        #expect(empty.textColor == AppTheme.light.palette.chatSecondaryText)
        #expect(contrastRatio(empty.textColor!, AppTheme.light.palette.chatCanvas) >= 4.5)
        controller.applyTheme(.dark)
        #expect(empty.textColor == AppTheme.dark.palette.chatSecondaryText)
        #expect(contrastRatio(empty.textColor!, AppTheme.dark.palette.chatCanvas) >= 4.5)
        controller.applyTheme(.light)
        #expect(empty.textColor == AppTheme.light.palette.chatSecondaryText)
        #expect(composer.stringValue == "preserved draft")
        #expect(scroll.contentView.bounds.origin == origin)
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

        #expect(controller.view.layer?.backgroundColor == AppTheme.light.palette.chatCanvas.cgColor)
        let fields = descendants(of: controller.view, as: NSTextField.self)
        let markdown = try #require(fields.first { $0.stringValue == "answer" })
        let error = try #require(
            fields.first { $0.accessibilityLabel() == "YumYum Agent 상태" }
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
        #expect(markdownColor == AppTheme.light.palette.chatText)
        #expect(error.textColor == AppTheme.light.palette.error)
        #expect(error.textColor != AppTheme.light.palette.chatSecondaryText)
        #expect(layerBackgroundColors(in: controller.view).contains(
            AppTheme.light.palette.assistantMessage.cgColor
        ))
        #expect(layerBackgroundColors(in: controller.view).contains(
            AppTheme.light.palette.userMessage.cgColor
        ))
        let composer = try #require(fields.first {
            $0.accessibilityLabel() == "대화 메시지"
        })
        let capture = try #require(
            descendants(of: controller.view, as: NSButton.self)
                .first { $0.title == "캡처" }
        )
        #expect(composer.backgroundColor == AppTheme.light.palette.composerSurface)
        #expect(capture.layer?.backgroundColor == AppTheme.light.palette.auxiliarySurface.cgColor)
        #expect(capture.contentTintColor == AppTheme.light.palette.chatText)
        controller.render(
            state: ChatBubbleState(
                draftText: "busy",
                phase: .sending(UUID())
            ),
            canRetry: false,
            agentNotice: nil
        )
        #expect(!send.isEnabled)
        #expect(composer.backgroundColor == .controlBackgroundColor)
        #expect(composer.textColor == .disabledControlTextColor)
        #expect(capture.alphaValue == 0.42)
    }

    @Test
    @MainActor
    func detailedChatCanvasIsOpaqueAndContainsNoGlassInEveryTheme() throws {
        let controller = QuickMenuViewController()
        controller.loadView()
        let scroll = try #require(descendants(of: controller.view, as: NSScrollView.self).first)
        let document = try #require(scroll.documentView)
        let content = try #require(document.subviews.first)
        let title = try #require(
            descendants(of: controller.view, as: NSTextField.self)
                .first { $0.stringValue == "YumYum Agent" }
        )
        let header = try #require(title.superview)

        for theme in AppTheme.allCases {
            controller.applyTheme(theme)
            let canvas = theme.palette.chatCanvas.cgColor

            #expect(descendants(of: controller.view, as: NSVisualEffectView.self).isEmpty)
            #expect(controller.view.layer?.backgroundColor == canvas)
            #expect(header.layer?.backgroundColor == canvas)
            #expect(scroll.layer?.backgroundColor == canvas)
            #expect(scroll.contentView.layer?.backgroundColor == canvas)
            #expect(document.layer?.backgroundColor == canvas)
            #expect(content.layer?.backgroundColor == canvas)
            for color in [
                controller.view.layer?.backgroundColor,
                header.layer?.backgroundColor,
                scroll.layer?.backgroundColor,
                scroll.contentView.layer?.backgroundColor,
                document.layer?.backgroundColor,
                content.layer?.backgroundColor,
            ] {
                #expect(color?.alpha == 1)
                #expect(color != NSColor.clear.cgColor)
            }
        }
    }

    @Test
    @MainActor
    func chatProductionStatesKeepWarmStylingScopedToChatContentAndAuxiliaryInputs() throws {
        let controller = QuickMenuViewController()
        let panel = QuickMenuPanel(
            contentRect: CGRect(x: 0, y: 0, width: 392, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        defer {
            panel.orderOut(nil)
            panel.contentViewController = nil
        }
        let fields = descendants(of: controller.view, as: NSTextField.self)
        let buttons = descendants(of: controller.view, as: NSButton.self)
        let composer = try #require(fields.first {
            $0.accessibilityLabel() == "대화 메시지"
        })
        let restart = try #require(buttons.first {
            $0.accessibilityLabel() == "새 대화 세션"
        })
        let capture = try #require(buttons.first {
            $0.accessibilityLabel() == "화면 영역 캡처 첨부"
        })
        let file = try #require(buttons.first { $0.title == "파일" })
        let send = try #require(buttons.first { $0.title == "보내기" })
        let retry = try #require(buttons.first { $0.title == "재시도" })
        let cancel = try #require(buttons.first { $0.title == "취소" })

        for theme in AppTheme.allCases {
            controller.render(
                state: ChatBubbleState(
                    draftText: "draft",
                    draftAttachments: [
                        ChatDraftAttachment(
                            url: URL(fileURLWithPath: "/tmp/render.txt"),
                            isTemporary: false
                        ),
                    ],
                    messages: [
                        ChatMessage(role: .user, text: "user"),
                        ChatMessage(role: .assistant, text: "assistant"),
                    ]
                ),
                canRetry: false,
                agentNotice: nil
            )
            controller.applyTheme(theme)
            #expect(layerBackgroundColors(in: controller.view).contains(
                theme.palette.userMessage.cgColor
            ))
            #expect(layerBackgroundColors(in: controller.view).contains(
                theme.palette.assistantMessage.cgColor
            ))
            #expect(composer.backgroundColor == theme.palette.composerSurface)
            #expect(restart.title == "새 세션")
            #expect(restart.layer?.backgroundColor == nil)
            #expect(capture.layer?.backgroundColor == theme.palette.auxiliarySurface.cgColor)
            #expect(file.layer?.backgroundColor == theme.palette.auxiliarySurface.cgColor)
            #expect(send.layer?.backgroundColor == nil)
            #expect(retry.layer?.backgroundColor == nil)
            #expect(cancel.layer?.backgroundColor == nil)

            controller.render(
                state: ChatBubbleState(
                    messages: [
                        ChatMessage(role: .assistant, text: "", isLoading: true),
                    ],
                    phase: .sending(UUID())
                ),
                canRetry: false,
                agentNotice: nil
            )
            #expect(!cancel.isHidden)
            #expect(!send.isEnabled)
            #expect(composer.backgroundColor == .controlBackgroundColor)
            #expect(descendants(of: controller.view, as: NSTextField.self)
                .contains { $0.accessibilityLabel() == "응답 생성 중" })

            controller.render(
                state: ChatBubbleState(phase: .failed("failed")),
                canRetry: true,
                agentNotice: nil
            )
            #expect(!retry.isHidden)
            #expect(cancel.isHidden)
            #expect(fields.first {
                $0.accessibilityLabel() == "YumYum Agent 상태"
            }?.textColor == theme.palette.error)

            controller.render(
                state: ChatBubbleState(phase: .cancelled),
                canRetry: false,
                agentNotice: nil
            )
            #expect(retry.isHidden)
            #expect(cancel.isHidden)
            #expect(descendants(of: controller.view, as: NSTextField.self)
                .contains { $0.accessibilityLabel() == "아직 대화가 없습니다" })
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(capture)
        #expect(capture.layer?.borderWidth == 1)
        #expect(capture.layer?.borderColor == NSColor.keyboardFocusIndicatorColor.cgColor)

        controller.applyTheme(.dark)
        controller.accessibilityDisplayOptionsDidChangeForTesting()
        #expect(controller.view.layer?.backgroundColor == AppTheme.dark.palette.chatCanvas.cgColor)
        controller.applyTheme(.light)
        #expect(controller.view.layer?.borderWidth == (
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        ))
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
}
