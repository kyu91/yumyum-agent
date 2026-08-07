import AppKit
import Combine
import QuartzCore
import UniformTypeIdentifiers
import YumYumCore

@MainActor
final class QuickMenuPanelController: NSObject {
    static let actionPanelSize = CGSize(
        width: 248,
        height: CGFloat(ActionBubbleAction.allCases.count * 44 + 16)
            + CGFloat(max(ActionBubbleAction.allCases.count - 1, 0) * 8)
    )
    static let thinkingPanelSize = CGSize(width: 112, height: 48)

    private let petController: FloatingPetWindowController
    private weak var viewModel: YumYumAppViewModel?
    private let chatController: ChatPanelController
    private let openSettings: @MainActor () -> Void
    private let layout = QuickMenuLayout()
    private let captureCoordinator = ScreenCaptureCoordinator()
    private let flightPolicy = FeedPreviewFlightPolicy()
    private let thinkingPolicy = ThinkingAnimationPolicy()
    private let actionViewController = ActionBubbleViewController()
    private let thinkingViewController = ThinkingBubbleViewController()
    private let responseViewController = ResponseBubbleViewController()

    private var flow = ActionFlowStateMachine()
    private var canFeed = false
    private var isCheckingAgents = false
    private var presentationEnabled = true
    private var captureTask: Task<Void, Never>?
    private var captureGeneration: UUID?
    private var captureShouldRestorePet = false
    private var fileGeneration: UUID?
    private var activeOpenPanel: NSOpenPanel?
    private var animationPanel: NSPanel?
    private var thinkingTask: Task<Void, Never>?
    private var thinkingGeneration: UUID?
    private var codexLoginObservation: AnyCancellable?
    private var lastReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#if DEBUG
    private(set) var responseFrameUpdateCountForTesting = 0
#endif
    private var lastActionSourceRect: CGRect?
    private var theme = AppTheme.dark

    let actionPanel: ActionBubblePanel
    let thinkingPanel: NSPanel
    let responsePanel: ResponseBubblePanel

    var isVisible: Bool { actionPanel.isVisible }

