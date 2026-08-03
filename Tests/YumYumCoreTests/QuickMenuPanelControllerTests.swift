import AppKit
import Testing
import YumYumCore
@testable import YumYumApp

@Suite
struct QuickMenuPanelControllerTests {
    @Test
    @MainActor
    func newSessionUsesTheProductionRuntimeResetPath() async throws {
        _ = NSApplication.shared
        let connector = ResetRecordingConnector()
        let workflow = FeedWorkflow(
            sender: ControlledPromptSender(),
            feedback: SilentFeedFeedback()
        )
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(
                fixtureProbe: UnusedFixtureProbe(),
                connectors: [connector]
            ),
            workflow: workflow
        )
        let view = try #require(controller.panel.contentView)
        let restart = try #require(buttons(in: view).first { $0.title == "새 세션" })

        restart.performClick(nil)
        await controller.waitForRestartForTesting()

        #expect(await connector.resetCount == 1)
    }

    @Test
    @MainActor
    func newSessionDoesNothingWhileTheSharedWorkflowIsBusy() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let workflow = FeedWorkflow(sender: sender, feedback: SilentFeedFeedback())
        let connector = ResetRecordingConnector()
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(
                fixtureProbe: UnusedFixtureProbe(),
                connectors: [connector]
            ),
            workflow: workflow
        )
        controller.setDraftText("기존 질문")
        #expect(controller.sendDraftFromResponse())
        #expect(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForSendForTesting()
        let messages = controller.state.messages

        let activeSubmission = Task {
            try await workflow.submit(FeedInput(text: "외부 요청"), reduceMotion: true)
        }
        #expect(await sender.waitForRequestCount(2))
        let view = try #require(controller.panel.contentView)
        let restart = try #require(buttons(in: view).first { $0.title == "새 세션" })
        restart.performClick(nil)
        await controller.waitForRestartForTesting()

        #expect(await connector.resetCount == 0)
        #expect(controller.state.messages == messages)
        await sender.completeRequest(at: 1)
        _ = try await activeSubmission.value
    }

    @Test
    @MainActor
    func chatHeaderNewSessionActionIsLocalizedAccessibleAndDisabledWhileBusy() throws {
        _ = NSApplication.shared
        let controller = QuickMenuViewController()
        _ = controller.view

        controller.applyLanguage(.english)
        let english = try #require(buttons(in: controller.view).first {
            $0.title == "New Session"
        })
        let close = try #require(buttons(in: controller.view).first {
            $0.accessibilityLabel() == "Close chat bubble"
        })
        #expect(english.accessibilityLabel() == "New chat session")
        #expect(english.accessibilityHelp() == "Clears the conversation and applies the current Soul to the next request")
        #expect(index(of: english, in: controller.view) < index(of: close, in: controller.view))

        controller.render(
            state: ChatBubbleState(phase: .sending(UUID())),
            canRetry: false,
            canRestart: false,
            agentNotice: nil
        )
        #expect(!english.isEnabled)

        controller.render(
            state: ChatBubbleState(draftText: "전송할 내용", phase: .failed("실패")),
            canRetry: true,
            canRestart: true,
            isRestarting: true,
            agentNotice: nil
        )
        #expect(buttons(in: controller.view).filter { button in
            ["Capture", "File", "Send", "New Session"].contains(button.title)
        }.allSatisfy { !$0.isEnabled })
        let composer = try #require(textFields(in: controller.view).first {
            $0.accessibilityLabel() == "Chat message"
        })
        #expect(!composer.isEnabled)
        #expect(buttons(in: controller.view).first { $0.title == "Retry" }?.isHidden == true)

        controller.applyLanguage(.korean)
        #expect(english.title == "새 세션")
        #expect(english.accessibilityLabel() == "새 대화 세션")
        #expect(english.accessibilityHelp() == "대화 내용을 지우고 현재 Soul을 다음 요청에 적용합니다")
        #expect(ChatPanelController.panelSize == CGSize(width: 400, height: 520))
    }

    @Test
    @MainActor
    func chatThemeDoesNotChangeRenderedActionThinkingOrResponseSurfaces() throws {
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

        controller.applyTheme(.light)
        let action = try #require(controller.actionPanel.contentView?.layer)
        let thinking = try #require(controller.thinkingPanel.contentView?.layer)
        let responseBody = try surface(
            "response-body-surface",
            in: try #require(controller.responsePanel.contentView)
        )

        #expect(action.backgroundColor == NSColor(calibratedWhite: 1, alpha: 1).cgColor)
        #expect(thinking.backgroundColor == NSColor(calibratedWhite: 1, alpha: 1).cgColor)
        #expect(layerBackgroundColors(in: responseBody).contains(
            NSColor(calibratedWhite: 1, alpha: 1).cgColor
        ))
        #expect(layerBackgroundColors(in: controller.responsePanel.contentView).contains(
            AppTheme.light.palette.primaryAction.cgColor
        ))
        #expect(layerBackgroundColors(in: controller.responsePanel.contentView).contains(
            AppTheme.light.palette.secondaryAction.cgColor
        ))
    }

    @Test
    @MainActor
    func responseUsesFourIndependentVerticalSurfacesOnATransparentRoot() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        let identifiers = [
            "response-body-surface",
            "response-inline-composer-surface",
            "response-inline-action-surface",
            "response-detail-action-surface",
        ]
        let surfaces = try identifiers.map { identifier in
            try #require(flattened(controller.view).first {
                $0.identifier?.rawValue == identifier
            })
        }

        #expect(controller.view.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(surfaces[1].isHidden)
        #expect(surfaces[0].frame.minY > surfaces[2].frame.maxY)
        #expect(surfaces[2].frame.minY > surfaces[3].frame.maxY)
        #expect(abs(surfaces[0].frame.minY - surfaces[2].frame.maxY - 8) < 0.5)
        #expect(abs(surfaces[2].frame.minY - surfaces[3].frame.maxY - 8) < 0.5)
        #expect(!surfaces[0].frame.intersects(surfaces[2].frame))
        #expect(!surfaces[2].frame.intersects(surfaces[3].frame))
    }

    @Test
    @MainActor
    func responseExpansionKeepsActionsEqualAndComposerOrderedAccessibleAndFocused() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        let panel = ResponseBubblePanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        controller.onRequestInput = { panel.beginInput() }
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.renderChat(ChatBubbleState(draftText: "보존할 초안"))
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        let inline = try surface("response-inline-action-surface", in: controller.view)
        let composerSurface = try surface("response-inline-composer-surface", in: controller.view)
        let detail = try surface("response-detail-action-surface", in: controller.view)
        let collapsedHeight = controller.preferredSize.height
        let scroll = try #require(scrollViews(in: controller.view).first)
        let composer = try #require(textFields(in: controller.view).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })

        #expect(inline.frame.size == detail.frame.size)
        #expect(composerSurface.isHidden)
        #expect(!composerSurface.isAccessibilityElement())
        try pressButton(titled: "채팅 입력하기", in: controller.view)
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.preferredSize.height > collapsedHeight)
        #expect(!composerSurface.isHidden)
        #expect(composerSurface.frame.minY > inline.frame.maxY)
        #expect(inline.frame.minY > detail.frame.maxY)
        #expect(index(of: composerSurface, in: controller.view)
            < index(of: inline, in: controller.view))
        #expect(composer.stringValue == "보존할 초안")
        #expect(panel.canBecomeKey)
        #expect(panel.firstResponder === composer.currentEditor())
        #expect(scroll.documentView?.isDescendant(of: inline) == false)
        #expect(scroll.documentView?.isDescendant(of: composerSurface) == false)
        #expect(scroll.documentView?.isDescendant(of: detail) == false)
    }

    @Test
    @MainActor
    func collapsingInlineComposerMovesFocusBeforeReturnAndPreservesDraft() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        let panel = ResponseBubblePanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        controller.onRequestInput = { panel.beginInput() }
        var sends = 0
        controller.onSend = { sends += 1 }
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.renderChat(ChatBubbleState(draftText: "보존할 초안"))

        try pressButton(titled: "채팅 입력하기", in: controller.view)
        let composerSurface = try surface(
            "response-inline-composer-surface",
            in: controller.view
        )
        let composer = try #require(textFields(in: controller.view).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        let inline = try #require(buttons(in: controller.view).first {
            $0.title == "채팅 입력하기"
        })
        #expect(panel.firstResponder === composer.currentEditor())

        inline.performClick(nil)

        #expect(composerSurface.isHidden)
        #expect(!composerSurface.isAccessibilityElement())
        #expect(panel.firstResponder === inline)
        _ = panel.firstResponder?.tryToPerform(
            #selector(NSResponder.insertNewline(_:)),
            with: nil
        )
        #expect(sends == 0)

        inline.performClick(nil)
        #expect(composer.stringValue == "보존할 초안")
        #expect(panel.firstResponder === composer.currentEditor())
    }

    @Test
    @MainActor
    func responseErrorKeepsMinimalRetryBehavior() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        var retries = 0
        controller.onRetry = { retries += 1 }

        controller.render(PetResponsePolicy.error(message: "실패"))
        let retry = try #require(buttons(in: controller.view).first {
            $0.accessibilityLabel() == "마지막 입력 재시도"
        })
        #expect(!retry.isHidden)
        retry.performClick(nil)
        #expect(retries == 1)

        controller.render(PetResponsePolicy.content(for: "복구"))
        #expect(retry.isHidden)
    }

    @Test
    @MainActor
    func responseFitsAClampedPanelWithoutRemovingTheMinimumBodyViewport() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: String(repeating: "긴 답변\n", count: 80)))

        controller.fitPanelHeight(220)
        controller.view.frame.size = CGSize(width: 360, height: 220)
        controller.view.layoutSubtreeIfNeeded()

        let bodyScroll = try #require(scrollViews(in: controller.view).first)
        #expect(bodyScroll.frame.height >= 44)
        #expect(flattened(controller.view).filter {
            $0.identifier?.rawValue.hasPrefix("response-") == true && !$0.isHidden
        }.allSatisfy {
            $0.frame.minY >= 0 && $0.frame.maxY <= controller.view.bounds.maxY
        })
    }

    @Test
    @MainActor
    func expandedComposerConstraintTracksDraftAttachmentsAndPreferredHeight() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.renderChat(ChatBubbleState())
        try pressButton(titled: "채팅 입력하기", in: controller.view)
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        let composerSurface = try surface(
            "response-inline-composer-surface",
            in: controller.view
        )
        let plainHeight = composerSurface.frame.height
        #expect(plainHeight > 0)

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
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        #expect(composerSurface.frame.height > plainHeight)
        #expect(abs(controller.view.frame.height - controller.preferredSize.height) < 0.5)
        #expect(!controller.view.hasAmbiguousLayout)
    }

    @Test
    @MainActor
    func constrainedExpandedErrorWithAttachmentKeepsEverySurfaceInsideNegativeOriginPanel() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.error(message: String(repeating: "실패\n", count: 40)))
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
        try pressButton(titled: "채팅 입력하기", in: controller.view)
        controller.fitPanelHeight(220)
        controller.view.frame = CGRect(x: -720, y: -360, width: 360, height: 220)
        controller.view.layoutSubtreeIfNeeded()

        let visibleSurfaces = flattened(controller.view).filter {
            $0.identifier?.rawValue.hasPrefix("response-") == true && !$0.isHidden
        }
        let localBounds = controller.view.bounds
        #expect(visibleSurfaces.count == 4)
        #expect(visibleSurfaces.allSatisfy { $0.frame.height > 0 })
        #expect(visibleSurfaces.allSatisfy {
            $0.frame.minY >= localBounds.minY && $0.frame.maxY <= localBounds.maxY
        })
        #expect(visibleSurfaces.indices.allSatisfy { first in
            visibleSurfaces.indices.allSatisfy { second in
                first == second || !visibleSurfaces[first].frame.intersects(
                    visibleSurfaces[second].frame
                )
            }
        })
        #expect(!controller.view.hasAmbiguousLayout)
    }

    @Test
    @MainActor
    func responseActionsReturnToNeutralAfterPanelHideAndKeyLoss() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        let panel = ResponseBubblePanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        controller.render(PetResponsePolicy.content(for: "완료"))
        let actions = buttons(in: controller.view).filter {
            $0.title == "채팅 입력하기" || $0.title == "채팅창 상세"
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        actions.forEach { $0.mouseEntered(with: event) }
        panel.beginInput()
        panel.makeFirstResponder(actions[0])
        panel.resignKey()
        panel.orderOut(nil)

        #expect(actions.allSatisfy {
            $0.layer?.backgroundColor == NSColor.white.withAlphaComponent(0).cgColor
                && $0.layer?.borderWidth == 0
        })
    }

    @Test
    @MainActor
    func droppedFilesUseTheProductionWorkflowExactlyOnceAndRejectInvalidOrBusyDrops() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drop.txt")
        let invalid = directory.appendingPathComponent("drop.zip")
        try Data("drop".utf8).write(to: file)
        try Data("invalid".utf8).write(to: invalid)

        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.canAcceptDroppedFiles([file, file]))
        #expect(!controller.canAcceptDroppedFiles([file, invalid]))
        #expect(!controller.feedDroppedFiles([invalid]))
        #expect(controller.feedDroppedFiles([file, file]))
        #expect(!controller.feedDroppedFiles([file]))
        #expect(await sender.waitForRequestCount(1))
        let request = await sender.requests[0]
        #expect(request.attachments.map(\.url) == [file])
        #expect(!request.text.contains(file.path))

        await sender.completeRequest(at: 0)
    }

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
            agentNotice: .selectDefault
        )

        controller.accessibilityDisplayOptionsDidChangeForTesting()

        #expect(buttons(in: controller.view).first { $0.title == "재시도" }?.isHidden == false)

        controller.render(
            state: ChatBubbleState(),
            canRetry: false,
            agentNotice: .selectDefault
        )
        controller.accessibilityDisplayOptionsDidChangeForTesting()
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == AppText.localized("설정에서 기본 에이전트를 선택하세요.")
        })
    }

    @Test
    @MainActor
    func openChatLanguageRefreshUpdatesPersistentAccessibilityInPlaceAndRelocalizesTypedNotice() throws {
        _ = NSApplication.shared
        let controller = QuickMenuViewController()
        _ = controller.view
        let attachment = ChatDraftAttachment(
            url: URL(fileURLWithPath: "/private/tmp/report.pdf"),
            isTemporary: false
        )
        controller.render(
            state: ChatBubbleState(
                draftText: "keep draft",
                draftAttachments: [attachment],
                messages: [ChatMessage(role: .assistant, text: "answer")]
            ),
            canRetry: true,
            agentNotice: .reselectDefault
        )
        let messageRow = try #require(flattened(controller.view).first {
            $0.accessibilityLabel()?.contains("answer") == true
        })
        let attachmentRow = try #require(flattened(controller.view).first {
            $0.accessibilityLabel()?.contains("report.pdf") == true
                && !($0 is NSButton)
        })

        controller.applyLanguage(.english)
        #expect(messageRow.accessibilityLabel() == "Assistant: answer")
        #expect(attachmentRow.accessibilityLabel() == "Attached file report.pdf")
        #expect(buttons(in: controller.view).contains {
            $0.title == "Capture"
                && $0.accessibilityLabel() == "Attach Screen Capture"
                && $0.accessibilityHelp() == "Attaches the selected screen area to the draft without sending it"
        })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == "Reselect the default agent in Settings."
                && $0.accessibilityLabel() == "YumYum Agent Status"
        })

        controller.applyLanguage(.korean)
        #expect(messageRow.accessibilityLabel() == "어시스턴트: answer")
        #expect(attachmentRow.accessibilityLabel() == "첨부 파일 report.pdf")
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == "keep draft"
                && $0.placeholderString == "대화를 입력하거나 자료를 첨부하세요."
                && $0.accessibilityLabel() == "대화 메시지"
        })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == "설정에서 기본 에이전트를 다시 선택하세요."
                && $0.accessibilityValue() == "설정에서 기본 에이전트를 다시 선택하세요."
        })
        #expect(flattened(controller.view).contains { $0 === messageRow })
        #expect(flattened(controller.view).contains { $0 === attachmentRow })
    }

    @Test
    @MainActor
    func visibleResponseLanguageRefreshReflowsFrameAndPreservesInputState() throws {
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
        controller.applyFeedStatus(FeedStatusUpdate(
            generation: UUID(),
            status: .failed(UserFacingErrorCategory.invalidFile.message(language: .english))
        ))
        controller.applyLanguage(.english)
        try pressButton(titled: "Reply", in: controller.responsePanel.contentView)
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "Inline chat message"
        })
        composer.stringValue = "keep draft"
        composer.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: composer)
        )
        controller.responsePanel.makeFirstResponder(composer)
        let responder = controller.responsePanel.firstResponder
        let updateCount = controller.responseFrameUpdateCountForTesting

        controller.applyLanguage(.korean)

        #expect(controller.responseFrameUpdateCountForTesting == updateCount + 1)
        #expect(controller.responsePanel.isVisible)
        #expect(composer.stringValue == "keep draft")
        #expect(composer.accessibilityLabel() == "인라인 채팅 메시지")
        #expect(controller.responsePanel.firstResponder === responder)
        #expect(NSScreen.screens.contains { $0.visibleFrame.contains(controller.responsePanel.frame) })
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
    func responseLanguageRefreshPreservesContentDraftAttachmentsExpansionAndScroll() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.applyLanguage(.english)
        controller.render(PetResponsePolicy.error(
            message: UserFacingErrorCategory.invalidFile.message(language: .english)
        ))
        controller.renderChat(ChatBubbleState(
            draftText: "keep draft",
            draftAttachments: [
                ChatDraftAttachment(
                    url: URL(fileURLWithPath: "/private/tmp/report.pdf"),
                    isTemporary: false
                ),
            ]
        ))
        try pressButton(titled: "Reply", in: controller.view)
        controller.responseScrollOriginForTesting = CGPoint(x: 0, y: 4)

        controller.applyLanguage(.korean)

        #expect(buttons(in: controller.view).contains { $0.title == "채팅창 상세" })
        #expect(buttons(in: controller.view).contains { $0.title == "재시도" && !$0.isHidden })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == "keep draft"
                && $0.accessibilityLabel() == "인라인 채팅 메시지"
                && $0.accessibilityHelp() == "Return을 눌러 전송합니다"
        })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == "report.pdf · 1개 첨부"
                && $0.accessibilityLabel() == "전송 예정 첨부"
        })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == UserFacingErrorCategory.invalidFile.message(language: .korean)
        })
        #expect(controller.responseScrollOriginForTesting == CGPoint(x: 0, y: 4))
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
    private func layerBackgroundColors(in view: NSView?) -> [CGColor] {
        guard let view else { return [] }
        return [view.layer?.backgroundColor].compactMap { $0 }
            + view.subviews.flatMap(layerBackgroundColors)
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
    private func surface(_ identifier: String, in view: NSView) throws -> NSView {
        try #require(flattened(view).first {
            $0.identifier?.rawValue == identifier
        })
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

private actor ResetRecordingConnector: AgentConnecting {
    let definitionID = AgentDefinitionID.hermes
    private(set) var resetCount = 0

    func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        PromptResponse(text: "unused")
    }

    func reset() {
        resetCount += 1
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
