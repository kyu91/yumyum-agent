import AppKit
import Testing
import YumYumCore
@testable import YumYumApp

@Suite
struct QuickMenuPanelControllerTests {
    @Test
    @MainActor
    func inlineReturnAndButtonUseTheProductionSessionExactlyOnce() async throws {
        _ = NSApplication.shared
        let attachment = FileManager.default.temporaryDirectory
            .appendingPathComponent("visible-\(UUID().uuidString).txt")
        try Data("attachment".utf8).write(to: attachment)
        defer { try? FileManager.default.removeItem(at: attachment) }
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let chatController = ChatPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(
                sender: sender,
                feedback: SilentFeedFeedback()
            )
        )
        let responseController = ResponseBubbleViewController()
        let responsePanel = ResponseBubblePanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        responsePanel.contentViewController = responseController
        responseController.onRequestInput = { responsePanel.beginInput() }
        responseController.onDraftChanged = { [weak chatController] text in
            chatController?.setDraftText(text)
        }
        responseController.onSend = { [weak chatController] in
            chatController?.sendDraftFromResponse()
        }
        chatController.onStateChanged = { [weak responseController] state in
            responseController?.renderChat(state)
        }
        responseController.render(PetResponsePolicy.content(for: "완료"))
        responseController.renderChat(chatController.state)
        let view = try #require(responsePanel.contentView)
        let initialButtons = buttons(in: view).filter { !$0.isHidden }
        let inline = try #require(initialButtons.first { $0.title == "채팅 입력하기" })
        let detail = try #require(initialButtons.first { $0.title == "채팅창 상세" })
        #expect(index(of: inline, in: view) < index(of: detail, in: view))

        inline.performClick(nil)
        let composer = try #require(textFields(in: view).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        let returnAction = try #require(composer.action)
        let send = try #require(buttons(in: view).first { $0.title == "전송" })

        composer.stringValue = " \n "
        composer.sendAction(returnAction, to: composer.target)
        await Task.yield()
        #expect(await sender.requestCount == 0)

        chatController.addAttachmentForTesting(
            ChatDraftAttachment(url: attachment, isTemporary: false)
        )
        composer.stringValue = "Return 경로"
        composer.sendAction(returnAction, to: composer.target)
        #expect(await sender.waitForRequestCount(1))
        composer.sendAction(returnAction, to: composer.target)
        #expect(await sender.requestCount == 1)
        let returnRequest = await sender.requests[0]
        #expect(returnRequest.attachments.map(\.url) == [attachment])
        #expect(!returnRequest.text.contains(attachment.path))
        #expect(!textFields(in: view).contains { $0.stringValue.contains(attachment.path) })
        await sender.completeRequest(at: 0)
        await chatController.waitForSendForTesting()

