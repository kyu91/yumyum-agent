import AppKit
import Testing
import YumYumCore
@testable import YumYumApp

extension AppGlobalStateTests {
@Suite
struct QuickMenuPanelControllerTests {
    @Test
    @MainActor
    func globalShortcutMatchesDespiteCapsLockAndFunctionFlags() throws {
        _ = NSApplication.shared
        let controller = GlobalShortcutController(
            keyCode: 1,
            modifiers: [.option]
        ) {}
        let event = try keyEvent(
            modifierFlags: [.option, .capsLock, .function],
            keyCode: 1
        )

        #expect(controller.matchesForTesting(event))
    }

    @Test
    @MainActor
    func pausedGlobalShortcutIgnoresItsOwnCombination() throws {
        _ = NSApplication.shared
        let controller = GlobalShortcutController(
            keyCode: 1,
            modifiers: [.option]
        ) {}
        controller.isPaused = true
        let event = try keyEvent(modifierFlags: [.option], keyCode: 1)

        #expect(!controller.matchesForTesting(event))
    }

    @Test
    @MainActor
    func recordedShortcutRejectsBareAndShiftOnlyCombinations() throws {
        _ = NSApplication.shared
        let bare = try keyEvent(modifierFlags: [], keyCode: 1)
        let shift = try keyEvent(modifierFlags: [.shift], keyCode: 1)
        let empty = try keyEvent(
            modifierFlags: [.option],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 1
        )
        let valid = try keyEvent(
            modifierFlags: [.control, .option, .capsLock],
            characters: "s",
            charactersIgnoringModifiers: "s",
            keyCode: 1
        )

        #expect(ClipboardFeedShortcut.recorded(from: bare) == nil)
        #expect(ClipboardFeedShortcut.recorded(from: shift) == nil)
        #expect(ClipboardFeedShortcut.recorded(from: empty) == nil)
        let recorded = try #require(ClipboardFeedShortcut.recorded(from: valid))
        #expect(recorded.character == "S")
        #expect(recorded.modifiers == [.control, .option])
        #expect(recorded.displayName == "⌃⌥S")
    }

    @Test
    func customShortcutRoundTripsThroughDefaults() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        let shortcut = ClipboardFeedShortcut(
            keyCode: 9,
            modifiers: [.command, .shift],
            character: ":"
        )

        shortcut.save(defaults: suite.defaults)

        #expect(ClipboardFeedShortcut.load(defaults: suite.defaults) == shortcut)
    }