    init(
        petController: FloatingPetWindowController,
        viewModel: YumYumAppViewModel,
        workflow: FeedWorkflow,
        openSettings: @escaping @MainActor () -> Void
    ) {
        self.petController = petController
        self.viewModel = viewModel
        self.openSettings = openSettings
        chatController = ChatPanelController(
            petController: petController,
            viewModel: viewModel,
            workflow: workflow
        )
        actionPanel = ActionBubblePanel(
            contentRect: CGRect(origin: .zero, size: Self.actionPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        thinkingPanel = Self.makeBubblePanel(
            size: Self.thinkingPanelSize,
            title: AppText.localized("YumYum Agent 생각 중")
        )
        responsePanel = ResponseBubblePanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 360, height: 120)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        codexLoginObservation = viewModel.$codexLoginState.dropFirst().sink { [weak self, weak viewModel] _ in
            guard let viewModel else { return }
            self?.update(snapshot: viewModel.agentSnapshot)
        }

        Self.configure(
            actionPanel,
            level: .popUpMenu,
            title: AppText.localized("YumYum Agent 액션")
        )
        actionPanel.contentViewController = actionViewController
        actionPanel.onCancel = { [weak self] in self?.dismissActionBubble() }
        actionPanel.onMoveFocus = { [weak actionViewController] delta in
            actionViewController?.moveFocus(delta: delta)
        }
        actionPanel.onActivateFocused = { [weak actionViewController] in
            actionViewController?.activateFocusedRow()
        }
        actionViewController.onAction = { [weak self] action in
            self?.select(action)
        }

        thinkingPanel.contentViewController = thinkingViewController
        Self.configure(responsePanel, level: .floating, title: AppText.localized("YumYum Agent 답변"))
        responsePanel.contentViewController = responseViewController
        responseViewController.onOpenChat = { [weak self] in
            self?.openChatFromResponse()
        }
        responseViewController.onRetry = { [weak self] in
            self?.retryFromResponse()
        }
        responseViewController.onDraftChanged = { [weak chatController] text in
            chatController?.setDraftText(text)
        }
        responseViewController.onSend = { [weak self] in
            guard self?.chatController.sendDraftFromResponse() == true else { return }
            self?.responsePanel.orderOut(nil)
        }
        responseViewController.onRequestInput = { [weak self] in
            self?.responsePanel.beginInput()
        }
        responseViewController.onPreferredSizeChanged = { [weak self] in
            self?.updateResponseFrame()
        }
        chatController.onStateChanged = { [weak self] state in
            self?.responseViewController.renderChat(state)
            if self?.responsePanel.isVisible == true {
                self?.updateResponseFrame()
            }
        }
        chatController.onWillBeginCapture = { [weak self] in
            self?.hideAuxiliaryBubblesForCapture()
        }
        chatController.onExplicitCancel = { [weak self] in
            self?.stopActivePresentation()
        }
        chatController.onVisibilityChanged = { [weak self] isVisible in
            if isVisible {
                self?.responsePanel.orderOut(nil)
            }
            self?.updateExternalThinkingVisibility()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        petController.configureFileDrop(
            canAccept: { [weak self] urls in
                self?.canAcceptDroppedFiles(urls) == true
            },
            perform: { [weak self] urls in
                self?.feedDroppedFiles(urls) == true
            }
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func setPresentationEnabled(_ enabled: Bool) {
        presentationEnabled = enabled
        guard !enabled else { return }
        cancelCapture(restorePet: false)
        cancelFileSelection()
        actionPanel.orderOut(nil)
        chatController.hide(restorePetAfterCapture: false)
        responsePanel.orderOut(nil)
        stopThinking()
        removeAnimationPreview()
        flow.returnToPet()
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        actionPanel.appearance = theme.appearance
        thinkingPanel.appearance = theme.appearance
        responsePanel.appearance = theme.appearance
        actionViewController.applyTheme(theme)
        chatController.applyTheme(theme)
        thinkingViewController.applyTheme(theme)
        responseViewController.applyTheme(theme)
        if responsePanel.isVisible {
            updateResponseFrame()
        }
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        let responseScrollOrigin = responseViewController.responseScrollOrigin
        let firstResponder = responsePanel.firstResponder
        actionViewController.applyLanguage(language)
        thinkingViewController.applyLanguage(language)
        responseViewController.applyLanguage(language)
        chatController.applyLanguage(language)
        actionPanel.title = AppText.localized(english: "YumYum Agent Actions", korean: "YumYum Agent 액션", language: language)
        thinkingPanel.title = AppText.localized(english: "YumYum Agent is thinking", korean: "YumYum Agent 생각 중", language: language)
        responsePanel.title = AppText.localized(english: "YumYum Agent Response", korean: "YumYum Agent 답변", language: language)
        if responsePanel.isVisible {
            updateResponseFrame()
            responseViewController.restoreResponseScrollOrigin(responseScrollOrigin)
            if let firstResponder {
                responsePanel.makeFirstResponder(firstResponder)
            }
        }
    }

    func canAcceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard presentationEnabled, !chatController.isSending else {
            return false
        }
        return (try? FeedValidator().validate(
            FeedInput(fileURLs: urls)
        ).attachments.isEmpty) == false
    }

    @discardableResult
    func feedDroppedFiles(_ urls: [URL]) -> Bool {
        guard presentationEnabled,
              !chatController.isSending,
              let validated = try? FeedValidator().validate(
                  FeedInput(fileURLs: urls)
              ) else {
            return false
        }
        return chatController.feedAttachments(
            validated.attachments.map {
                ChatDraftAttachment(url: $0.url, isTemporary: false)
            },
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    @discardableResult
    func feedFromClipboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard presentationEnabled,
              !chatController.isSending,
              captureTask == nil,
              fileGeneration == nil else {
            return false
        }

        let urls = FloatingPetHostingView<YumYumPetView>.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            guard let validated = try? FeedValidator().validate(
                FeedInput(fileURLs: urls)
            ), chatController.stageAttachments(
                validated.attachments.map {
                    ChatDraftAttachment(url: $0.url, isTemporary: false)
                }
            ) else {
                return false
            }
            return presentStagedDraftBubble()
        }

        if let url = Self.writeTemporaryPNG(from: pasteboard) {
            guard chatController.stageAttachments([
                ChatDraftAttachment(url: url, isTemporary: true),
            ]) else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return presentStagedDraftBubble()
        }

        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return false
        }
        let existing = chatController.state.draftText
        chatController.setDraftText(existing.isEmpty ? text : existing + "\n" + text)
        return presentStagedDraftBubble()
    }

    @discardableResult
    private func presentStagedDraftBubble() -> Bool {
        showResponse(Self.stagedDraftContent())
        if responsePanel.isVisible {
            responseViewController.beginInlineCompose()
        }
        return true
    }

    private static func stagedDraftContent() -> PetResponseContent {
        PetResponsePolicy.content(for: AppText.localized(
            english: "Staged for chat. Add an instruction and press Return.",
            korean: "채팅 초안에 담았어요. 지침을 입력하고 Return을 누르세요."
        ))
    }

    private static func writeTemporaryPNG(from pasteboard: NSPasteboard) -> URL? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffRepresentation = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(CaptureTemporaryFileCleanup.filenamePrefix)\(UUID().uuidString).png"
        )
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func show() {
        guard presentationEnabled,
              captureTask == nil,
              fileGeneration == nil,
              !chatController.isCapturing else {
            return
        }
        perform(flow.openActionBubble())
    }

    func dismissActionBubble() {
        perform(flow.dismissActionBubble())
    }

    func hide(restorePetAfterCapture: Bool = true) {
        cancelCapture(restorePet: restorePetAfterCapture)
        cancelFileSelection()
        actionPanel.orderOut(nil)
        chatController.hide(restorePetAfterCapture: restorePetAfterCapture)
        responsePanel.orderOut(nil)
        stopThinking()
        removeAnimationPreview()
        flow.returnToPet()
    }

    func prepareForTermination() {
        presentationEnabled = false
        cancelCapture(restorePet: false)
        cancelFileSelection()
        thinkingTask?.cancel()
        thinkingTask = nil
        chatController.prepareForTermination()
        actionPanel.orderOut(nil)
        responsePanel.orderOut(nil)
        thinkingPanel.orderOut(nil)
        removeAnimationPreview()
    }

    func showCheckingStatus() {
        isCheckingAgents = true
        actionViewController.setFeedActionsEnabled(false)
    }

    func update(snapshot: AgentRegistrySnapshot) {
        isCheckingAgents = false
        canFeed = viewModel?.canSendPrompt ?? false
        actionViewController.setFeedActionsEnabled(
            canFeed && !isCheckingAgents && !chatController.isSending
        )
        chatController.update(snapshot: snapshot)
    }

    func animatePreview(_ preview: FeedPreview, reduceMotion: Bool) async {
        lastReduceMotion = reduceMotion
        guard presentationEnabled else { return }

        let contentSize = previewContentSize(for: preview)
        let sourceRect = preview.sourceRect
            ?? lastActionSourceRect
            ?? CGRect(
                x: petController.panel.frame.midX - contentSize.width / 2,
                y: petController.panel.frame.maxY + 18,
                width: contentSize.width,
                height: contentSize.height
            )
        let keyframes = flightPolicy.keyframes(
            contentSize: contentSize,
            sourceRect: sourceRect,
            targetRect: petController.mouthTargetFrame,
            reduceMotion: reduceMotion
        )
        guard let first = keyframes.first else { return }

        let previewPanel = makeAnimationPanel(preview: preview, frame: first.frame)
        removeAnimationPreview()
        animationPanel = previewPanel
        previewPanel.alphaValue = first.alpha
        previewPanel.orderFrontRegardless()

        for (start, end) in zip(keyframes, keyframes.dropFirst()) {
            if Task.isCancelled { break }
            await animate(
                previewPanel,
                to: end,
                duration: Double(end.milliseconds - start.milliseconds) / 1_000
            )
        }
        previewPanel.orderOut(nil)
        if animationPanel === previewPanel {
            animationPanel = nil
        }
    }

    func applyFeedStatus(_ update: FeedStatusUpdate) {
        switch update.status {
        case .validating, .animating, .sending:
            chatController.setWorkflowBusy(true)
        case .idle, .completed, .failed, .cancelled:
            chatController.setWorkflowBusy(false)
        }
        switch update.status {
        case .idle:
            break
        case .validating:
            responsePanel.orderOut(nil)
        case .animating:
            break
        case .sending:
            startThinking(generation: update.generation)
        case let .completed(response):
            showResponse(
                PetResponsePolicy.content(for: response),
                resetPet: false
            )
        case let .failed(message):
            showResponse(
                PetResponsePolicy.error(message: message),
                resetPet: false
            )
        case .cancelled:
            responsePanel.orderOut(nil)
            stopThinking(resetPet: false)
            removeAnimationPreview()
            flow.returnToPet()
        }
    }

#if DEBUG
    func renderChatForTesting(_ state: ChatBubbleState) {
        chatController.renderForTesting(state)
    }

    func prepareResponseForCaptureForTesting() {
        hideAuxiliaryBubblesForCapture()
    }

    var chatStateForTesting: ChatBubbleState {
        chatController.state
    }

    var chatPanelForTesting: QuickMenuPanel {
        chatController.panel
    }

    func waitForChatSendForTesting() async {
        await chatController.waitForSendForTesting()
    }

    func updateActionFrameForTesting(petFrame: CGRect, visibleFrames: [CGRect]) {
        updateActionFrame(petFrame: petFrame, visibleFrames: visibleFrames)
    }
#endif

    private func select(_ action: ActionBubbleAction) {
        guard action != .capture && action != .findFile
                || canFeed && !isCheckingAgents && !chatController.isSending else {
            return
        }
        perform(flow.select(action, generation: UUID()))
        if action == .feedClipboard {
            _ = feedFromClipboard()
        }
    }

    private func perform(_ effects: [ActionFlowEffect]) {
        for effect in effects {
            switch effect {
            case .showPet:
                if presentationEnabled {
                    petController.show()
                }
            case .showActionBubble:
                showActionBubble()
            case .hideActionBubble:
                lastActionSourceRect = actionPanel.frame
                actionPanel.orderOut(nil)
                updateExternalThinkingVisibility()
            case .hideAllForCapture:
                hideAllForCapture()
            case let .beginCapture(generation):
                beginCapture(generation: generation)
            case let .beginFileSelection(generation):
                beginFileSelection(generation: generation)
            case let .submitMeal(meal, _):
                submit(meal)
            case let .showChat(scrollToLatest):
                showChat(scrollToLatest: scrollToLatest)
            case .hideChat:
                chatController.hide()
            case .hideResponseBubble:
                responsePanel.orderOut(nil)
            case .openSettings:
                openSettings()
            }
        }
    }

    private func showActionBubble() {
        thinkingPanel.orderOut(nil)
        actionViewController.setFeedActionsEnabled(
            canFeed && !isCheckingAgents && !chatController.isSending
        )
        updateActionFrame()
        actionPanel.makeKeyAndOrderFront(nil)
        actionViewController.focusFirstRow()
    }

    private func showChat(scrollToLatest: Bool) {
        actionPanel.orderOut(nil)
        responsePanel.orderOut(nil)
        let shouldScrollToLatest = scrollToLatest && !chatController.hasPresented
        chatController.show()
        updateExternalThinkingVisibility()
        if shouldScrollToLatest {
            chatController.scrollToLatest()
        }
    }

    private func openChatFromResponse() {
        perform(flow.responseClicked())
    }

    private func retryFromResponse() {
        responsePanel.orderOut(nil)
        flow.returnToPet()
        chatController.retryLastSend()
    }

    private func hideAllForCapture() {
        captureShouldRestorePet = petController.isVisible && presentationEnabled
        lastActionSourceRect = actionPanel.frame
        actionPanel.orderOut(nil)
        chatController.hide(restorePetAfterCapture: false)
        responsePanel.orderOut(nil)
        stopThinking()
        removeAnimationPreview()
        petController.hide()
        CATransaction.flush()
    }

    private func hideAuxiliaryBubblesForCapture() {
        actionPanel.orderOut(nil)
        responsePanel.orderOut(nil)
        stopThinking()
        removeAnimationPreview()
        flow.returnToPet()
    }

    private func stopActivePresentation() {
        responsePanel.orderOut(nil)
        stopThinking()
        removeAnimationPreview()
        flow.returnToPet()
    }

    private func beginCapture(generation: UUID) {
        guard captureTask == nil else { return }
        captureGeneration = generation
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            do {
                let result = try await captureCoordinator.capture()
                guard !Task.isCancelled,
                      captureGeneration == generation else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }
                finishCapture(
                    .selected(url: result.url, region: result.selectedRegion),
                    generation: generation
                )
            } catch is CancellationError {
                finishCapture(.cancelled, generation: generation)
            } catch let error as ScreenCaptureCoordinatorError {
                switch error {
                case .permissionDenied:
                    finishCapture(.permissionDenied, generation: generation)
                default:
                    finishCapture(
                        .failed(error.errorDescription ?? AppText.localized("화면을 캡처하지 못했습니다.")),
                        generation: generation
                    )
                }
            } catch {
                finishCapture(
                    .failed(AppText.localized("화면을 캡처하지 못했습니다.")),
                    generation: generation
                )
            }
        }
    }

    private func finishCapture(
        _ outcome: ActionCaptureOutcome,
        generation: UUID
    ) {
        guard captureGeneration == generation else {
            if case let .selected(url, _) = outcome {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        captureGeneration = nil
        captureTask = nil
        let shouldRestorePet = captureShouldRestorePet
        captureShouldRestorePet = false
        let effects = flow.finishCapture(outcome, generation: generation)
        if shouldRestorePet {
            perform(effects)
        } else {
            if case let .selected(url, _) = outcome {
                try? FileManager.default.removeItem(at: url)
            }
            flow.returnToPet()
        }
    }

    private func cancelCapture(restorePet: Bool) {
        guard let generation = captureGeneration else { return }
        captureGeneration = nil
        captureCoordinator.cancel()
        captureTask?.cancel()
        captureTask = nil
        let shouldRestore = captureShouldRestorePet && restorePet
        captureShouldRestorePet = false
        let effects = flow.finishCapture(.cancelled, generation: generation)
        if shouldRestore {
            perform(effects)
        } else {
            flow.returnToPet()
        }
    }

    private func beginFileSelection(generation: UUID) {
        guard fileGeneration == nil else { return }
        lastActionSourceRect = actionPanel.frame
        fileGeneration = generation
        let openPanel = NSOpenPanel()
        activeOpenPanel = openPanel
        openPanel.title = AppText.localized("먹일 파일 선택")
        openPanel.prompt = AppText.localized("먹이기")
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = false
        openPanel.allowedContentTypes = [.image, .pdf, .plainText, .sourceCode]
        openPanel.begin { [weak self, weak openPanel] response in
            Task { @MainActor in
                guard let self,
                      self.fileGeneration == generation else {
                    return
                }
                self.fileGeneration = nil
                self.activeOpenPanel = nil
                let outcome: ActionFileOutcome
                if response == .OK, let urls = openPanel?.urls, !urls.isEmpty {
                    outcome = .selected(urls)
                } else {
                    outcome = .cancelled
                }
                self.perform(
                    self.flow.finishFiles(outcome, generation: generation)
                )
            }
        }
    }

    private func cancelFileSelection() {
        activeOpenPanel?.cancel(nil)
        activeOpenPanel = nil
        fileGeneration = nil
        flow.returnToPet()
    }

    private func submit(_ meal: ActionMeal) {
        let attachments = meal.fileURLs.enumerated().map { index, url in
            ChatDraftAttachment(
                url: url,
                isTemporary: meal.temporaryFileURLs.contains(url),
                sourceRect: index == 0 ? meal.sourceRect : nil
            )
        }
        let didStart = chatController.feedAttachments(
            attachments,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard didStart else {
            for url in meal.temporaryFileURLs {
                try? FileManager.default.removeItem(at: url)
            }
            flow.returnToPet()
            return
        }
        actionViewController.setFeedActionsEnabled(false)
    }

    private func startThinking(generation: UUID) {
        stopThinking(resetPet: false)
        thinkingGeneration = generation
        guard presentationEnabled else { return }
        petController.show()
        updateExternalThinkingVisibility()

        let reduceMotion = lastReduceMotion
        if reduceMotion {
            thinkingViewController.setThought(
                thinkingPolicy.thought(at: 0, reduceMotion: true)
            )
            petController.applyChewFrame(
                thinkingPolicy.frame(at: 0, reduceMotion: true)
            )
            return
        }

        thinkingTask = Task { @MainActor [weak self] in
            var elapsed = 0
            while let self,
                  !Task.isCancelled,
                  self.thinkingGeneration == generation {
                self.thinkingViewController.setThought(
                    self.thinkingPolicy.thought(
                        at: elapsed,
                        reduceMotion: false
                    )
                )
                self.petController.applyChewFrame(
                    self.thinkingPolicy.frame(
                        at: elapsed,
                        reduceMotion: false
                    )
                )
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
                elapsed = (elapsed + 150) % ThinkingAnimationPolicy.cycleMilliseconds
            }
        }
    }

    private func stopThinking(resetPet: Bool = true) {
        thinkingGeneration = nil
        thinkingTask?.cancel()
        thinkingTask = nil
        thinkingPanel.orderOut(nil)
        if resetPet {
            petController.resetChewPresentation()
        }
    }

    private func updateExternalThinkingVisibility() {
        guard presentationEnabled,
              thinkingPolicy.showsExternalBubble(
                isThinking: thinkingGeneration != nil,
                isChatVisible: chatController.isVisible
              ) else {
            thinkingPanel.orderOut(nil)
            return
        }
        updateThinkingFrame()
        thinkingPanel.orderFrontRegardless()
    }

    private func showResponse(
        _ content: PetResponseContent,
        resetPet: Bool = true
    ) {
        stopThinking(resetPet: resetPet)
        removeAnimationPreview()
        actionPanel.orderOut(nil)
        guard presentationEnabled else {
            flow.returnToPet()
            return
        }
        guard !chatController.isVisible else {
            responsePanel.orderOut(nil)
            return
        }
        petController.show()
        responseViewController.render(content)
        responseViewController.renderChat(chatController.state)
        flow.showResponse()
        updateResponseFrame()
        responsePanel.orderFrontRegardless()
    }

    private func previewContentSize(for preview: FeedPreview) -> CGSize {
        if preview.sourceRect != nil,
           let url = preview.fileURLs.first,
           let image = NSImage(contentsOf: url),
           image.size.width > 0,
           image.size.height > 0 {
            return image.size
        }
        if !preview.fileURLs.isEmpty {
            return CGSize(
                width: 54 + CGFloat(min(preview.fileURLs.count - 1, 3)) * 16,
                height: 54
            )
        }
        return CGSize(width: 140, height: 32)
    }

    private func makeAnimationPanel(
        preview: FeedPreview,
        frame: CGRect
    ) -> NSPanel {
        let panel = Self.makeBubblePanel(size: frame.size, title: AppText.localized("YumYum Agent 먹이 미리보기"))
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.setFrame(frame, display: false)
        panel.contentView = FeedPreviewContentView(preview: preview)
        return panel
    }

    private func animate(
        _ panel: NSPanel,
        to keyframe: FeedFlightKeyframe,
        duration: TimeInterval
    ) async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(
                    name: keyframe.milliseconds == 100 ? .easeOut : .easeInEaseOut
                )
                panel.animator().setFrame(keyframe.frame, display: true)
                panel.animator().alphaValue = keyframe.alpha
            } completionHandler: {
                continuation.resume()
            }
        }
    }

    private func removeAnimationPreview() {
        animationPanel?.orderOut(nil)
        animationPanel = nil
    }

    private func updateActionFrame() {
        updateActionFrame(
            petFrame: petController.panel.frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    private func updateActionFrame(petFrame: CGRect, visibleFrames: [CGRect]) {
        let placement = layout.placement(
            petFrame: petFrame,
            panelSize: Self.actionPanelSize,
            visibleFrames: visibleFrames
        )
        actionViewController.applyHorizontalAlignment(placement.horizontalAlignment)
        actionPanel.setFrame(placement.frame, display: true)
    }

    private func updateThinkingFrame() {
        thinkingPanel.setFrame(
            layout.panelFrame(
                petFrame: petController.panel.frame,
                panelSize: Self.thinkingPanelSize,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
    }

    private func updateResponseFrame() {
#if DEBUG
        responseFrameUpdateCountForTesting += 1
#endif
        let size = responseViewController.preferredSize
        let frame = layout.panelFrame(
            petFrame: petController.panel.frame,
            panelSize: size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        responseViewController.fitPanelHeight(frame.height)
        responsePanel.setFrame(frame, display: true)
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        if actionPanel.isVisible { updateActionFrame() }
        if thinkingPanel.isVisible { updateThinkingFrame() }
        if responsePanel.isVisible { updateResponseFrame() }
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        lastReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        applyTheme(theme)
        if let generation = thinkingGeneration {
            startThinking(generation: generation)
        }
    }

    private static func makeBubblePanel(size: CGSize, title: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel, level: .floating, title: title)
        panel.ignoresMouseEvents = title == AppText.localized("YumYum Agent 생각 중")
        return panel
    }

    private static func configure(
        _ panel: NSPanel,
        level: NSWindow.Level,
        title: String
    ) {
        panel.title = title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }
}

final class ActionBubblePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onMoveFocus: ((Int) -> Void)?
    var onActivateFocused: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 126:
            onMoveFocus?(-1)
        case 125:
            onMoveFocus?(1)
        case 36, 49:
            onActivateFocused?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class ResponseBubblePanel: NSPanel {
    private var acceptsKeyInput = false

    override var canBecomeKey: Bool { acceptsKeyInput }
    override var canBecomeMain: Bool { false }

    func beginInput() {
        acceptsKeyInput = true
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        acceptsKeyInput = false
        (contentViewController as? ResponseBubbleViewController)?
            .resetActionInteractionState()
    }

    override func orderOut(_ sender: Any?) {
        acceptsKeyInput = false
        (contentViewController as? ResponseBubbleViewController)?
            .resetActionInteractionState()
        super.orderOut(sender)
    }
}

@MainActor
private final class ActionBubbleViewController: NSViewController {
    var onAction: ((ActionBubbleAction) -> Void)?

    private var buttons: [ActionRowButton] = []
    private var actionStack: NSStackView?
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var feedActionsEnabled = false
    private var theme = AppTheme.dark

    override func loadView() {
        let root = NSView(
            frame: CGRect(origin: .zero, size: QuickMenuPanelController.actionPanelSize)
        )
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        buttons = ActionBubbleAction.allCases.map { action in
            let button = ActionRowButton(action: action)
            button.target = self
            button.action = #selector(actionPressed(_:))
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return button
        }
        let stack = NSStackView(views: buttons)
        actionStack = stack
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .trailing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.list)
        stack.setAccessibilityLabel(AppText.localized("YumYum Agent 액션"))
        root.addSubview(stack)
        let leadingConstraint = stack.leadingAnchor.constraint(
            equalTo: root.leadingAnchor,
            constant: 8
        )
        let trailingConstraint = stack.trailingAnchor.constraint(
            equalTo: root.trailingAnchor,
            constant: -8
        )
        stackLeadingConstraint = leadingConstraint
        stackTrailingConstraint = trailingConstraint
        NSLayoutConstraint.activate([
            trailingConstraint,
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 8),
        ])
        for index in buttons.indices {
            buttons[index].nextKeyView = buttons[(index + 1) % buttons.count]
        }
        applyEnabledState()
        applyTheme(theme)
    }

    func applyHorizontalAlignment(_ alignment: QuickMenuHorizontalAlignment) {
        _ = view
        let isLeading = alignment == .leading
        stackLeadingConstraint?.isActive = false
        stackTrailingConstraint?.isActive = false
        actionStack?.alignment = isLeading ? .leading : .trailing
        (isLeading ? stackLeadingConstraint : stackTrailingConstraint)?.isActive = true
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        view.appearance = theme.appearance
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        buttons.forEach { $0.applyTheme(theme) }
    }

    func setFeedActionsEnabled(_ enabled: Bool) {
        feedActionsEnabled = enabled
        if isViewLoaded {
            applyEnabledState()
        }
    }

    func focusFirstRow() {
        buttons.forEach { $0.setFocusVisible(false) }
        let enabled = buttons.map(\.isEnabled)
        guard let index = ActionMenuFocusPolicy.firstEnabledIndex(in: enabled) else {
            return
        }
        view.window?.makeFirstResponder(buttons[index])
    }

    func moveFocus(delta: Int) {
        guard !buttons.isEmpty else { return }
        let current = buttons.firstIndex {
            view.window?.firstResponder === $0
        } ?? 0
        let enabled = buttons.map(\.isEnabled)
        guard let next = ActionMenuFocusPolicy.nextEnabledIndex(
            from: current,
            delta: delta,
            enabled: enabled
        ) else { return }
        buttons.forEach { $0.setFocusVisible($0 === buttons[next]) }
        view.window?.makeFirstResponder(buttons[next])
    }

    func activateFocusedRow() {
        if let focused = buttons.first(where: {
            view.window?.firstResponder === $0
        }), focused.isEnabled {
            focused.performClick(nil)
            return
        }
        guard let index = ActionMenuFocusPolicy.firstEnabledIndex(
            in: buttons.map(\.isEnabled)
        ) else { return }
        buttons[index].performClick(nil)
    }

    private func applyEnabledState() {
        let current = buttons.firstIndex {
            view.window?.firstResponder === $0
        }
        for (index, button) in buttons.enumerated() {
            button.isEnabled = index >= 2 || feedActionsEnabled
        }
        let enabled = buttons.map(\.isEnabled)
        guard let target = ActionMenuFocusPolicy.rehomedIndex(
            current: current,
            enabled: enabled
        ), target != current else {
            return
        }
        view.window?.makeFirstResponder(buttons[target])
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        buttons.forEach { $0.applyLanguage(language) }
        view.setAccessibilityLabel(AppText.localized(
            english: "YumYum Agent Actions",
            korean: "YumYum Agent 액션",
            language: language
        ))
    }

    @objc
    private func actionPressed(_ sender: ActionRowButton) {
        onAction?(sender.actionItem)
    }
}

struct ActionRowAppearance {
    let backgroundColor: NSColor
    let textColor: NSColor
    let opacity: CGFloat

    static func resolve(
        theme: AppTheme,
        isEnabled: Bool = true,
        isHovered: Bool = false,
        isPressed: Bool = false,
        isFocused: Bool = false
    ) -> Self {
        let palette = theme.palette
        guard isEnabled else {
            return Self(
                backgroundColor: palette.surface.withAlphaComponent(1),
                textColor: palette.text,
                opacity: 0.42
            )
        }
        var accent = NSColor.controlAccentColor
        theme.appearance?.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? accent
        }
        let fraction: CGFloat? = isPressed
            ? (theme == .light ? 0.22 : 0.30)
            : (isHovered || isFocused ? (theme == .light ? 0.12 : 0.20) : nil)
        let background = fraction.flatMap {
            palette.surface.blended(withFraction: $0, of: accent)
        } ?? palette.surface
        return Self(
            backgroundColor: background.withAlphaComponent(1),
            textColor: palette.text,
            opacity: 1
        )
    }
}

