import AppKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import YumYumCore

enum GlobalShortcutChoice: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case commandShiftSpace
    case controlOptionReturn

    static let defaultsKey = "YumYum.GlobalShortcut"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .commandShiftSpace: "⇧⌘Space"
        case .controlOptionReturn: "⌃⌥Return"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .controlOptionSpace, .commandShiftSpace: 49
        case .controlOptionReturn: 36
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .controlOptionSpace, .controlOptionReturn: [.control, .option]
        case .commandShiftSpace: [.command, .shift]
        }
    }

    static func load(defaults: UserDefaults = .standard) -> GlobalShortcutChoice {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:))
            ?? .controlOptionSpace
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

@MainActor
final class GlobalShortcutController {
    private var choice: GlobalShortcutChoice
    private let action: @MainActor () -> Void
    private var globalMonitor: EventMonitorToken?
    private var localMonitor: EventMonitorToken?

    init(choice: GlobalShortcutChoice, action: @escaping @MainActor () -> Void) {
        self.choice = choice
        self.action = action
        installMonitors()
    }

    func update(choice: GlobalShortcutChoice) {
        self.choice = choice
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            Task { @MainActor in
                guard let self, self.matches(event) else { return }
                self.action()
            }
        }.map(EventMonitorToken.init)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.matches(event) else { return event }
            self.action()
            return nil
        }.map(EventMonitorToken.init)
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard !event.isARepeat, event.keyCode == choice.keyCode else {
            return false
        }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            == choice.modifiers
    }
}

private final class EventMonitorToken: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    deinit {
        NSEvent.removeMonitor(value)
    }
}

@MainActor
final class QuickMenuPanelController: NSObject {
    static let panelSize = CGSize(width: 360, height: 276)

    private let petController: FloatingPetWindowController
    private weak var viewModel: YumYumAppViewModel?
    private let workflow: FeedWorkflow
    private let layout = QuickMenuLayout()
    private let viewController = QuickMenuViewController()
    private let captureCoordinator = ScreenCaptureCoordinator()
    private var animationPanel: NSPanel?

    let panel: QuickMenuPanel

    var isVisible: Bool { panel.isVisible }