        composer.stringValue = "버튼 경로"
        responseController.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification)
        )
        send.performClick(nil)
        #expect(await sender.waitForRequestCount(2))
        send.performClick(nil)
        #expect(await sender.requestCount == 2)
        #expect(!send.isEnabled)
        await sender.completeRequest(at: 1)
        await chatController.waitForSendForTesting()
    }

    @Test
    @MainActor
    func responseThemeChangePreservesBodyScrollOrigin() {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        let panel = ResponseBubblePanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        controller.render(PetResponsePolicy.content(for: String(repeating: "긴 답변\n", count: 80)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        controller.responseScrollOriginForTesting = CGPoint(x: 0, y: 40)

        controller.applyTheme(.light)

        #expect(controller.responseScrollOriginForTesting.y == 40)
    }

    @Test
    @MainActor
    func hiddenSendingChatStopsAndShownChatRestartsOneLoadingTask() {
        _ = NSApplication.shared
        let controller = QuickMenuViewController()
        _ = controller.view
        let sending = ChatBubbleState(
            messages: [ChatMessage(role: .assistant, text: "", isLoading: true)],
            phase: .sending(UUID())
        )

        controller.setPresented(true)
        controller.render(state: sending, canRetry: false, agentNotice: nil)
        #expect(controller.hasLoadingTaskForTesting)
        controller.setPresented(false)
        #expect(!controller.hasLoadingTaskForTesting)
        controller.setPresented(true)
        #expect(controller.hasLoadingTaskForTesting)
        controller.setPresented(true)
        #expect(controller.hasLoadingTaskForTesting)
        controller.render(
            state: ChatBubbleState(),
            canRetry: false,
            agentNotice: nil
        )
        #expect(!controller.hasLoadingTaskForTesting)
    }

    @Test
    @MainActor
    func loadingTaskDoesNotRetainItsViewControllerDuringSleep() async {
        _ = NSApplication.shared
        var controller: QuickMenuViewController? = QuickMenuViewController()
        _ = controller?.view
        controller?.setPresented(true)
        controller?.render(
            state: ChatBubbleState(
                messages: [ChatMessage(role: .assistant, text: "", isLoading: true)],
                phase: .sending(UUID())
            ),
            canRetry: false,
            agentNotice: nil
        )
        await Task.yield()
        weak let releasedController = controller

        controller = nil
        await Task.yield()

        #expect(releasedController == nil)
    }

    @Test
    @MainActor
    func responseKeyInputEndsOnResignDetailCaptureAndOrdinaryPresentation() throws {
        _ = NSApplication.shared
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(
                sender: ControlledPromptSender(),
                feedback: SilentFeedFeedback()
            ),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let panel = controller.responsePanel
        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .completed("완료"))
        )
        #expect(!panel.canBecomeKey)

        try pressButton(titled: "채팅 입력하기", in: panel.contentView)
        #expect(panel.canBecomeKey)
        panel.resignKey()
        #expect(!panel.canBecomeKey)

        try pressButton(titled: "채팅 입력하기", in: panel.contentView)
        try pressButton(titled: "채팅창 상세", in: panel.contentView)
        #expect(!panel.canBecomeKey)

        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .completed("다시"))
        )
        try pressButton(titled: "채팅 입력하기", in: panel.contentView)
        controller.prepareResponseForCaptureForTesting()
        #expect(!panel.canBecomeKey)
    }

    @Test
    @MainActor
    func reduceMotionRerenderPreservesRetryAndAgentMetadata() throws {
        _ = NSApplication.shared
        let controller = QuickMenuViewController()
        _ = controller.view
        controller.render(
            state: ChatBubbleState(phase: .failed("실패")),
            canRetry: true,
            agentNotice: "에이전트 상태"
        )

        controller.accessibilityDisplayOptionsDidChangeForTesting()

        #expect(buttons(in: controller.view).first { $0.title == "재시도" }?.isHidden == false)

        controller.render(
            state: ChatBubbleState(),
            canRetry: false,
            agentNotice: "에이전트 상태"
        )
        controller.accessibilityDisplayOptionsDidChangeForTesting()
        #expect(textFields(in: controller.view).contains { $0.stringValue == "에이전트 상태" })
    }

    @Test
    @MainActor
    func expandedAttachmentChromeFitsItsArrangedSubviews() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.renderChat(
            ChatBubbleState(
                draftAttachments: [
                    ChatDraftAttachment(
                        url: URL(fileURLWithPath: "/private/tmp/report.pdf"),
                        isTemporary: false
                    ),
                ]
            )
        )
        let collapsedHeight = controller.preferredSize.height
        try pressButton(titled: "채팅 입력하기", in: controller.view)
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.preferredSize.height >= collapsedHeight + 48)
        #expect(!controller.view.hasAmbiguousLayout)
    }

    @Test
    @MainActor
    func chatLoadingUsesSharedThinkingPolicyWithoutMotionAnnouncements() throws {
        _ = NSApplication.shared
        let controller = QuickMenuViewController()
        _ = controller.view
        let state = ChatBubbleState(
            messages: [
                ChatMessage(role: .assistant, text: "", isLoading: true),
            ],
            phase: .sending(UUID())
        )

        controller.renderForTesting(
            state: state,
            elapsedMilliseconds: 0,
            reduceMotion: false
        )
        #expect(textFields(in: controller.view).contains { $0.stringValue == "Yum." })
        controller.renderForTesting(
            state: state,
            elapsedMilliseconds: 300,
            reduceMotion: false
        )
        #expect(textFields(in: controller.view).contains { $0.stringValue == "Yum.." })
        controller.renderForTesting(
            state: state,
            elapsedMilliseconds: 600,
            reduceMotion: true
        )
        #expect(textFields(in: controller.view).contains { $0.stringValue == "Yum..." })
        #expect(textFields(in: controller.view).filter {
            $0.identifier?.rawValue.hasPrefix("chat-loading-") == true
        }.allSatisfy {
            $0.accessibilityValue() == "응답 생성 중"
        })
    }

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
        let chatPanel = controller.chatPanelForTesting
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
    func responseDetailPreservesAPreviouslyViewedFullChatScrollPosition() throws {
        _ = NSApplication.shared
        let pet = FloatingPetWindowController {}
        let viewModel = YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe())
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: viewModel,
            workflow: FeedWorkflow(
                sender: viewModel.agentRuntime,
                feedback: AppFeedFeedback(petController: pet)
            ),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        controller.show()
        try pressButton(titled: "채팅 열기", in: controller.actionPanel.contentView)
        let chatPanel = controller.chatPanelForTesting
        controller.renderChatForTesting(
            ChatBubbleState(
                messages: (0..<30).map {
                    ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "메시지 \($0)")
                }
            )
        )
        chatPanel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollViews(in: chatPanel.contentView).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        let origin = scroll.contentView.bounds.origin
        try pressButton(accessibilityLabel: "대화 말풍선 닫기", in: chatPanel.contentView)
        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .completed("새 응답"))
        )

        try pressButton(
            accessibilityLabel: "전체 답변을 채팅에서 열기",
            in: controller.responsePanel.contentView
        )

        #expect(scroll.contentView.bounds.origin == origin)
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
        let chatPanel = controller.chatPanelForTesting
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

    @MainActor
    private func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ?? []
            + view.subviews.flatMap(scrollViews)
    }

    @MainActor
    private func index(of target: NSView, in view: NSView) -> Int {
        flattened(view).firstIndex { $0 === target } ?? .max
    }

    @MainActor
    private func flattened(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(flattened)
    }
}