private final class ActionRowButton: NSButton {
    let actionItem: ActionBubbleAction

    private static let horizontalContentPadding: CGFloat = 28
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isFocusVisible = false
    private var theme = AppTheme.dark

    init(action: ActionBubbleAction) {
        actionItem = action
        super.init(frame: .zero)
        title = action.title
        image = NSImage(
            systemSymbolName: action.symbolName,
            accessibilityDescription: nil
        )
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .center
        font = .systemFont(ofSize: 14, weight: .medium)
        isBordered = false
        focusRingType = .none
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 4
        setAccessibilityLabel(action.title)
        setAccessibilityRole(.button)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += Self.horizontalContentPadding
        size.height = max(size.height, 44)
        return size
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
        super.mouseDown(with: event)
        isPressed = false
        updateAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateAppearance()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        updateAppearance()
        return accepted
    }

    private func updateAppearance() {
        guard let layer else { return }
        let focused = isFocusVisible && window?.firstResponder === self
        let appearance = ActionRowAppearance.resolve(
            theme: theme,
            isEnabled: isEnabled,
            isHovered: isHovered,
            isPressed: isPressed,
            isFocused: focused
        )
        alphaValue = appearance.opacity
        contentTintColor = appearance.textColor
        layer.backgroundColor = appearance.backgroundColor.cgColor
        layer.shadowColor = theme.palette.shadow.cgColor
        layer.shadowOpacity = theme == .light ? 1 : 0
        layer.borderWidth = focused
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        layer.borderColor = focused
            ? NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.72).cgColor
            : theme.palette.border.cgColor
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        updateAppearance()
    }

    func setFocusVisible(_ visible: Bool) {
        isFocusVisible = visible
        updateAppearance()
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        title = actionItem.title(language: language)
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(title)
    }
}