    init(
        petController: FloatingPetWindowController,
        viewModel: YumYumAppViewModel,
        workflow: FeedWorkflow
    ) {
        self.petController = petController
        self.viewModel = viewModel
        self.workflow = workflow
        panel = QuickMenuPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "YumYum 빠른 메뉴"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
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
        panel.contentViewController = viewController
        panel.onCancel = { [weak self] in self?.hide() }

        viewController.onClose = { [weak self] in self?.hide() }
        viewController.onCapture = { [weak self] in self?.captureScreen() }
        viewController.onChooseFiles = { [weak self] in self?.chooseFiles() }
        viewController.onSendText = { [weak self] text in
            self?.submit(FeedInput(text: text))
        }
        viewController.onSelectAgent = { [weak self] installation in
            self?.selectAgent(installation)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        updateFrame()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func showCheckingStatus() {
        viewController.setStatus("에이전트 상태 확인 중…", isError: false)
        viewController.setBusy(true)
    }

    func update(snapshot: AgentRegistrySnapshot) {
        viewController.update(snapshot: snapshot)
    }

    func updateStatus(_ status: FeedStatus) {
        switch status {
        case .idle:
            viewController.setStatus("입력을 선택하세요.", isError: false)
            viewController.setBusy(false)
        case .validating:
            viewController.setStatus("입력을 확인하는 중…", isError: false)
            viewController.setBusy(true)
        case let .animating(label):
            viewController.setStatus("\(label)을 먹는 중…", isError: false)
        case .sending:
            viewController.setStatus("선택한 에이전트에 보내는 중…", isError: false)
        case let .completed(text):
            viewController.setStatus(text, isError: false)
            viewController.setBusy(false)
            viewController.clearText()
        case let .failed(message):
            viewController.setStatus(message, isError: true)
            viewController.setBusy(false)
        }
    }

    func animatePreview(_ preview: FeedPreview, reduceMotion: Bool) async {
        let sourceFrame = CGRect(
            x: panel.frame.midX - 70,
            y: panel.frame.midY - 16,
            width: 140,
            height: 32
        )
        let targetFrame = petController.mouthTargetFrame
        let chip = makeAnimationPanel(label: preview.label, frame: sourceFrame)
        animationPanel?.orderOut(nil)
        animationPanel = chip
        chip.orderFrontRegardless()

        if reduceMotion {
            try? await Task.sleep(for: .milliseconds(180))
        } else {
            await withCheckedContinuation { continuation in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    chip.animator().setFrame(targetFrame, display: true)
                    chip.animator().alphaValue = 0.15
                } completionHandler: {
                    continuation.resume()
                }
            }
        }
        chip.orderOut(nil)
        if animationPanel === chip {
            animationPanel = nil
        }
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        if panel.isVisible {
            updateFrame()
        }
    }

    private func updateFrame() {
        panel.setFrame(
            layout.panelFrame(
                petFrame: petController.panel.frame,
                panelSize: Self.panelSize,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
    }

    private func selectAgent(_ installation: AgentInstallation) {
        guard let path = installation.path,
              let viewModel else {
            return
        }
        Task { @MainActor [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            do {
                try await viewModel.selectAgent(installation.definitionID, path: path)
                self.update(snapshot: viewModel.agentSnapshot)
            } catch {
                self.viewController.setStatus(
                    (error as? LocalizedError)?.errorDescription ?? "에이전트를 선택하지 못했습니다.",
                    isError: true
                )
            }
        }
    }

    private func captureScreen() {
        guard viewModel?.canSendPrompt == true else {
            viewController.setStatus("기본 에이전트를 먼저 선택하세요.", isError: true)
            return
        }
        viewController.setStatus("캡처할 화면이나 창을 선택하세요.", isError: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let imageURL = try await captureCoordinator.capture()
                submit(
                    FeedInput(
                        fileURLs: [imageURL],
                        temporaryFileURLs: [imageURL]
                    )
                )
            } catch is CancellationError {
                viewController.setStatus("화면 캡처를 취소했습니다.", isError: false)
            } catch {
                viewController.setStatus(
                    "화면 캡처 권한 또는 선택 상태를 확인하세요: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
    }

    private func chooseFiles() {
        guard viewModel?.canSendPrompt == true else {
            viewController.setStatus("기본 에이전트를 먼저 선택하세요.", isError: true)
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.title = "YumYum에 먹일 파일 선택"
        openPanel.prompt = "선택"
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = false
        openPanel.allowedContentTypes = [.image, .pdf, .plainText, .sourceCode]
        openPanel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK else {
                    self.viewController.setStatus("파일 선택을 취소했습니다.", isError: false)
                    return
                }
                self.submit(
                    FeedInput(
                        text: self.viewController.currentText,
                        fileURLs: openPanel.urls
                    )
                )
            }
        }
    }

    private func submit(_ input: FeedInput) {
        guard viewModel?.canSendPrompt == true else {
            for url in input.temporaryFileURLs {
                try? FileManager.default.removeItem(at: url)
            }
            viewController.setStatus("기본 에이전트를 먼저 선택하세요.", isError: true)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { [weak self, workflow] in
            do {
                _ = try await workflow.submit(input, reduceMotion: reduceMotion)
            } catch is CancellationError {
                await MainActor.run {
                    self?.viewController.setStatus("입력 처리를 취소했습니다.", isError: false)
                }
            } catch {
                if let viewModel = await MainActor.run(body: { self?.viewModel }) {
                    await viewModel.refreshAgents(trigger: .manualRescan)
                }
                await MainActor.run {
                    if let self, let viewModel = self.viewModel {
                        self.update(snapshot: viewModel.agentSnapshot)
                    }
                    self?.viewController.setStatus(
                        (error as? LocalizedError)?.errorDescription ?? "입력을 보내지 못했습니다.",
                        isError: true
                    )
                }
            }
        }
    }

    private func makeAnimationPanel(label: String, frame: CGRect) -> NSPanel {
        let chip = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        chip.isOpaque = false
        chip.backgroundColor = .clear
        chip.hasShadow = true
        chip.level = .popUpMenu
        chip.ignoresMouseEvents = true
        chip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .center
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.wantsLayer = true
        labelField.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.96).cgColor
        labelField.layer?.cornerRadius = 12
        chip.contentView = labelField
        return chip
    }
}

final class QuickMenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class QuickMenuViewController: NSViewController, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onCapture: (() -> Void)?
    var onChooseFiles: (() -> Void)?
    var onSendText: ((String) -> Void)?
    var onSelectAgent: ((AgentInstallation) -> Void)?

    private let agentPopup = NSPopUpButton()
    private let captureButton = NSButton(title: "화면 캡처", target: nil, action: nil)
    private let fileButton = NSButton(title: "파일 선택", target: nil, action: nil)
    private let textField = NSTextField()
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "입력을 선택하세요.")
    private var installationByID: [String: AgentInstallation] = [:]
    private var hasAvailableSelection = false
    private var isBusy = false

    var currentText: String { textField.stringValue }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        view = background

        let title = NSTextField(labelWithString: "YumYum에 먹이기")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "닫기")!,
            target: self,
            action: #selector(closePressed)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("빠른 메뉴 닫기")

        let header = NSStackView(views: [title, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY

        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        agentPopup.setAccessibilityLabel("기본 에이전트")
        agentPopup.setAccessibilityHelp("검증된 로컬 에이전트 중 기본 전송 대상을 선택합니다")

        captureButton.target = self
        captureButton.action = #selector(capturePressed)
        captureButton.image = NSImage(systemSymbolName: "rectangle.dashed.badge.record", accessibilityDescription: nil)
        captureButton.imagePosition = .imageLeading
        captureButton.setAccessibilityHelp("ScreenCaptureKit 선택기를 엽니다")

        fileButton.target = self
        fileButton.action = #selector(filePressed)
        fileButton.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        fileButton.imagePosition = .imageLeading
        fileButton.setAccessibilityHelp("이미지, PDF, 텍스트 또는 소스 파일을 여러 개 선택합니다")

        let actions = NSStackView(views: [captureButton, fileButton])
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8

        textField.placeholderString = "에이전트에게 바로 물어보기"
        textField.delegate = self
        textField.target = self
        textField.action = #selector(sendPressed)
        textField.setAccessibilityLabel("대화 내용")
        textField.setAccessibilityHelp("Return을 눌러 선택한 에이전트에 보냅니다")

        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded
        sendButton.setAccessibilityLabel("대화 보내기")

        let conversation = NSStackView(views: [textField, sendButton])
        conversation.orientation = .horizontal
        conversation.spacing = 8
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityLabel("YumYum 상태")

        let shortcutHint = NSTextField(labelWithString: "⌃⌥Space로 어디서든 열기")
        shortcutHint.font = .systemFont(ofSize: 11)
        shortcutHint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            header,
            agentPopup,
            actions,
            conversation,
            statusLabel,
            shortcutHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        for arrangedView in stack.arrangedSubviews {
            arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -14),
            textField.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    func update(snapshot: AgentRegistrySnapshot) {
        installationByID.removeAll()
        agentPopup.removeAllItems()
        for installation in snapshot.installations {
            let detail: String
            switch installation.availability {
            case .available:
                detail = installation.version.map { " · \($0)" } ?? ""
            case .unavailable:
                detail = " · 사용 불가"
            }
            agentPopup.addItem(withTitle: "\(installation.definitionID.displayName)\(detail)")
            guard let item = agentPopup.lastItem else { continue }
            item.representedObject = installation.id
            item.isEnabled = installation.availability == .available
            installationByID[installation.id] = installation
            if snapshot.selectedInstallation?.id == installation.id {
                agentPopup.select(item)
            }
        }
        let actionState = QuickMenuActionState(snapshot: snapshot, isBusy: false)
        hasAvailableSelection = actionState.isInputEnabled
        setBusy(false)
        setStatus(actionState.statusText, isError: snapshot.requiresExplicitReselection)
    }

    func setBusy(_ isBusy: Bool) {
        self.isBusy = isBusy
        let enabled = hasAvailableSelection && !isBusy
        captureButton.isEnabled = enabled
        fileButton.isEnabled = enabled
        textField.isEnabled = enabled
        sendButton.isEnabled = enabled
        agentPopup.isEnabled = !isBusy
    }

    func setStatus(_ text: String, isError: Bool) {
        let didChange = statusLabel.stringValue != text
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.setAccessibilityValue(text)
        if didChange {
            NSAccessibility.post(
                element: statusLabel,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    func clearText() {
        textField.stringValue = ""
    }

    @objc private func closePressed() { onClose?() }
    @objc private func capturePressed() { onCapture?() }
    @objc private func filePressed() { onChooseFiles?() }
    @objc private func sendPressed() { onSendText?(textField.stringValue) }

    @objc
    private func agentChanged() {
        guard let id = agentPopup.selectedItem?.representedObject as? String,
              let installation = installationByID[id] else {
            return
        }
        onSelectAgent?(installation)
    }
}

@MainActor
final class AppFeedFeedback: FeedFeedback, @unchecked Sendable {
    private weak var petController: FloatingPetWindowController?
    weak var quickMenuController: QuickMenuPanelController?

    init(petController: FloatingPetWindowController) {
        self.petController = petController
    }

    func setMouthOpen(_ isOpen: Bool) async {
        petController?.setMouthOpen(isOpen)
    }

    func animate(_ preview: FeedPreview, reduceMotion: Bool) async {
        await quickMenuController?.animatePreview(preview, reduceMotion: reduceMotion)
    }

    func setStatus(_ status: FeedStatus) async {
        quickMenuController?.updateStatus(status)
    }
}

enum ScreenCaptureCoordinatorError: LocalizedError {
    case alreadyPresenting
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyPresenting: "이미 화면 캡처 선택기를 표시하고 있습니다."
        case .encodingFailed: "선택한 화면을 PNG로 저장하지 못했습니다."
        }
    }
}

@MainActor
final class ScreenCaptureCoordinator: NSObject, @preconcurrency SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<URL, any Error>?

    func capture() async throws -> URL {
        guard continuation == nil else {
            throw ScreenCaptureCoordinatorError.alreadyPresenting
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = SCContentSharingPicker.shared
            picker.add(self)
            picker.isActive = true
            picker.present()
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            do {
                let configuration = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                configuration.width = max(1, Int(filter.contentRect.width * scale))
                configuration.height = max(1, Int(filter.contentRect.height * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                let representation = NSBitmapImageRep(cgImage: image)
                guard let data = representation.representation(using: .png, properties: [:]) else {
                    throw ScreenCaptureCoordinatorError.encodingFailed
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "\(CaptureTemporaryFileCleanup.filenamePrefix)\(UUID().uuidString).png"
                    )
                try data.write(to: url, options: .atomic)
                finish(.success(url), picker: picker)
            } catch {
                finish(.failure(error), picker: picker)
            }
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        finish(.failure(CancellationError()), picker: picker)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(.failure(error), picker: .shared)
    }

    private func finish(
        _ result: Result<URL, any Error>,
        picker: SCContentSharingPicker
    ) {
        picker.remove(self)
        picker.isActive = false
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