    @Test
    func legacyShortcutRawValuesMigrateToTheirKeyCodes() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }

        suite.defaults.set("optionS", forKey: ClipboardFeedShortcut.defaultsKey)
        #expect(ClipboardFeedShortcut.load(defaults: suite.defaults) == .default)
        suite.defaults.set("controlOptionS", forKey: ClipboardFeedShortcut.defaultsKey)
        #expect(ClipboardFeedShortcut.load(defaults: suite.defaults) == ClipboardFeedShortcut(
            keyCode: 1,
            modifiers: [.control, .option],
            character: "S"
        ))
        suite.defaults.set("controlOptionV", forKey: ClipboardFeedShortcut.defaultsKey)
        #expect(ClipboardFeedShortcut.load(defaults: suite.defaults) == ClipboardFeedShortcut(
            keyCode: 9,
            modifiers: [.control, .option],
            character: "V"
        ))
    }

    @Test
    @MainActor
    func settingAShortcutUpdatesTheInstalledMonitor() throws {
        _ = NSApplication.shared
        let controller = GlobalShortcutController(
            keyCode: ClipboardFeedShortcut.default.keyCode,
            modifiers: ClipboardFeedShortcut.default.modifiers
        ) {}
        let oldEvent = try keyEvent(modifierFlags: [.option], keyCode: 1)
        let newEvent = try keyEvent(
            modifierFlags: [.control, .option],
            keyCode: 9
        )
        let newShortcut = try #require(ClipboardFeedShortcut.recorded(from: newEvent))

        controller.update(keyCode: newShortcut.keyCode, modifiers: newShortcut.modifiers)

        #expect(!controller.matchesForTesting(oldEvent))
        #expect(controller.matchesForTesting(newEvent))
    }

    @Test(arguments: AppTheme.allCases)
    func actionRowColorsAreOpaqueDistinctAndReadable(theme: AppTheme) throws {
        let normal = ActionRowAppearance.resolve(theme: theme)
        let hover = ActionRowAppearance.resolve(theme: theme, isHovered: true)
        let pressed = ActionRowAppearance.resolve(theme: theme, isPressed: true)
        let focused = ActionRowAppearance.resolve(theme: theme, isFocused: true)
        let disabled = ActionRowAppearance.resolve(
            theme: theme,
            isEnabled: false,
            isHovered: true,
            isPressed: true,
            isFocused: true
        )

        for appearance in [normal, hover, pressed, focused, disabled] {
            #expect(try alpha(of: appearance.backgroundColor) == 1)
            #expect(contrastRatio(appearance.textColor, appearance.backgroundColor) >= 4.5)
        }
        #expect(!colorsEqual(normal.backgroundColor, hover.backgroundColor))
        #expect(!colorsEqual(hover.backgroundColor, pressed.backgroundColor))
        #expect(colorsEqual(hover.backgroundColor, focused.backgroundColor))
        #expect(colorsEqual(disabled.backgroundColor, normal.backgroundColor))
        #expect(disabled.opacity == 0.42)

        if theme == .light {
            #expect(!colorsEqual(
                hover.backgroundColor,
                NSColor.controlAccentColor.withAlphaComponent(0.12)
            ))
        }
    }

    @Test
    @MainActor
    func completedChatEnablesNewSession() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback())
        )
        defer {
            controller.panel.orderOut(nil)
            controller.panel.contentViewController = nil
        }
        controller.setDraftText("질문")
        #expect(controller.sendDraftFromResponse())
        try #require(await sender.waitForRequestCount(1))

        await sender.completeRequest(at: 0)
        await controller.waitForSendForTesting()

        let view = try #require(controller.panel.contentView)
        #expect(buttons(in: view).first { $0.title == "새 세션" }?.isEnabled == true)
    }

    @Test
    @MainActor
    func emptyChatResetRestoresComposerActionsAndDraftSendEnablement() async throws {
        _ = NSApplication.shared
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: ControlledPromptSender(), feedback: SilentFeedFeedback()),
            resetAgentSession: { true }
        )
        let view = try #require(controller.panel.contentView)
        try pressButton(titled: "새 세션", in: view)

        await controller.waitForRestartForTesting()

        let composer = try #require(textFields(in: view).first {
            $0.accessibilityLabel() == "대화 메시지"
        })
        #expect(composer.isEnabled)
        #expect(buttons(in: view).filter {
            ["캡처", "파일", "새 세션"].contains($0.title)
        }.allSatisfy { $0.isEnabled })
        #expect(buttons(in: view).first { $0.title == "보내기" }?.isEnabled == false)
        controller.setDraftText("새 질문")
        #expect(buttons(in: view).first { $0.title == "보내기" }?.isEnabled == true)
    }

    @Test
    @MainActor
    func rejectedResetRestoresControlsAndPreservesTranscript() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            resetAgentSession: { false }
        )
        controller.setDraftText("질문")
        #expect(controller.sendDraftFromResponse())
        try #require(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForSendForTesting()
        let messages = controller.state.messages
        let view = try #require(controller.panel.contentView)

        try pressButton(titled: "새 세션", in: view)
        await controller.waitForRestartForTesting()

        #expect(controller.state.messages == messages)
        #expect(buttons(in: view).first { $0.title == "새 세션" }?.isEnabled == true)
        #expect(textFields(in: view).first {
            $0.accessibilityLabel() == "대화 메시지"
        }?.isEnabled == true)
    }

    @Test
    @MainActor
    func blockingResetDisablesInteractiveControlsOnlyUntilItFinishes() async throws {
        _ = NSApplication.shared
        let reset = BlockingPanelReset()
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: ControlledPromptSender(), feedback: SilentFeedFeedback()),
            resetAgentSession: { await reset.perform() }
        )
        controller.setDraftText("보존할 초안")
        let view = try #require(controller.panel.contentView)
        try pressButton(titled: "새 세션", in: view)
        await reset.waitUntilStarted()

        #expect(buttons(in: view).filter {
            ["캡처", "파일", "보내기", "새 세션"].contains($0.title)
        }.allSatisfy { !$0.isEnabled })
        #expect(textFields(in: view).first {
            $0.accessibilityLabel() == "대화 메시지"
        }?.isEnabled == false)

        await reset.finish()
        await controller.waitForRestartForTesting()

        #expect(buttons(in: view).filter {
            ["캡처", "파일", "보내기", "새 세션"].contains($0.title)
        }.allSatisfy { $0.isEnabled })
        #expect(textFields(in: view).first {
            $0.accessibilityLabel() == "대화 메시지"
        }?.isEnabled == true)
    }

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
        try #require(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForSendForTesting()
        let messages = controller.state.messages

        let activeSubmission = Task {
            try await workflow.submit(FeedInput(text: "외부 요청"), reduceMotion: true)
        }
        try #require(await sender.waitForRequestCount(2))
        let view = try #require(controller.panel.contentView)
        let restart = try #require(buttons(in: view).first { $0.title == "새 세션" })
        restart.performClick(nil)
        await controller.waitForRestartForTesting()

        #expect(await connector.resetCount == 0)
        #expect(controller.state.messages == messages)
        await sender.completeRequest(at: 1)
        _ = try await activeSubmission.value
    }

    private func alpha(of color: NSColor) throws -> CGFloat {
        try #require(color.usingColorSpace(.deviceRGB)).alphaComponent
    }

    private func colorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        lhs.usingColorSpace(.deviceRGB) == rhs.usingColorSpace(.deviceRGB)
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

    @MainActor
    private func pasteboard(_ objects: [NSPasteboardWriting]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        return pasteboard
    }

    @MainActor
    private func keyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String = "s",
        charactersIgnoringModifiers: String? = "s",
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeDefaults() throws -> DefaultsSuite {
        let name = "QuickMenuPanelControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return DefaultsSuite(name: name, defaults: defaults)
    }

    private struct DefaultsSuite {
        let name: String
        let defaults: UserDefaults

        func remove() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    @MainActor
    private func imageForPasteboard() -> NSImage {
        let image = NSImage(size: CGSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
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

        #expect(action.backgroundColor == NSColor.clear.cgColor)
        let actionButtons = buttons(in: controller.actionPanel.contentView)
        #expect(actionButtons.count == 4)
        #expect(actionButtons.allSatisfy {
            $0.layer?.backgroundColor == AppTheme.light.palette.surface.cgColor
                && $0.layer?.borderColor == AppTheme.light.palette.border.cgColor
        })
        #expect(thinking.backgroundColor == NSColor(calibratedWhite: 1, alpha: 1).cgColor)
        #expect(layerBackgroundColors(in: responseBody).contains(
            NSColor(calibratedWhite: 1, alpha: 1).cgColor
        ))
        #expect(layerBackgroundColors(in: controller.responsePanel.contentView).contains(
            AppTheme.light.palette.secondaryAction.cgColor
        ))
    }

    @Test
    @MainActor
    func actionMenuUsesAdaptiveAlignedIntrinsicTailFreeBubbleSurfaces() throws {
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
        controller.applyLanguage(.english)
        controller.updateActionFrameForTesting(
            petFrame: CGRect(x: 20, y: 100, width: 96, height: 96),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1_200, height: 800)]
        )
        let root = try #require(controller.actionPanel.contentView)
        root.layoutSubtreeIfNeeded()
        let actionButtons = buttons(in: root).sorted { $0.frame.maxY > $1.frame.maxY }
        actionButtons.forEach { $0.layoutSubtreeIfNeeded() }
        let stack = try #require(flattened(root).compactMap { $0 as? NSStackView }.first)

        #expect(QuickMenuPanelController.actionPanelSize == CGSize(width: 248, height: 216))
        #expect(root.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(actionButtons.map(\.title) == ActionBubbleAction.allCases.map {
            $0.title(language: .english)
        })
        #expect(stack.spacing == 8)
        let widths = actionButtons.map(\.frame.width)
        #expect(Set(widths.map { Int($0.rounded()) }).count > 1)
        let chooseFiles = try #require(actionButtons.first { $0.title == "Choose Files" })
        let settings = try #require(actionButtons.first { $0.title == "Settings" })
        #expect(chooseFiles.frame.width > settings.frame.width)
        #expect(controller.actionPanel.frame.minX == 20)
        #expect(actionButtons.allSatisfy {
            abs($0.frame.minX - actionButtons[0].frame.minX) < 0.5
        })

        controller.updateActionFrameForTesting(
            petFrame: CGRect(x: 1_080, y: 100, width: 96, height: 96),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1_200, height: 800)]
        )
        root.layoutSubtreeIfNeeded()
        #expect(controller.actionPanel.frame.maxX == 1_176)
        #expect(actionButtons.allSatisfy {
            abs($0.frame.maxX - actionButtons[0].frame.maxX) < 0.5
        })
        #expect(actionButtons.allSatisfy {
            let contentWidth = $0.cell?.cellSize.width ?? $0.frame.width
            let horizontalPadding = $0.frame.width - contentWidth
            return $0.frame.height >= 44
                && horizontalPadding / 2 >= 12
                && $0.layer?.backgroundColor != NSColor.clear.cgColor
                && ($0.layer?.borderWidth ?? 0) > 0
                && $0.layer?.sublayers?.contains { $0 is CAShapeLayer } != true
        })
        #expect(zip(actionButtons, actionButtons.dropFirst()).allSatisfy {
            $0.frame.minY - $1.frame.maxY >= 7
        })
    }

    @Test
    @MainActor
    func responseUsesThreeIndependentVerticalSurfacesOnATransparentRoot() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        let identifiers = [
            "response-body-surface",
            "response-inline-composer-surface",
            "response-detail-action-surface",
        ]
        let surfaces = try identifiers.map { identifier in
            try #require(flattened(controller.view).first {
                $0.identifier?.rawValue == identifier
            })
        }

        #expect(controller.view.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(!surfaces[1].isHidden)
        #expect(surfaces[0].frame.minY > surfaces[1].frame.maxY)
        #expect(surfaces[1].frame.minY > surfaces[2].frame.maxY)
        #expect(abs(surfaces[0].frame.minY - surfaces[1].frame.maxY - 8) < 0.5)
        #expect(abs(surfaces[1].frame.minY - surfaces[2].frame.maxY - 8) < 0.5)
        #expect(!surfaces[0].frame.intersects(surfaces[1].frame))
        #expect(!surfaces[1].frame.intersects(surfaces[2].frame))
    }

    @Test
    @MainActor
    func responseBubbleShowsEveryTurnNotJustTheLatest() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        let messages = [
            ChatMessage(role: .user, text: "첫 질문"),
            ChatMessage(role: .assistant, text: "첫 답변"),
            ChatMessage(role: .user, text: "두 번째 질문"),
            ChatMessage(role: .assistant, text: "두 번째 답변"),
        ]

        controller.renderChat(ChatBubbleState(messages: messages))
        controller.render(PetResponsePolicy.content(for: "두 번째 답변"))
        controller.view.layoutSubtreeIfNeeded()

        let values = textFields(in: controller.view).map(\.stringValue)
        #expect(messages.allSatisfy { values.contains($0.text) })
        #expect(values.filter { $0 == "두 번째 답변" }.count == 1)
    }

    @Test
    @MainActor
    func responseBubbleScrollsWhenTheTranscriptExceedsTheMaximumHeight() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.renderChat(ChatBubbleState(messages: (0..<30).map {
            ChatMessage(
                role: $0.isMultiple(of: 2) ? .user : .assistant,
                text: "긴 대화 메시지 \($0)"
            )
        }))
        controller.render(PetResponsePolicy.content(for: "긴 대화 메시지 29"))
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        let scroll = try #require(scrollViews(in: controller.view).first)
        let document = try #require(scroll.documentView)
        #expect(controller.preferredSize.height == 310)
        #expect(scroll.hasVerticalScroller)
        #expect(document.frame.height > scroll.contentView.bounds.height)
    }

    @Test
    @MainActor
    func closingAndReopeningTheResponseBubblePreservesTheTranscript() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let controller = QuickMenuPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let empty = NSPasteboard(name: .init(UUID().uuidString))
        empty.clearContents()

        controller.toggleStagedDraftBubble(empty)
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        composer.stringValue = "첫 질문"
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)
        try #require(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()

        #expect(controller.chatStateForTesting.messages.count == 2)
        controller.toggleStagedDraftBubble(empty)
        try pressButton(accessibilityLabel: "답변 말풍선 닫기", in: controller.responsePanel.contentView)
        #expect(!controller.responsePanel.isVisible)
        controller.toggleStagedDraftBubble(empty)

        #expect(textFields(in: controller.responsePanel.contentView).contains {
            $0.stringValue == "첫 질문"
        })
        #expect(textFields(in: controller.responsePanel.contentView).contains {
            $0.stringValue == "완료"
        })
    }

    @Test
    @MainActor
    func newSessionResetStillClearsTheCompactTranscript() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let controller = ChatPanelController(
            petController: FloatingPetWindowController {},
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            resetAgentSession: { true }
        )
        controller.setDraftText("첫 질문")
        #expect(controller.sendDraftFromResponse())
        try #require(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForSendForTesting()
        #expect(controller.state.messages.count == 2)

        let view = try #require(controller.panel.contentView)
        try pressButton(titled: "새 세션", in: view)
        await controller.waitForRestartForTesting()

        #expect(controller.state.messages.isEmpty)
        let resetState = controller.state
        let response = ResponseBubbleViewController()
        _ = response.view
        response.render(PetResponsePolicy.content(for: "메시지를 입력하고 Return을 누르세요."))
        response.renderChat(resetState)

        #expect(textFields(in: response.view).contains {
            $0.stringValue == "메시지를 입력하고 Return을 누르세요."
        })
        #expect(!textFields(in: response.view).contains {
            $0.stringValue == "첫 질문" || $0.stringValue == "완료"
        })
    }

    @Test
    @MainActor
    func responseBubbleErrorStillShowsItsMessageAlongsideThePriorTurns() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.renderChat(ChatBubbleState(messages: [
            ChatMessage(role: .user, text: "질문"),
            ChatMessage(role: .assistant, text: "이전 답변"),
        ]))
        let error = UserFacingErrorCategory.invalidFile.message
        controller.render(PetResponsePolicy.error(message: error))

        #expect(textFields(in: controller.view).contains { $0.stringValue == "질문" })
        #expect(textFields(in: controller.view).contains { $0.stringValue == "이전 답변" })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == UserFacingErrorCategory.invalidFile.message
        })
    }

    @Test
    @MainActor
    func responseKeepsComposerOrderedAccessibleAndFocused() throws {
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

        let composerSurface = try surface("response-inline-composer-surface", in: controller.view)
        let detail = try surface("response-detail-action-surface", in: controller.view)
        let scroll = try #require(scrollViews(in: controller.view).first)
        let composer = try #require(textFields(in: controller.view).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })

        #expect(!composerSurface.isHidden)
        #expect(!composerSurface.isAccessibilityElement())
        controller.beginInlineCompose()
        controller.view.frame.size = controller.preferredSize
        controller.view.layoutSubtreeIfNeeded()

        #expect(!composerSurface.isHidden)
        #expect(composerSurface.frame.minY > detail.frame.maxY)
        #expect(composer.stringValue == "보존할 초안")
        #expect(panel.canBecomeKey)
        #expect(panel.firstResponder === composer.currentEditor())
        #expect(scroll.documentView?.isDescendant(of: composerSurface) == false)
        #expect(scroll.documentView?.isDescendant(of: detail) == false)
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
    func composerConstraintTracksDraftAttachmentsAndPreferredHeight() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.renderChat(ChatBubbleState())
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
    func constrainedErrorWithAttachmentKeepsEverySurfaceInsideNegativeOriginPanel() throws {
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
        controller.fitPanelHeight(220)
        controller.view.frame = CGRect(x: -720, y: -360, width: 360, height: 220)
        controller.view.layoutSubtreeIfNeeded()

        let surfaceIDs = Set([
            "response-body-surface",
            "response-inline-composer-surface",
            "response-detail-action-surface",
        ])
        let visibleSurfaces = flattened(controller.view).filter {
            surfaceIDs.contains($0.identifier?.rawValue ?? "") && !$0.isHidden
        }
        let localBounds = controller.view.bounds
        #expect(visibleSurfaces.count == 3)
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
            $0.title == "채팅창 상세"
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
    func droppedFilesStageIntoTheChatDraftAndRejectInvalidOrRepeatedDrops() async throws {
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
        #expect(controller.chatStateForTesting.draftAttachments.map(\.url) == [file])
        #expect(controller.responsePanel.isVisible)
        #expect(await sender.requestCount == 0)

        #expect(!controller.canAcceptDroppedFiles([file]))
        #expect(!controller.feedDroppedFiles([file]))
        #expect(controller.chatStateForTesting.draftAttachments.map(\.url) == [file])

        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        composer.stringValue = "summarize this"
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)

        try #require(await sender.waitForRequestCount(1))
        let request = try #require(await sender.requests.first)
        #expect(request.attachments.map(\.url) == [file])
        #expect(!request.text.contains(file.path))

        await sender.completeRequest(at: 0)
    }

    @Test
    @MainActor
    func imageOnlyClipboardDraftSendsOnReturnExactlyOnce() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        #expect(controller.responsePanel.isVisible)
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        let fieldEditor = try #require(composer.currentEditor())
        #expect(composer.window?.firstResponder === fieldEditor)

        let firstResponder = try #require(composer.window?.firstResponder)
        _ = firstResponder.tryToPerform(
            #selector(NSResponder.insertNewline(_:)),
            with: nil
        )
        try #require(await sender.waitForRequestCount(1))
        #expect(await sender.requestCount == 1)

        let request = try #require(await sender.requests.first)
        let attachment = try #require(request.attachments.first)
        #expect(request.attachments.count == 1)
        #expect(attachment.kind == .image)
        #expect(request.currentTurnText == "")
        #expect(!request.text.contains(attachment.url.path))

        _ = fieldEditor.tryToPerform(
            #selector(NSResponder.insertNewline(_:)),
            with: nil
        )
        #expect(await sender.requestCount == 1)

        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()
    }

    @Test
    @MainActor
    func clipboardStagingPrefersFilesOverImageAndText() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clipboard.txt")
        try Data("clipboard".utf8).write(to: file)

        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([
            file as NSURL,
            imageForPasteboard(),
            "  clipboard text  " as NSString,
        ])))
        #expect(controller.chatStateForTesting.draftAttachments.map(\.url) == [file])
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(controller.responsePanel.isVisible)
        #expect(!controller.chatPanelForTesting.isVisible)
        #expect(textFields(in: controller.responsePanel.contentView).contains {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        #expect(await sender.requestCount == 0)
        #expect(pet.presentationModel.chewFrame == .resting)
    }

    @Test
    @MainActor
    func clipboardStagingPrefersImageOverTextWhenNoFileIsPresent() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([
            imageForPasteboard(),
            "  image text  " as NSString,
        ])))
        let attachments = controller.chatStateForTesting.draftAttachments
        #expect(attachments.count == 1)
        #expect(attachments.first?.isTemporary == true)
        #expect(attachments.first?.url.lastPathComponent.hasPrefix(CaptureTemporaryFileCleanup.filenamePrefix) == true)
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(await sender.requestCount == 0)
    }

    @Test
    @MainActor
    func clipboardStagingUsesTextWhenNoFileOrImageIsPresent() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([
            "  text only  " as NSString,
        ])))
        #expect(controller.chatStateForTesting.draftText == "text only")
        #expect(controller.chatStateForTesting.draftAttachments.isEmpty)
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        #expect(composer.stringValue == "text only")
        #expect(await sender.requestCount == 0)
    }

    @Test
    @MainActor
    func repeatedClipboardFeedIsRejectedWhileAnAttachmentIsStaged() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clipboard.txt")
        try Data("clipboard".utf8).write(to: file)

        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([file as NSURL])))
        #expect(!controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        #expect(!controller.feedFromClipboard(pasteboard(["second text" as NSString])))
        #expect(controller.chatStateForTesting.draftAttachments.map(\.url) == [file])
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(await sender.requestCount == 0)
    }

    @Test
    @MainActor
    func repeatedClipboardFeedIsRejectedWhileDraftTextIsStagedAndDoesNotAppend() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard(["clipboard text" as NSString])))
        #expect(!controller.feedFromClipboard(pasteboard(["more text" as NSString])))
        #expect(controller.chatStateForTesting.draftText == "clipboard text")
        #expect(await sender.requestCount == 0)
    }

    @Test
    @MainActor
    func toggleStagedDraftBubbleStagesOnFirstClickHidesOnSecondAndReopensWithoutRestagingOnThird() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        controller.toggleStagedDraftBubble(pasteboard(["clipboard text" as NSString]))
        #expect(controller.chatStateForTesting.draftText == "clipboard text")
        #expect(controller.responsePanel.isVisible)

        controller.toggleStagedDraftBubble(pasteboard(["ignored while hiding" as NSString]))
        #expect(!controller.responsePanel.isVisible)
        #expect(controller.chatStateForTesting.draftText == "clipboard text")

        controller.toggleStagedDraftBubble(pasteboard(["should not be staged" as NSString]))
        #expect(controller.responsePanel.isVisible)
        #expect(controller.chatStateForTesting.draftText == "clipboard text")
        #expect(await sender.requestCount == 0)
    }

    @Test
    @MainActor
    func togglingAfterSendWithUnchangedClipboardDoesNotRestage() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let board = pasteboard(["clipboard text" as NSString])

        controller.toggleStagedDraftBubble(board)
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        composer.stringValue = "send this"
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)
        try #require(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()

        controller.toggleStagedDraftBubble(board)

        #expect(controller.responsePanel.isVisible)
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        }?.stringValue == "")
        #expect(await sender.requestCount == 1)
    }

    @Test
    @MainActor
    func togglingAfterSendWithNewClipboardStagesNewContent() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let board = pasteboard(["first text" as NSString])

        controller.toggleStagedDraftBubble(board)
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        composer.stringValue = "send this"
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)
        try #require(await sender.waitForRequestCount(1))
        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()

        board.clearContents()
        #expect(board.writeObjects(["new text" as NSString]))
        controller.toggleStagedDraftBubble(board)

        #expect(controller.responsePanel.isVisible)
        #expect(controller.chatStateForTesting.draftText == "new text")
    }

    @Test
    @MainActor
    func toggleWithNoPendingDraftAndNoNewClipboardOpensEmptyComposer() throws {
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
        let empty = NSPasteboard(name: .init(UUID().uuidString))
        empty.clearContents()

        controller.toggleStagedDraftBubble(empty)

        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        #expect(controller.responsePanel.isVisible)
        #expect(composer.stringValue.isEmpty)
        #expect(composer.window?.firstResponder === composer.currentEditor())
    }

    @Test
    @MainActor
    func responseCloseButtonHidesBubbleAndRestoresPet() throws {
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
        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .completed("완료"))
        )

        #expect(controller.responsePanel.isVisible)
        try pressButton(
            accessibilityLabel: "답변 말풍선 닫기",
            in: controller.responsePanel.contentView
        )

        #expect(!controller.responsePanel.isVisible)
        #expect(pet.isVisible)
        #expect(pet.presentationModel.chewFrame == .resting)
    }

    @Test
    @MainActor
    func clipboardStagingRejectsInvalidFilesWithoutFallingBackToPathText() async throws {
        _ = NSApplication.shared
        let invalid = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard.zip")
        try Data("invalid".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let pasteboard = pasteboard([invalid as NSURL])
        pasteboard.setString(invalid.path, forType: .string)

        #expect(!controller.feedFromClipboard(pasteboard))
        #expect(controller.chatStateForTesting.draftAttachments.isEmpty)
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(!controller.chatPanelForTesting.isVisible)
        #expect(!controller.responsePanel.isVisible)
        #expect(await sender.requestCount == 0)
        #expect(!(await sender.requests).contains { $0.text.contains(invalid.path) })
    }

    @Test
    @MainActor
    func emptyAndUnsupportedClipboardStagesNothingAndOpensNoPanel() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let wasVisible = controller.isVisible

        let empty = NSPasteboard(name: .init(UUID().uuidString))
        empty.clearContents()
        #expect(!controller.feedFromClipboard(empty))
        #expect(controller.isVisible == wasVisible)

        let unsupported = NSPasteboard(name: .init(UUID().uuidString))
        unsupported.clearContents()
        unsupported.setData(Data("unsupported".utf8), forType: NSPasteboard.PasteboardType("com.yumyum.unsupported"))
        #expect(!controller.feedFromClipboard(unsupported))
        #expect(controller.isVisible == wasVisible)
        #expect(controller.chatStateForTesting.draftAttachments.isEmpty)
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(!controller.chatPanelForTesting.isVisible)
        #expect(!controller.responsePanel.isVisible)
        #expect(await sender.requestCount == 0)
        #expect(pet.presentationModel.chewFrame == .resting)
    }

    @Test
    @MainActor
    func clipboardStagingIsRejectedWhileASendIsInFlight() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }
        let board = pasteboard(["first" as NSString])

        #expect(controller.feedFromClipboard(board))
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)
        try #require(await sender.waitForRequestCount(1))
        #expect(!controller.feedFromClipboard(pasteboard(["second" as NSString])))
        #expect(await sender.requestCount == 1)
        #expect(controller.chatStateForTesting.draftText.isEmpty)
        #expect(controller.chatStateForTesting.draftAttachments.isEmpty)
        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()
    }

    @Test
    @MainActor
    func clipboardStagedTextIsSentTogetherWithTheTypedInstruction() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard(["clipboard text" as NSString])))
        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        #expect(composer.stringValue == "clipboard text")
        composer.stringValue = "clipboard text\nadd an instruction"
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)

        try #require(await sender.waitForRequestCount(1))
        let request = try #require(await sender.requests.first)
        #expect(request.currentTurnText == "clipboard text\nadd an instruction")
        #expect(request.attachments.isEmpty)
        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()
    }

    @Test
    @MainActor
    func clipboardStagedImageIsSentWithTheTypedInstructionAndItsTemporaryFileIsRemoved() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        let stagedAttachment = try #require(controller.chatStateForTesting.draftAttachments.first)
        let url = stagedAttachment.url
        #expect(stagedAttachment.isTemporary)
        #expect(url.lastPathComponent.hasPrefix(CaptureTemporaryFileCleanup.filenamePrefix))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await sender.requestCount == 0)

        let composer = try #require(textFields(in: controller.responsePanel.contentView).first {
            $0.accessibilityLabel() == "인라인 채팅 메시지"
        })
        composer.stringValue = "describe this image"
        let returnAction = try #require(composer.action)
        composer.sendAction(returnAction, to: composer.target)

        try #require(await sender.waitForRequestCount(1))
        let request = try #require(await sender.requests.first)
        let attachment = try #require(request.attachments.first)
        #expect(attachment.kind == .image)
        #expect(request.currentTurnText == "describe this image")
        #expect(!request.text.contains(url.path))

        await sender.completeRequest(at: 0)
        await controller.waitForChatSendForTesting()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    @MainActor
    func removingTheStagedAttachmentDeletesItsTemporaryFileAndUnblocksTheNextClipboardFeed() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        let url = try #require(controller.chatStateForTesting.draftAttachments.first).url
        #expect(FileManager.default.fileExists(atPath: url.path))
        let view = try #require(controller.responsePanel.contentView)
        let remove = try #require(buttons(in: view).first {
            $0.accessibilityLabel() == "\(url.lastPathComponent) 첨부 제거"
        })
        remove.performClick(nil)

        #expect(controller.chatStateForTesting.draftAttachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        #expect(await sender.requestCount == 0)
    }

    @Test
    @MainActor
    func stagedImageAttachmentRendersAThumbnailInTheResponseBubble() throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        let view = try #require(controller.responsePanel.contentView)
        let thumbnail = try #require(
            flattened(view).first {
                $0.identifier?.rawValue == "response-attachment-thumbnail"
            } as? NSImageView
        )
        #expect(thumbnail.image?.size == CGSize(width: 4, height: 4))
    }

    @Test
    @MainActor
    func abandonedClipboardImageStagingSurvivesPanelCloseAndIsRemovedOnTermination() async throws {
        _ = NSApplication.shared
        let sender = ControlledPromptSender()
        let pet = FloatingPetWindowController {}
        let controller = QuickMenuPanelController(
            petController: pet,
            viewModel: YumYumAppViewModel(fixtureProbe: UnusedFixtureProbe()),
            workflow: FeedWorkflow(sender: sender, feedback: SilentFeedFeedback()),
            openSettings: {}
        )
        defer { controller.prepareForTermination() }

        #expect(controller.feedFromClipboard(pasteboard([imageForPasteboard()])))
        let attachment = try #require(controller.chatStateForTesting.draftAttachments.first)
        let url = attachment.url
        #expect(url.lastPathComponent.hasPrefix(CaptureTemporaryFileCleanup.filenamePrefix))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await sender.requestCount == 0)

        controller.hide()

        #expect(controller.chatStateForTesting.draftAttachments == [attachment])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await sender.requestCount == 0)

        controller.prepareForTermination()

        #expect(controller.chatStateForTesting.draftAttachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await sender.requestCount == 0)
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
        defer {
            responsePanel.orderOut(nil)
            responsePanel.contentViewController = nil
            chatController.panel.orderOut(nil)
            chatController.panel.contentViewController = nil
        }
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
        let detail = try #require(buttons(in: view).first { $0.title == "채팅창 상세" })
        #expect(!detail.isHidden)
        responseController.beginInlineCompose()
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
        try #require(await sender.waitForRequestCount(1))
        composer.sendAction(returnAction, to: composer.target)
        #expect(await sender.requestCount == 1)
        let returnRequest = try #require(await sender.requests.first)
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
        try #require(await sender.waitForRequestCount(2))
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

        #expect(controller.feedFromClipboard(pasteboard(["초안" as NSString])))
        #expect(panel.canBecomeKey)
        panel.resignKey()
        #expect(!panel.canBecomeKey)

        try pressButton(titled: "채팅창 상세", in: panel.contentView)
        #expect(!panel.canBecomeKey)

        controller.applyFeedStatus(
            FeedStatusUpdate(generation: UUID(), status: .completed("다시"))
        )
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
        #expect(controller.feedFromClipboard(pasteboard(["staged" as NSString])))
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
    func attachmentChromeFitsItsArrangedSubviews() throws {
        _ = NSApplication.shared
        let controller = ResponseBubbleViewController()
        _ = controller.view
        controller.render(PetResponsePolicy.content(for: "완료"))
        controller.renderChat(ChatBubbleState())
        let plainHeight = controller.preferredSize.height
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

        #expect(controller.preferredSize.height > plainHeight)
        #expect(!controller.view.hasAmbiguousLayout)
    }

    @Test
    @MainActor
    func responseLanguageRefreshPreservesContentDraftAttachmentsAndScroll() throws {
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
        controller.responseScrollOriginForTesting = CGPoint(x: 0, y: 4)

        controller.applyLanguage(.korean)

        #expect(buttons(in: controller.view).contains { $0.title == "채팅창 상세" })
        #expect(buttons(in: controller.view).contains { $0.title == "재시도" && !$0.isHidden })
        #expect(textFields(in: controller.view).contains {
            $0.stringValue == "keep draft"
                && $0.accessibilityLabel() == "인라인 채팅 메시지"
                && $0.accessibilityHelp() == "Return을 눌러 전송합니다"
        })
        #expect(flattened(controller.view).contains {
            $0.accessibilityLabel() == "첨부 파일 report.pdf"
                && textFields(in: $0).contains { $0.stringValue == "report.pdf" }
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

private actor BlockingPanelReset {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func perform() async -> Bool {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        return true
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
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
        guard continuations.indices.contains(index) else {
            Issue.record("No controlled request at index \(index)")
            return
        }
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