@MainActor
final class ThinkingBubbleViewController: NSViewController {
    private let label = NSTextField(labelWithString: "Yum.")
    private var theme = AppTheme.dark

    override func loadView() {
        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.28).cgColor
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityLabel(AppText.localized("YumYum Agent가 응답을 생각하는 중"))
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        view = background
        applyTheme(theme)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = NSWorkspace.shared
            .accessibilityDisplayShouldReduceTransparency
            ? theme.palette.surface.withAlphaComponent(1).cgColor
            : theme.palette.surface.cgColor
        view.layer?.borderColor = theme.palette.text
            .withAlphaComponent(theme == .light ? 0.14 : 0.28).cgColor
        view.layer?.shadowColor = theme.palette.shadow.cgColor
        view.layer?.shadowOpacity = theme == .light ? 1 : 0
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        label.textColor = theme.palette.text
    }

    func setThought(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        view.setAccessibilityLabel(AppText.localized(
            english: "YumYum Agent is thinking about the response",
            korean: "YumYum Agent가 응답을 생각하는 중",
            language: language
        ))
    }
}

@MainActor
final class ResponseBubbleViewController: NSViewController, NSTextFieldDelegate {
    private static let panelWidth: CGFloat = 360
    private static let bodyWidth: CGFloat = 312
    private static let minBodyHeight: CGFloat = 44
    private static let maxPanelHeight: CGFloat = 310
    private static let surfaceInset: CGFloat = 8
    private static let bodyInsets: CGFloat = 28
    private static let actionHeight: CGFloat = 36
    private static let composerHeight: CGFloat = 50
    private static let stackSpacing: CGFloat = 8

