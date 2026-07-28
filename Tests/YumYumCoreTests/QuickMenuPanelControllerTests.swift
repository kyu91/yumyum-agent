import AppKit
import Testing
import YumYumCore
@testable import YumYumApp

@Suite
struct QuickMenuPanelControllerTests {
    @Test
    @MainActor
    func completedExternalResponseDoesNotReappearAfterChatCloses() throws {
        _ = NSApplication.shared
        let pet = FloatingPetWindowController {}
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe()
        )
        let feedback = AppFeedFeedback(petController: pet)
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: viewModel,
            workflow: FeedWorkflow(
                sender: viewModel.agentRuntime,
                feedback: feedback
            ),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .failed("retry"))
        )
        #expect(controller.responsePanel.isVisible)

        try pressButton(
            accessibilityLabel: "전체 답변을 채팅에서 열기",
            in: controller.responsePanel.contentView
        )
        let chatPanel = try #require(
            NSApp.windows.first { $0.title == "YumYum 대화" }
        )
        #expect(chatPanel.isVisible)
        #expect(!controller.responsePanel.isVisible)

        controller.applyFeedStatus(
            FeedStatusUpdate(
                generation: UUID(),
                status: .completed("완료 응답")
            )
        )

        #expect(!controller.responsePanel.isVisible)

        try pressButton(accessibilityLabel: "대화 말풍선 닫기", in: chatPanel.contentView)
        #expect(!controller.responsePanel.isVisible)
    }

    @Test
    @MainActor
    func chatVisibilityControlsExternalThinkingWithoutStoppingIt() throws {
        _ = NSApplication.shared
        let pet = FloatingPetWindowController {}
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe()
        )
        let feedback = AppFeedFeedback(petController: pet)
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: viewModel,
            workflow: FeedWorkflow(
                sender: viewModel.agentRuntime,
                feedback: feedback
            ),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        controller.show()
        try pressButton(titled: "채팅 열기", in: controller.actionPanel.contentView)
        let chatPanel = try #require(
            NSApp.windows.first { $0.title == "YumYum 대화" }
        )
        controller.renderChatForTesting(
            ChatBubbleState(
                messages: [
                    ChatMessage(role: .user, text: "keep me"),
                    ChatMessage(
                        role: .assistant,
                        text: "",
                        isLoading: true
                    ),
                ],
                phase: .sending(UUID())
            )
        )
        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .sending)
        )

        #expect(!controller.thinkingPanel.isVisible)
        #expect(textFields(in: chatPanel.contentView).contains {
            $0.stringValue == "keep me"
        })

        try pressButton(accessibilityLabel: "대화 말풍선 닫기", in: chatPanel.contentView)
        #expect(controller.thinkingPanel.isVisible)
        #expect(pet.isVisible)

        controller.show()
        try pressButton(titled: "채팅 열기", in: controller.actionPanel.contentView)
        #expect(!controller.thinkingPanel.isVisible)
        #expect(textFields(in: chatPanel.contentView).contains {
            $0.stringValue == "keep me"
        })
    }

    @MainActor
    private func pressButton(
        titled title: String,
        in view: NSView?
    ) throws {
        let button = try #require(buttons(in: view).first { $0.title == title })
        button.performClick(nil)
    }

    @MainActor
    private func pressButton(
        accessibilityLabel: String,
        in view: NSView?
    ) throws {
        let button = try #require(
            buttons(in: view).first {
                $0.accessibilityLabel() == accessibilityLabel
            }
        )
        button.performClick(nil)
    }

    @MainActor
    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? []
            + view.subviews.flatMap(buttons)
    }

    @MainActor
    private func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return (view as? NSTextField).map { [$0] } ?? []
            + view.subviews.flatMap(textFields)
    }
}

private struct UnusedFixtureProbe: FixtureProbing {
    let fixturePath = "/unused"

    func probe() async throws -> String { "unused" }
}
