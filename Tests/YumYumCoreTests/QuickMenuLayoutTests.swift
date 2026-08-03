import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import YumYumApp
@testable import YumYumCore

extension AppGlobalStateTests {
@Suite
struct QuickMenuLayoutTests {
    @Test
    @MainActor
    func streamingMarkdownHidesIncompleteDelimiters() {
        let rendered = AssistantMarkdownRenderer.render(
            "**강조 중이고 `코드 입력 중",
            font: .systemFont(ofSize: 13),
            textColor: .labelColor,
            isStreaming: true
        )

        #expect(rendered.string == "강조 중이고 코드 입력 중")
        #expect(!rendered.string.contains("**"))
        #expect(!rendered.string.contains("`"))

        let headingMarker = AssistantMarkdownRenderer.render(
            "##",
            font: .systemFont(ofSize: 13),
            textColor: .labelColor,
            isStreaming: true
        )
        #expect(headingMarker.string.isEmpty)
    }

    @Test
    @MainActor
    func completedMarkdownRendersBlockAndInlineStyles() throws {
        let rendered = AssistantMarkdownRenderer.render(
            "# 제목\n\n**굵게**와 `인라인`\n\n```swift\nlet value = 1\n```",
            font: .systemFont(ofSize: 13),
            textColor: .labelColor,
            isStreaming: false
        )

        let heading = try #require(font(in: rendered, matching: "제목"))
        let bold = try #require(font(in: rendered, matching: "굵게"))
        let inlineCode = try #require(font(in: rendered, matching: "인라인"))
        let fencedCode = try #require(font(in: rendered, matching: "let value = 1"))
        #expect(!rendered.string.contains("#"))
        #expect(!rendered.string.contains("**"))
        #expect(!rendered.string.contains("```"))
        #expect(heading.pointSize > 13)
        #expect(
            heading.fontDescriptor.symbolicTraits.contains(
                NSFontDescriptor.SymbolicTraits.bold
            )
        )
        #expect(
            bold.fontDescriptor.symbolicTraits.contains(
                NSFontDescriptor.SymbolicTraits.bold
            )
        )
        #expect(
            inlineCode.fontDescriptor.symbolicTraits.contains(
                NSFontDescriptor.SymbolicTraits.monoSpace
            )
        )
        #expect(
            fencedCode.fontDescriptor.symbolicTraits.contains(
                NSFontDescriptor.SymbolicTraits.monoSpace
            )
        )
    }

    @Test
    func menuStateEnablesInputOnlyForAnAvailableExplicitSelection() {
        let available = AgentInstallation(
            definitionID: .codex,
            path: "/safe/codex",
            version: "1.0.0",
            runtimeContract: .codexExec,
            availability: .available
        )
        let reference = SelectedAgentReference(definitionID: .codex, path: "/safe/codex")

        #expect(
            !QuickMenuActionState(
                snapshot: AgentRegistrySnapshot(
                    installations: [available],
                    selection: .unselected
                ),
                isBusy: false
            ).isInputEnabled
        )
        #expect(
            QuickMenuActionState(
                snapshot: AgentRegistrySnapshot(
                    installations: [available],
                    selection: .selected(available)
                ),
                isBusy: false
            ).isInputEnabled
        )
        #expect(
            !QuickMenuActionState(
                snapshot: AgentRegistrySnapshot(
                    installations: [available],
                    selection: .selected(available)
                ),
                isBusy: true
            ).isInputEnabled
        )

        let unavailable = QuickMenuActionState(
            snapshot: AgentRegistrySnapshot(
                installations: [available],
                selection: .unavailable(reference: reference, reason: "missing")
            ),
            isBusy: false
        )
        #expect(!unavailable.isInputEnabled)
        #expect(unavailable.statusText == "기존 에이전트를 사용할 수 없습니다. 다시 선택하세요.")
    }

    @Test
    func placesTheBubbleBesideThePetAndClampsItToThePetsDisplay() {
        let primary = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let secondary = CGRect(x: -1_728, y: -80, width: 1_728, height: 1_080)
        let panelSize = CGSize(width: 360, height: 276)
        let layout = QuickMenuLayout()

        let primaryFrame = layout.panelFrame(
            petFrame: CGRect(x: 1_324, y: 45, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [secondary, primary]
        )
        #expect(primaryFrame == CGRect(x: 1_060, y: 149, width: 360, height: 276))

        let secondaryFrame = layout.panelFrame(
            petFrame: CGRect(x: -116, y: 800, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [primary, secondary]
        )
        #expect(secondaryFrame == CGRect(x: -380, y: 516, width: 360, height: 276))
        #expect(secondary.contains(secondaryFrame))

        let tinyDisplay = CGRect(x: 100, y: 100, width: 300, height: 220)
        let tinyFrame = layout.panelFrame(
            petFrame: CGRect(x: 300, y: 120, width: 80, height: 80),
            panelSize: panelSize,
            visibleFrames: [tinyDisplay]
        )
        #expect(tinyFrame == tinyDisplay)
    }

    @Test
    func alignsTheMenuFromThePetsSideOfItsSelectedDisplay() {
        let layout = QuickMenuLayout()
        let display = CGRect(x: 100, y: 25, width: 1_200, height: 800)
        let panelSize = CGSize(width: 248, height: 216)

        let left = layout.placement(
            petFrame: CGRect(x: 120, y: 100, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [display]
        )
        let right = layout.placement(
            petFrame: CGRect(x: 1_180, y: 100, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [display]
        )
        let midpoint = layout.placement(
            petFrame: CGRect(x: display.midX - 48, y: 100, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [display]
        )

        #expect(left.horizontalAlignment == .leading)
        #expect(left.frame.minX == 120)
        #expect(right.horizontalAlignment == .trailing)
        #expect(right.frame.maxX == 1_276)
        #expect(midpoint.horizontalAlignment == .leading)
        #expect(display.contains(left.frame))
        #expect(display.contains(right.frame))
        #expect(display.contains(midpoint.frame))
    }

    @Test
    func usesTheSelectedNegativeCoordinateDisplayForAlignmentAndClamping() {
        let layout = QuickMenuLayout()
        let primary = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let secondary = CGRect(x: -1_728, y: -80, width: 1_728, height: 1_080)
        let panelSize = CGSize(width: 248, height: 216)

        let left = layout.placement(
            petFrame: CGRect(x: -1_710, y: 200, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [primary, secondary]
        )
        let right = layout.placement(
            petFrame: CGRect(x: -116, y: 200, width: 96, height: 96),
            panelSize: panelSize,
            visibleFrames: [primary, secondary]
        )

        #expect(left.horizontalAlignment == .leading)
        #expect(left.frame.minX == -1_710)
        #expect(right.horizontalAlignment == .trailing)
        #expect(right.frame.maxX == -20)
        #expect(secondary.contains(left.frame))
        #expect(secondary.contains(right.frame))
    }

    @Test
    func clampsTheTallChatBubbleOnNegativeAndVerticallyArrangedDisplays() {
        let lower = CGRect(x: -1_440, y: -900, width: 1_440, height: 900)
        let upper = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        let bubbleSize = CGSize(width: 400, height: 520)
        let layout = QuickMenuLayout()

        let lowerBubble = layout.panelFrame(
            petFrame: CGRect(x: -120, y: -880, width: 96, height: 96),
            panelSize: bubbleSize,
            visibleFrames: [upper, lower]
        )
        let upperBubble = layout.panelFrame(
            petFrame: CGRect(x: -1_420, y: 790, width: 96, height: 96),
            panelSize: bubbleSize,
            visibleFrames: [lower, upper]
        )

        #expect(lower.contains(lowerBubble))
        #expect(upper.contains(upperBubble))
        #expect(lowerBubble.size == bubbleSize)
        #expect(upperBubble.size == bubbleSize)
    }
}
}

private func font(
    in attributedString: NSAttributedString,
    matching text: String
) -> NSFont? {
    let range = (attributedString.string as NSString).range(of: text)
    guard range.location != NSNotFound else { return nil }
    return attributedString.attribute(
        .font,
        at: range.location,
        effectiveRange: nil
    ) as? NSFont
}