    var onOpenChat: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDraftChanged: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onRequestInput: (() -> Void)?
    var onPreferredSizeChanged: (() -> Void)?

    private let label = NSTextField(wrappingLabelWithString: "")
    private let responseScroll = NSScrollView()
    private let inlineToggleButton = ResponseActionButton(title: AppText.localized("채팅 입력하기"))
    private let openChatButton = ResponseActionButton(title: AppText.localized("채팅창 상세"))
    private let retryButton = NSButton(title: AppText.localized("재시도"), target: nil, action: nil)
    private let retryRow = NSStackView()
    private let composer = NSTextField()
    private let sendButton = NSButton(title: AppText.localized("전송"), target: nil, action: nil)
    private let attachmentLabel = NSTextField(labelWithString: "")
    private let inlineStack = NSStackView()
    private let bodySurface = ResponseSurfaceView(identifier: "response-body-surface")
    private let inlineActionSurface = ResponseSurfaceView(identifier: "response-inline-action-surface")
    private let composerSurface = ResponseSurfaceView(identifier: "response-inline-composer-surface")
    private let detailActionSurface = ResponseSurfaceView(identifier: "response-detail-action-surface")
    private var responseHeightConstraint: NSLayoutConstraint?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var surfaceStack: NSStackView?
    private var isInlineExpanded = false
    private var content = PetResponseContent(
        fullText: "",
        displayText: "",
        isExcerpt: false,
        showsOpenChat: false
    )
    private var chatState = ChatBubbleState()
    private var theme = AppTheme.dark
    private var language = AppText.language

