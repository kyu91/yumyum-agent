import CoreGraphics
import Testing
@testable import YumYumCore

@Suite
struct QuickMenuLayoutTests {
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