private struct UnusedFixtureProbe: FixtureProbing {
    let fixturePath = "/unused"

    func probe() async throws -> String { "unused" }
}

private actor ControlledPromptSender: PromptSending {
    private(set) var requests: [PromptRequest] = []
    private var continuations: [PromptResponseEventStream.Continuation] = []

    var requestCount: Int { requests.count }

    func send(_ request: PromptRequest) async throws -> PromptResponse {
        fatalError("sendEvents is the production path")
    }

    nonisolated func sendEvents(_ request: PromptRequest) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            Task { await self.store(request, continuation: continuation) }
        }
    }

    func waitForRequestCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while requests.count < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return requests.count == count
    }

    func completeRequest(at index: Int) {
        continuations[index].yield(.completed(PromptResponse(text: "완료")))
        continuations[index].finish()
    }

    private func store(
        _ request: PromptRequest,
        continuation: PromptResponseEventStream.Continuation
    ) {
        requests.append(request)
        continuations.append(continuation)
    }
}

private struct SilentFeedFeedback: FeedFeedback {
    func setMouthPresentation(_ presentation: FeedMouthPresentation) async {}
    func animate(_ preview: FeedPreview, reduceMotion: Bool) async {}
    func setStatus(_ update: FeedStatusUpdate) async {}
}