    var preferredSize: CGSize {
        CGSize(
            width: Self.panelWidth,
            height: preferredPanelHeight
        )
    }

    private var renderedText: NSAttributedString {
        AssistantMarkdownRenderer.render(
            content.displayText(language: language),
            font: .systemFont(ofSize: 13.5),
            textColor: content.isError ? theme.palette.error : theme.palette.text
        )
    }

    private var measuredTextHeight: CGFloat {
        ceil(renderedText.boundingRect(
            with: CGSize(width: Self.bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 2
    }

    private var composerSurfaceHeight: CGFloat {
        guard isInlineExpanded else { return 0 }
        let attachmentHeight = attachmentLabel.isHidden
            ? 0
            : ceil(attachmentLabel.intrinsicContentSize.height) + inlineStack.spacing
        return Self.composerHeight + attachmentHeight
    }

    private var chromeHeight: CGFloat {
        let fixed = Self.actionHeight * 2 + Self.stackSpacing * 2
        return isInlineExpanded
            ? fixed + composerSurfaceHeight + Self.stackSpacing
            : fixed
    }

    private var retryHeight: CGFloat {
        content.showsRetry ? Self.actionHeight : 0
    }

    private var preferredPanelHeight: CGFloat {
        min(
            Self.maxPanelHeight,
            max(
                Self.minBodyHeight + Self.bodyInsets + chromeHeight + retryHeight
                    + Self.surfaceInset * 2,
                measuredTextHeight + Self.bodyInsets + chromeHeight + retryHeight
                    + Self.surfaceInset * 2
            )
        )
    }

    private var visibleTextHeight: CGFloat {
        max(
            Self.minBodyHeight,
            preferredPanelHeight - Self.bodyInsets - chromeHeight - retryHeight
                - Self.surfaceInset * 2
        )
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        bodySurface.content.onClick = { [weak self] in self?.onOpenChat?() }
        bodySurface.setAccessibilityElement(true)
        bodySurface.setAccessibilityRole(.group)
        bodySurface.setAccessibilityHelp(AppText.localized("누르면 전체 채팅을 엽니다."))

        label.font = .systemFont(ofSize: 13.5)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        let document = ResponseDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(label)
        responseScroll.documentView = document
        responseScroll.hasVerticalScroller = true
        responseScroll.autohidesScrollers = true
        responseScroll.drawsBackground = false
        responseScroll.borderType = .noBorder
        responseScroll.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(openChatPressed))
        )
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: responseScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: responseScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: responseScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: responseScroll.contentView.widthAnchor),
            label.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            label.topAnchor.constraint(equalTo: document.topAnchor),
            label.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        openChatButton.target = self
        openChatButton.action = #selector(openChatPressed)
        openChatButton.setAccessibilityLabel(AppText.localized("전체 답변을 채팅에서 열기"))
        inlineToggleButton.target = self
        inlineToggleButton.action = #selector(toggleInline)
        inlineToggleButton.setAccessibilityLabel(AppText.localized("응답 말풍선에서 채팅 입력하기"))
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityLabel(AppText.localized("마지막 입력 재시도"))

        composer.placeholderString = AppText.localized("메시지 입력")
        composer.delegate = self
        composer.target = self
        composer.action = #selector(sendPressed)
        composer.setAccessibilityLabel(AppText.localized("인라인 채팅 메시지"))
        composer.setAccessibilityHelp(AppText.localized("Return을 눌러 전송합니다"))
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.setAccessibilityLabel(AppText.localized("인라인 메시지 전송"))
        attachmentLabel.font = .systemFont(ofSize: 11)
        attachmentLabel.textColor = .secondaryLabelColor
        attachmentLabel.lineBreakMode = .byTruncatingMiddle
        attachmentLabel.setAccessibilityLabel(AppText.localized("전송 예정 첨부"))
        let composerRow = NSStackView(views: [composer, sendButton])
        composerRow.orientation = .horizontal
        composerRow.spacing = 8
        inlineStack.setViews([attachmentLabel, composerRow], in: .top)
        inlineStack.orientation = .vertical
        inlineStack.spacing = 5

        retryRow.setViews([NSView(), retryButton], in: .leading)
        retryRow.orientation = .horizontal
        retryRow.heightAnchor.constraint(equalToConstant: Self.actionHeight).isActive = true
        let bodyStack = NSStackView(views: [responseScroll, retryRow])
        bodyStack.orientation = .vertical
        bodyStack.spacing = 0
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodySurface.content.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: bodySurface.content.leadingAnchor, constant: 16),
            bodyStack.trailingAnchor.constraint(equalTo: bodySurface.content.trailingAnchor, constant: -16),
            bodyStack.topAnchor.constraint(equalTo: bodySurface.content.topAnchor, constant: 14),
            bodyStack.bottomAnchor.constraint(equalTo: bodySurface.content.bottomAnchor, constant: -14),
            responseScroll.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
            retryRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
        ])
        inlineActionSurface.content.addSubview(inlineToggleButton)
        composerSurface.content.addSubview(inlineStack)
        detailActionSurface.content.addSubview(openChatButton)
        for (child, surface) in [
            (inlineToggleButton, inlineActionSurface),
            (inlineStack, composerSurface),
            (openChatButton, detailActionSurface),
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 10),
                child.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -10),
                child.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 4),
                child.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -4),
            ])
        }

        let stack = NSStackView(views: [
            bodySurface,
            composerSurface,
            inlineActionSurface,
            detailActionSurface,
        ])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = Self.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.surfaceInset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.surfaceInset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.surfaceInset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.surfaceInset),
            bodySurface.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inlineActionSurface.widthAnchor.constraint(equalToConstant: 164),
            composerSurface.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailActionSurface.widthAnchor.constraint(equalToConstant: 164),
            inlineActionSurface.heightAnchor.constraint(equalToConstant: Self.actionHeight),
            detailActionSurface.heightAnchor.constraint(equalToConstant: Self.actionHeight),
            composer.heightAnchor.constraint(equalToConstant: 28),
        ])
        let composerHeight = composerSurface.heightAnchor.constraint(
            equalToConstant: composerSurfaceHeight
        )
        composerHeight.isActive = true
        composerHeightConstraint = composerHeight
        surfaceStack = stack
        let height = responseScroll.heightAnchor.constraint(equalToConstant: visibleTextHeight)
        height.isActive = true
        responseHeightConstraint = height
        view = root
        render(content)
        applyTheme(theme)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        let scrollOrigin = responseScroll.contentView.bounds.origin
        view.appearance = theme.appearance
        let opaqueSurface = theme == .light
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        view.layer?.backgroundColor = NSColor.clear.cgColor
        for surface in [bodySurface, composerSurface] {
            surface.applyTheme(theme, color: theme.palette.surface, opaque: opaqueSurface)
        }
        inlineActionSurface.applyTheme(
            theme,
            color: theme.palette.primaryAction,
            opaque: true
        )
        detailActionSurface.applyTheme(
            theme,
            color: theme.palette.secondaryAction,
            opaque: true
        )
        inlineToggleButton.contentTintColor = .white
        openChatButton.contentTintColor = theme == .light ? theme.palette.text : .white
        attachmentLabel.textColor = theme.palette.secondaryText
        render(content, resetScroll: false)
        responseScroll.contentView.scroll(to: scrollOrigin)
        responseScroll.reflectScrolledClipView(responseScroll.contentView)
    }

    func render(_ content: PetResponseContent, resetScroll: Bool = true) {
        self.content = content
        guard isViewLoaded else { return }
        label.attributedStringValue = renderedText
        openChatButton.isHidden = false
        retryButton.isHidden = !content.showsRetry
        retryRow.isHidden = !content.showsRetry
        inlineToggleButton.isHidden = false
        composerSurface.isHidden = !isInlineExpanded
        updateLayout()
        responseScroll.hasVerticalScroller = measuredTextHeight > visibleTextHeight
        if resetScroll {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.responseScroll.contentView.scroll(to: .zero)
                self.responseScroll.reflectScrolledClipView(self.responseScroll.contentView)
            }
        }
        bodySurface.setAccessibilityRole(
            content.showsOpenChat || content.showsRetry ? .group : .button
        )
        bodySurface.setAccessibilityLabel(
            content.isExcerpt
                ? AppText.localized("YumYum Agent 답변 요약. 채팅에서 전체 답변을 열 수 있습니다.", language: language)
                : AppText.localized("YumYum Agent 답변", language: language)
        )
        bodySurface.setAccessibilityValue(content.displayText(language: language))
    }

    @objc private func openChatPressed() { onOpenChat?() }
    @objc private func retryPressed() { onRetry?() }

    func renderChat(_ state: ChatBubbleState) {
        chatState = state
        guard isViewLoaded else { return }
        if composer.stringValue != state.draftText {
            composer.stringValue = state.draftText
        }
        let attachments = state.draftAttachments
        attachmentLabel.stringValue = attachments.isEmpty
            ? ""
            : AppText.localized(
                english: "\(attachments.first?.displayName ?? "") · \(attachments.count) attached",
                korean: "\(attachments.first?.displayName ?? "") · \(attachments.count)개 첨부",
                language: language
            )
        attachmentLabel.isHidden = attachments.isEmpty
        let hasDraft = !state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
        composer.isEnabled = !state.isSending
        sendButton.isEnabled = hasDraft && !state.isSending
        updateLayout()
    }

    func fitPanelHeight(_ height: CGFloat) {
        composerHeightConstraint?.constant = composerSurfaceHeight
        let surfaceCount: CGFloat = isInlineExpanded ? 4 : 3
        let gapCount = surfaceCount - 1
        let fixedHeight = Self.surfaceInset * 2 + Self.bodyInsets + retryHeight
            + Self.actionHeight * 2 + composerSurfaceHeight
        let spacing = min(Self.stackSpacing, max(0, (height - fixedHeight) / gapCount))
        surfaceStack?.spacing = spacing
        responseHeightConstraint?.constant = max(
            0,
            height - fixedHeight - spacing * gapCount
        )
        view.layoutSubtreeIfNeeded()
    }

    func resetActionInteractionState() {
        inlineToggleButton.resetInteractionState()
        openChatButton.resetInteractionState()
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        self.language = language
        inlineToggleButton.title = AppText.localized(english: "Reply", korean: "채팅 입력하기", language: language)
        openChatButton.title = AppText.localized(english: "Open Chat", korean: "채팅창 상세", language: language)
        retryButton.title = AppText.localized(english: "Retry", korean: "재시도", language: language)
        sendButton.title = AppText.localized(english: "Send", korean: "전송", language: language)
        composer.placeholderString = AppText.localized(english: "Message", korean: "메시지 입력", language: language)
        bodySurface.setAccessibilityHelp(AppText.localized("누르면 전체 채팅을 엽니다.", language: language))
        openChatButton.setAccessibilityLabel(AppText.localized("전체 답변을 채팅에서 열기", language: language))
        inlineToggleButton.setAccessibilityLabel(AppText.localized("응답 말풍선에서 채팅 입력하기", language: language))
        retryButton.setAccessibilityLabel(AppText.localized("마지막 입력 재시도", language: language))
        composer.setAccessibilityLabel(AppText.localized("인라인 채팅 메시지", language: language))
        composer.setAccessibilityHelp(AppText.localized("Return을 눌러 전송합니다", language: language))
        sendButton.setAccessibilityLabel(AppText.localized("인라인 메시지 전송", language: language))
        attachmentLabel.setAccessibilityLabel(AppText.localized("전송 예정 첨부", language: language))
        let scrollOrigin = responseScroll.contentView.bounds.origin
        render(content, resetScroll: false)
        renderChat(chatState)
        responseScroll.contentView.scroll(to: scrollOrigin)
        responseScroll.reflectScrolledClipView(responseScroll.contentView)
    }

    var responseScrollOrigin: CGPoint {
        responseScroll.contentView.bounds.origin
    }

    func restoreResponseScrollOrigin(_ origin: CGPoint) {
        responseScroll.contentView.scroll(to: origin)
        responseScroll.reflectScrolledClipView(responseScroll.contentView)
    }

    private func updateLayout() {
        composerHeightConstraint?.constant = composerSurfaceHeight
        surfaceStack?.spacing = Self.stackSpacing
        responseHeightConstraint?.constant = visibleTextHeight
        view.layoutSubtreeIfNeeded()
    }

