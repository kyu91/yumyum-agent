import AppKit
import QuartzCore
import UniformTypeIdentifiers
import YumYumCore

@MainActor
final class QuickMenuPanelController: NSObject {
    static let actionPanelSize = CGSize(width: 248, height: 200)
    static let thinkingPanelSize = CGSize(width: 112, height: 48)

    private let petController: FloatingPetWindowController
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
    private var lastReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastActionSourceRect: CGRect?

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
            title: "YumYum 생각 중"
        )
        responsePanel = ResponseBubblePanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 360, height: 120)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        Self.configure(
            actionPanel,
            level: .popUpMenu,
            title: "YumYum 액션"
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
        Self.configure(responsePanel, level: .floating, title: "YumYum 답변")
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
        actionPanel.appearance = theme.appearance
        thinkingPanel.appearance = theme.appearance
        responsePanel.appearance = theme.appearance
        chatController.applyTheme(theme)
        thinkingViewController.applyTheme(theme)
        responseViewController.applyTheme(theme)
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
        canFeed = snapshot.canSend
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

    var chatPanelForTesting: QuickMenuPanel {
        chatController.panel
    }
#endif

    private func select(_ action: ActionBubbleAction) {
        guard action != .capture && action != .findFile
                || canFeed && !isCheckingAgents && !chatController.isSending else {
            return
        }
        perform(flow.select(action, generation: UUID()))
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
                        .failed(error.errorDescription ?? "화면을 캡처하지 못했습니다."),
                        generation: generation
                    )
                }
            } catch {
                finishCapture(
                    .failed("화면을 캡처하지 못했습니다."),
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
        openPanel.title = "먹일 파일 선택"
        openPanel.prompt = "먹이기"
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
        let panel = Self.makeBubblePanel(size: frame.size, title: "YumYum 먹이 미리보기")
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
        actionPanel.setFrame(
            layout.panelFrame(
                petFrame: petController.panel.frame,
                panelSize: Self.actionPanelSize,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
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
        let size = responseViewController.preferredSize
        responsePanel.setFrame(
            layout.panelFrame(
                petFrame: petController.panel.frame,
                panelSize: size,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
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
        panel.ignoresMouseEvents = title == "YumYum 생각 중"
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
    }

    override func orderOut(_ sender: Any?) {
        acceptsKeyInput = false
        super.orderOut(sender)
    }
}

@MainActor
private final class ActionBubbleViewController: NSViewController {
    var onAction: ((ActionBubbleAction) -> Void)?

    private var buttons: [ActionRowButton] = []
    private var feedActionsEnabled = false

    override func loadView() {
        let background = makeGlassBackground(cornerRadius: 18)
        view = background

        buttons = ActionBubbleAction.allCases.map { action in
            let button = ActionRowButton(action: action)
            button.target = self
            button.action = #selector(actionPressed(_:))
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.list)
        stack.setAccessibilityLabel("YumYum 액션")
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
        for index in buttons.indices {
            buttons[index].nextKeyView = buttons[(index + 1) % buttons.count]
        }
        applyEnabledState()
    }

    func setFeedActionsEnabled(_ enabled: Bool) {
        feedActionsEnabled = enabled
        if isViewLoaded {
            applyEnabledState()
        }
    }

    func focusFirstRow() {
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

    @objc
    private func actionPressed(_ sender: ActionRowButton) {
        onAction?(sender.actionItem)
    }
}

private final class ActionRowButton: NSButton {
    let actionItem: ActionBubbleAction

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

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
        alignment = .left
        font = .systemFont(ofSize: 14, weight: .medium)
        isBordered = false
        focusRingType = .none
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(action.title)
        setAccessibilityRole(.button)
        updateAppearance()
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

    private func updateAppearance() {
        guard let layer else { return }
        alphaValue = isEnabled ? 1 : 0.42
        let focused = window?.firstResponder === self
        if isPressed {
            layer.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.22).cgColor
        } else if isHovered || focused {
            layer.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.13).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
        layer.borderWidth = focused ? 1 : 0
        layer.borderColor = NSColor.keyboardFocusIndicatorColor
            .withAlphaComponent(0.72).cgColor
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
        background.setAccessibilityLabel("YumYum이 응답을 생각하는 중")
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
        view.layer?.backgroundColor = theme.palette.surface.cgColor
        view.layer?.borderColor = theme.palette.text
            .withAlphaComponent(0.28).cgColor
        label.textColor = theme.palette.text
    }

    func setThought(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
    }
}

@MainActor
final class ResponseBubbleViewController: NSViewController, NSTextFieldDelegate {
    private static let panelWidth: CGFloat = 360
    private static let bodyWidth: CGFloat = 328
    private static let minPanelHeight: CGFloat = 72
    private static let maxPanelHeight: CGFloat = 310
    private static let verticalInsets: CGFloat = 28
    private static let buttonRowHeight: CGFloat = 25
    private static let stackSpacing: CGFloat = 9

    var onOpenChat: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDraftChanged: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onRequestInput: (() -> Void)?
    var onPreferredSizeChanged: (() -> Void)?

    private let label = NSTextField(wrappingLabelWithString: "")
    private let responseScroll = NSScrollView()
    private let inlineToggleButton = NSButton(title: "채팅 입력하기", target: nil, action: nil)
    private let openChatButton = NSButton(title: "채팅창 상세", target: nil, action: nil)
    private let retryButton = NSButton(title: "재시도", target: nil, action: nil)
    private let buttonRow = NSStackView()
    private let composer = NSTextField()
    private let sendButton = NSButton(title: "전송", target: nil, action: nil)
    private let attachmentLabel = NSTextField(labelWithString: "")
    private let inlineStack = NSStackView()
    private var responseHeightConstraint: NSLayoutConstraint?
    private var isInlineExpanded = false
    private var content = PetResponseContent(
        fullText: "",
        displayText: "",
        isExcerpt: false,
        showsOpenChat: false
    )
    private var theme = AppTheme.dark

    var preferredSize: CGSize {
        CGSize(
            width: Self.panelWidth,
            height: preferredPanelHeight
        )
    }

    private var renderedText: NSAttributedString {
        AssistantMarkdownRenderer.render(
            content.displayText,
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

    private var buttonChromeHeight: CGFloat {
        let rows = Self.buttonRowHeight * 2
        guard isInlineExpanded else {
            return rows + Self.stackSpacing
        }
        let attachmentHeight = attachmentLabel.isHidden
            ? 0
            : ceil(attachmentLabel.intrinsicContentSize.height) + inlineStack.spacing
        return rows + 28 + attachmentHeight + Self.stackSpacing * 3
    }

    private var preferredPanelHeight: CGFloat {
        min(
            Self.maxPanelHeight,
            max(
                Self.minPanelHeight,
                measuredTextHeight + Self.verticalInsets + buttonChromeHeight
            )
        )
    }

    private var visibleTextHeight: CGFloat {
        preferredPanelHeight - Self.verticalInsets - buttonChromeHeight
    }

    override func loadView() {
        let background = ClickableGlassView()
        installGlassBackground(in: background, cornerRadius: 18)
        background.onClick = { [weak self] in self?.onOpenChat?() }
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityHelp("누르면 전체 채팅을 엽니다.")

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
        openChatButton.bezelStyle = .rounded
        openChatButton.setAccessibilityLabel("전체 답변을 채팅에서 열기")
        inlineToggleButton.target = self
        inlineToggleButton.action = #selector(toggleInline)
        inlineToggleButton.bezelStyle = .rounded
        inlineToggleButton.setAccessibilityLabel("응답 말풍선에서 채팅 입력하기")
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityLabel("마지막 입력 재시도")

        buttonRow.setViews([NSView(), retryButton, inlineToggleButton], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.heightAnchor.constraint(equalToConstant: Self.buttonRowHeight).isActive = true
        composer.placeholderString = "메시지 입력"
        composer.delegate = self
        composer.target = self
        composer.action = #selector(sendPressed)
        composer.setAccessibilityLabel("인라인 채팅 메시지")
        composer.setAccessibilityHelp("Return을 눌러 전송합니다")
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.setAccessibilityLabel("인라인 메시지 전송")
        attachmentLabel.font = .systemFont(ofSize: 11)
        attachmentLabel.textColor = .secondaryLabelColor
        attachmentLabel.lineBreakMode = .byTruncatingMiddle
        attachmentLabel.setAccessibilityLabel("전송 예정 첨부")
        let composerRow = NSStackView(views: [composer, sendButton])
        composerRow.orientation = .horizontal
        composerRow.spacing = 8
        inlineStack.setViews([attachmentLabel, composerRow], in: .top)
        inlineStack.orientation = .vertical
        inlineStack.spacing = 5
        let detailRow = NSStackView(views: [NSView(), openChatButton])
        detailRow.orientation = .horizontal
        let stack = NSStackView(views: [responseScroll, buttonRow, inlineStack, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        for arrangedView in stack.arrangedSubviews {
            arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            composer.heightAnchor.constraint(equalToConstant: 28),
            detailRow.heightAnchor.constraint(equalToConstant: Self.buttonRowHeight),
        ])
        let height = responseScroll.heightAnchor.constraint(equalToConstant: visibleTextHeight)
        height.isActive = true
        responseHeightConstraint = height
        view = background
        render(content)
        applyTheme(theme)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        view.appearance = theme.appearance
        render(content, resetScroll: false)
    }

    func render(_ content: PetResponseContent, resetScroll: Bool = true) {
        self.content = content
        guard isViewLoaded else { return }
        label.attributedStringValue = renderedText
        openChatButton.isHidden = false
        retryButton.isHidden = !content.showsRetry
        inlineToggleButton.isHidden = false
        buttonRow.isHidden = false
        inlineStack.isHidden = !isInlineExpanded
        responseHeightConstraint?.constant = visibleTextHeight
        responseScroll.hasVerticalScroller = measuredTextHeight > visibleTextHeight
        if resetScroll {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.responseScroll.contentView.scroll(to: .zero)
                self.responseScroll.reflectScrolledClipView(self.responseScroll.contentView)
            }
        }
        view.setAccessibilityRole(
            content.showsOpenChat || content.showsRetry ? .group : .button
        )
        view.setAccessibilityLabel(
            content.isExcerpt
                ? "YumYum 답변 요약. 채팅에서 전체 답변을 열 수 있습니다."
                : "YumYum 답변"
        )
        view.setAccessibilityValue(content.displayText)
    }

    @objc private func openChatPressed() { onOpenChat?() }
    @objc private func retryPressed() { onRetry?() }

    func renderChat(_ state: ChatBubbleState) {
        guard isViewLoaded else { return }
        if composer.stringValue != state.draftText {
            composer.stringValue = state.draftText
        }
        let attachments = state.draftAttachments
        attachmentLabel.stringValue = attachments.isEmpty
            ? ""
            : "\(attachments.first?.displayName ?? "") · \(attachments.count)개 첨부"
        attachmentLabel.isHidden = attachments.isEmpty
        let hasDraft = !state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
        composer.isEnabled = !state.isSending
        sendButton.isEnabled = hasDraft && !state.isSending
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

    @objc
    private func toggleInline() {
        isInlineExpanded.toggle()
        inlineToggleButton.state = isInlineExpanded ? .on : .off
        inlineStack.isHidden = !isInlineExpanded
        responseHeightConstraint?.constant = visibleTextHeight
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
        setAccessibilityLabel("YumYum에게 먹이는 자료: \(preview.label)")
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