#if DEBUG
    var responseScrollOriginForTesting: CGPoint {
        get { responseScroll.contentView.bounds.origin }
        set {
            responseScroll.contentView.scroll(to: newValue)
            responseScroll.reflectScrolledClipView(responseScroll.contentView)
        }
    }
#endif

    func controlTextDidChange(_ notification: Notification) {
        onDraftChanged?(composer.stringValue)
    }

    func beginInlineCompose() {
        guard isInlineExpanded else {
            toggleInline()
            return
        }
        onRequestInput?()
        view.window?.makeFirstResponder(composer)
    }

    @objc
    private func toggleInline() {
        if isInlineExpanded {
            view.window?.makeFirstResponder(inlineToggleButton)
        }
        isInlineExpanded.toggle()
        inlineToggleButton.state = isInlineExpanded ? .on : .off
        composerSurface.isHidden = !isInlineExpanded
        updateLayout()
        onPreferredSizeChanged?()
        if isInlineExpanded {
            onRequestInput?()
            view.window?.makeFirstResponder(composer)
        }
    }

    @objc
    private func sendPressed() {
        onDraftChanged?(composer.stringValue)
        guard sendButton.isEnabled else { return }
        onSend?()
    }
}

private final class ResponseDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ResponseActionButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .semibold)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
        super.mouseDown(with: event)
        isPressed = false
        updateAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateAppearance()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        updateAppearance()
        return accepted
    }

    func resetInteractionState() {
        isHovered = false
        isPressed = false
        updateAppearance()
    }

    private func updateAppearance() {
        alphaValue = isEnabled ? 1 : 0.42
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        layer?.backgroundColor = NSColor.white.withAlphaComponent(
            isPressed ? 0.22 : (isHovered || focused ? 0.13 : 0)
        ).cgColor
        layer?.borderWidth = focused ? 1 : 0
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor
            .withAlphaComponent(0.72).cgColor
    }
}

@MainActor
private final class ResponseSurfaceView: NSView {
    let content = ClickableGlassView()

    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        wantsLayer = true
        layer?.masksToBounds = false
        content.translatesAutoresizingMaskIntoConstraints = false
        installGlassBackground(in: content, cornerRadius: 14)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ theme: AppTheme, color: NSColor, opaque: Bool) {
        content.layer?.backgroundColor = opaque ? color.cgColor : NSColor.clear.cgColor
        content.layer?.borderWidth = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        content.layer?.borderColor = theme.palette.border.cgColor
        setGlassBackgroundsHidden(opaque, in: content)
        layer?.shadowColor = theme.palette.shadow.cgColor
        layer?.shadowOpacity = theme == .light ? 1 : 0
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
}

private final class ClickableGlassView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate {
            if view is NSButton || view is NSScrollView {
                return hit
            }
            candidate = view.superview
        }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

private final class FeedPreviewContentView: NSView {
    init(preview: FeedPreview) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        if preview.sourceRect != nil,
           let url = preview.fileURLs.first,
           let image = NSImage(contentsOf: url) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 10
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            imageView.layer?.borderWidth = 0.5
            imageView.layer?.borderColor = NSColor.white
                .withAlphaComponent(0.5).cgColor
            fill(with: imageView)
        } else if !preview.fileURLs.isEmpty {
            fill(with: OverlappingFileIconsView(urls: preview.fileURLs))
        } else {
            let label = NSTextField(labelWithString: preview.label)
            label.alignment = .center
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.lineBreakMode = .byTruncatingMiddle
            label.wantsLayer = true
            label.layer?.cornerRadius = 12
            label.layer?.cornerCurve = .continuous
            label.layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.92).cgColor
            fill(with: label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(AppText.localized(
            english: "Material being fed to YumYum Agent: \(preview.label)",
            korean: "YumYum Agent에게 먹이는 자료: \(preview.label)"
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func fill(with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class OverlappingFileIconsView: NSView {
    private var tiles: [NSImageView] = []
    private var countBadge: NSTextField?

    init(urls: [URL]) {
        super.init(frame: .zero)
        wantsLayer = true
        let shown = Array(urls.prefix(4))
        for url in shown {
            let tile = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            tile.imageScaling = .scaleProportionallyDown
            tile.wantsLayer = true
            tile.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.94).cgColor
            tile.layer?.cornerRadius = 9
            tile.layer?.cornerCurve = .continuous
            tile.layer?.borderWidth = 0.5
            tile.layer?.borderColor = NSColor.separatorColor.cgColor
            addSubview(tile)
            tiles.append(tile)
        }
        if urls.count > shown.count {
            let badge = NSTextField(labelWithString: "+\(urls.count - shown.count)")
            badge.alignment = .center
            badge.font = .systemFont(ofSize: 10, weight: .bold)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            badge.layer?.cornerRadius = 9
            addSubview(badge)
            countBadge = badge
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        let baseWidth = 54 + CGFloat(tiles.count - 1) * 16
        let scale = min(bounds.width / baseWidth, bounds.height / 54)
        let contentWidth = baseWidth * scale
        let originX = (bounds.width - contentWidth) / 2
        let originY = (bounds.height - 54 * scale) / 2
        for (index, tile) in tiles.enumerated() {
            tile.frame = CGRect(
                x: originX + CGFloat(index) * 16 * scale,
                y: originY,
                width: 54 * scale,
                height: 54 * scale
            )
            tile.layer?.cornerRadius = 9 * scale
        }
        countBadge?.frame = CGRect(
            x: originX + CGFloat(tiles.count - 1) * 16 * scale + 38 * scale,
            y: originY,
            width: 20 * scale,
            height: 18 * scale
        )
        countBadge?.font = .systemFont(ofSize: max(1, 10 * scale), weight: .bold)
        countBadge?.layer?.cornerRadius = 9 * scale
    }
}

@MainActor
private func makeGlassBackground(cornerRadius: CGFloat) -> NSView {
    let view = NSView()
    installGlassBackground(in: view, cornerRadius: cornerRadius)
    return view
}

@MainActor
private func installGlassBackground(
    in container: NSView,
    cornerRadius: CGFloat
) {
    let background: NSView
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.04)
        background = glass
    } else {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.035).cgColor
        background = effect
    }
    background.identifier = NSUserInterfaceItemIdentifier("YumYumGlassBackground")
    background.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(background)
    NSLayoutConstraint.activate([
        background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        background.topAnchor.constraint(equalTo: container.topAnchor),
        background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    container.wantsLayer = true
    container.layer?.cornerRadius = cornerRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    container.layer?.borderWidth = 0.5
    container.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
}

@MainActor
private func setGlassBackgroundsHidden(_ hidden: Bool, in view: NSView) {
    for subview in view.subviews {
        if subview.identifier?.rawValue == "YumYumGlassBackground" {
            subview.isHidden = hidden
        }
        setGlassBackgroundsHidden(hidden, in: subview)
    }
}
