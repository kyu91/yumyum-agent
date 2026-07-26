import AppKit
import Combine
import UniformTypeIdentifiers
import YumYumCore

@MainActor
enum AssistantMarkdownRenderer {
    static func render(
        _ source: String,
        font: NSFont,
        textColor: NSColor,
        isStreaming: Bool = false
    ) -> NSAttributedString {
        let renderedSource = isStreaming ? streamingSource(source) : source
        let fallback = NSAttributedString(
            string: renderedSource,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
            ]
        )

        do {
            let markdown = try AttributedString(
                markdown: renderedSource,
                options: .init(interpretedSyntax: .full)
            )
            let rendered = NSMutableAttributedString()
            var previousBlock: MarkdownBlock?
            for run in markdown.runs {
                let block = markdownBlock(for: run.presentationIntent)
                if previousBlock?.identity != block.identity {
                    if let previousBlock {
                        appendSeparator(
                            to: rendered,
                            between: previousBlock,
                            and: block,
                            font: font,
                            textColor: textColor
                        )
                    }
                    if !block.prefix.isEmpty {
                        rendered.append(
                            NSAttributedString(
                                string: block.prefix,
                                attributes: [
                                    .font: blockFont(base: font, block: block),
                                    .foregroundColor: textColor,
                                ]
                            )
                        )
                    }
                    previousBlock = block
                }
                let intent = run.inlinePresentationIntent
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: renderedFont(
                        base: blockFont(base: font, block: block),
                        intent: intent
                    ),
                    .foregroundColor: textColor,
                ]
                if intent?.contains(.strikethrough) == true {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                rendered.append(
                    NSAttributedString(
                        string: String(markdown[run.range].characters),
                        attributes: attributes
                    )
                )
            }
            return rendered.length == 0 && !renderedSource.isEmpty ? fallback : rendered
        } catch {
            return fallback
        }
    }

    private static func streamingSource(_ source: String) -> String {
        let characters = Array(source)
        var hidden: Set<Int> = []

        let asterisks = characters.indices.filter { characters[$0] == "*" }
        if !asterisks.count.isMultiple(of: 4) {
            hidden.formUnion(asterisks)
        }

        let lineStart = (characters.lastIndex(of: "\n") ?? -1) + 1
        var headingEnd = lineStart
        while headingEnd < characters.count,
              headingEnd - lineStart < 6,
              characters[headingEnd] == "#" {
            headingEnd += 1
        }
        if headingEnd > lineStart,
           characters[headingEnd...].allSatisfy(\.isWhitespace) {
            hidden.formUnion(lineStart..<characters.count)
        }

        var backtickRuns: [Int: [Range<Int>]] = [:]
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index] == "`" {
                index += 1
            }
            let run = start..<index
            if run.count < 3 {
                backtickRuns[run.count, default: []].append(run)
            }
        }
        for runs in backtickRuns.values where !runs.count.isMultiple(of: 2) {
            hidden.formUnion(runs.last ?? 0..<0)
        }

        return String(
            characters.enumerated().compactMap { offset, character in
                hidden.contains(offset) ? nil : character
            }
        )
    }

    private struct MarkdownBlock {
        enum Kind {
            case paragraph
            case heading(Int)
            case unorderedItem
            case orderedItem(Int)
            case quote
            case code
        }

        let identity: Int?
        let kind: Kind
        let listDepth: Int

        var isListItem: Bool {
            switch kind {
            case .unorderedItem, .orderedItem:
                true
            default:
                false
            }
        }

        var prefix: String {
            let indentation = String(repeating: "  ", count: max(0, listDepth - 1))
            return switch kind {
            case .unorderedItem:
                indentation + "- "
            case let .orderedItem(ordinal):
                indentation + "\(ordinal). "
            case .quote:
                "> "
            default:
                ""
            }
        }
    }

    private static func markdownBlock(
        for intent: PresentationIntent?
    ) -> MarkdownBlock {
        guard let intent, let leaf = intent.components.first else {
            return MarkdownBlock(identity: nil, kind: .paragraph, listDepth: 0)
        }
        var kind: MarkdownBlock.Kind = .paragraph
        var listOrdinal: Int?
        var nearestListIsUnordered: Bool?
        var listDepth = 0
        for component in intent.components {
            switch component.kind {
            case let .header(level):
                kind = .heading(level)
            case let .listItem(ordinal):
                listOrdinal = ordinal
            case .unorderedList:
                if nearestListIsUnordered == nil {
                    nearestListIsUnordered = true
                }
                listDepth += 1
            case .orderedList:
                if nearestListIsUnordered == nil {
                    nearestListIsUnordered = false
                }
                listDepth += 1
            case .blockQuote:
                kind = .quote
            case .codeBlock:
                kind = .code
            default:
                break
            }
        }
        if let listOrdinal {
            kind = nearestListIsUnordered == true
                ? .unorderedItem
                : .orderedItem(listOrdinal)
        }
        return MarkdownBlock(
            identity: leaf.identity,
            kind: kind,
            listDepth: listDepth
        )
    }

    private static func blockFont(base: NSFont, block: MarkdownBlock) -> NSFont {
        switch block.kind {
        case let .heading(level):
            let increment = max(1, 6 - CGFloat(level) * 1.25)
            return .systemFont(ofSize: base.pointSize + increment, weight: .bold)
        case .code:
            return .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        default:
            return base
        }
    }

    private static func appendSeparator(
        to rendered: NSMutableAttributedString,
        between previous: MarkdownBlock,
        and next: MarkdownBlock,
        font: NSFont,
        textColor: NSColor
    ) {
        let desiredCount = previous.isListItem && next.isListItem ? 1 : 2
        let existingCount = rendered.string.reversed().prefix { $0 == "\n" }.count
        guard existingCount < desiredCount else { return }
        rendered.append(
            NSAttributedString(
                string: String(repeating: "\n", count: desiredCount - existingCount),
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                ]
            )
        )
    }

    private static func renderedFont(
        base: NSFont,
        intent: InlinePresentationIntent?
    ) -> NSFont {
        let isBold = intent?.contains(.stronglyEmphasized) == true
        let isItalic = intent?.contains(.emphasized) == true
        var rendered = intent?.contains(.code) == true
            ? NSFont.monospacedSystemFont(
                ofSize: base.pointSize,
                weight: isBold ? .semibold : .regular
            )
            : base
        var traits: NSFontTraitMask = []
        if isBold && intent?.contains(.code) != true {
            traits.insert(.boldFontMask)
        }
        if isItalic {
            traits.insert(.italicFontMask)
        }
        if !traits.isEmpty {
            rendered = NSFontManager.shared.convert(rendered, toHaveTrait: traits)
        }
        return rendered
    }
}

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
final class ChatPanelController: NSObject {
    static let panelSize = CGSize(width: 400, height: 520)

    private let petController: FloatingPetWindowController
    private weak var viewModel: YumYumAppViewModel?
    private let layout = QuickMenuLayout()
    private let viewController = QuickMenuViewController()
    private let captureCoordinator = ScreenCaptureCoordinator()
    private let session: ChatBubbleSession
    private var stateObservation: AnyCancellable?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration: UUID?
    private var captureRestoration = (panel: false, pet: false)
    private var fileSelectionGate = CallbackGenerationGate()
    private var activeFilePanel: NSOpenPanel?
    private var agentNotice: String?

    var onWillBeginCapture: (() -> Void)?
    var onExplicitCancel: (() -> Void)?

    let panel: QuickMenuPanel

    var isVisible: Bool { panel.isVisible }
    var isCapturing: Bool { captureTask != nil }

    init(
        petController: FloatingPetWindowController,
        viewModel: YumYumAppViewModel,
        workflow: FeedWorkflow
    ) {
        self.petController = petController
        self.viewModel = viewModel
        session = ChatBubbleSession(submitter: workflow)
        panel = QuickMenuPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "YumYum 대화"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
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
        viewController.onDraftChanged = { [weak self] text in
            self?.session.setDraftText(text)
        }
        viewController.onSend = { [weak self] in self?.sendDraft() }
        viewController.onCancelSend = { [weak self] in self?.cancelSend() }
        viewController.onRetry = { [weak self] in self?.retrySend() }
        viewController.onRemoveAttachment = { [weak self] id in
            self?.session.removeAttachment(id: id)
        }

        stateObservation = session.$state.sink { [weak self] state in
            guard let self else { return }
            self.viewController.render(
                state: state,
                canRetry: self.session.canRetry,
                agentNotice: self.agentNotice
            )
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
        guard captureTask == nil else { return }
        updateFrame()
        session.show()
        panel.makeKeyAndOrderFront(nil)
        viewController.focusComposer()
    }

    func hide(restorePetAfterCapture: Bool = true) {
        cancelFileSelection()
        cancelCapture(
            restorePanel: false,
            restorePet: restorePetAfterCapture
        )
        session.hide()
        panel.orderOut(nil)
    }

    func prepareForTermination() {
        cancelFileSelection()
        cancelCapture(restorePanel: false, restorePet: false)
        session.discardDraftAndCancel()
        petController.setMouthOpen(false)
        panel.orderOut(nil)
        petController.hide()
    }

    func showCheckingStatus() {}

    var isSending: Bool { session.state.isSending }

    @discardableResult
    func feedAttachments(
        _ attachments: [ChatDraftAttachment],
        reduceMotion: Bool
    ) -> Bool {
        let didStart = session.feedAttachments(
            attachments,
            reduceMotion: reduceMotion
        )
        if didStart {
            refreshAgentStateAfterFailure()
        }
        return didStart
    }

    func retryLastSend() {
        retrySend()
    }

    func scrollToLatest() {
        viewController.scrollToLatest()
    }

    func update(snapshot: AgentRegistrySnapshot) {
        if snapshot.canSend {
            agentNotice = nil
        } else if snapshot.requiresExplicitReselection {
            agentNotice = "설정에서 기본 에이전트를 다시 선택하세요."
        } else {
            agentNotice = "설정에서 기본 에이전트를 선택하세요."
        }
        viewController.render(
            state: session.state,
            canRetry: session.canRetry,
            agentNotice: agentNotice
        )
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

    private func captureScreen() {
        cancelFileSelection()
        guard captureTask == nil, session.beginCapture() else {
            return
        }
        let generation = UUID()
        captureGeneration = generation
        let restorePet = petController.isVisible
        captureRestoration = (false, restorePet)
        onWillBeginCapture?()
        panel.orderOut(nil)
        petController.hide()
        CATransaction.flush()

        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            defer {
                self.finishCapture(generation: generation)
            }
            do {
                let result = try await captureCoordinator.capture()
                guard !Task.isCancelled,
                      self.captureGeneration == generation,
                      self.session.state.phase == .capturing else {
                    try? FileManager.default.removeItem(at: result.url)
                    throw CancellationError()
                }
                session.finishCapture(
                    .attachment(
                        ChatDraftAttachment(
                            url: result.url,
                            isTemporary: true,
                            sourceRect: result.selectedRegion
                        )
                    )
                )
            } catch is CancellationError {
                session.finishCapture(.cancelled)
            } catch let error as ScreenCaptureCoordinatorError {
                switch error {
                case .permissionDenied:
                    session.finishCapture(.permissionDenied)
                default:
                    session.finishCapture(
                        .failed(error.errorDescription ?? "화면을 캡처하지 못했습니다.")
                    )
                }
            } catch {
                session.finishCapture(.failed("화면을 캡처하지 못했습니다."))
            }
        }
    }

    private func cancelCapture(restorePanel: Bool, restorePet: Bool) {
        guard captureGeneration != nil else { return }
        let restoration = captureRestoration
        captureRestoration = (false, false)
        captureCoordinator.cancel()
        captureTask?.cancel()
        session.finishCapture(.cancelled)
        if restorePet, restoration.pet {
            petController.show()
        }
        if restorePanel, restoration.panel {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func finishCapture(generation: UUID) {
        guard captureGeneration == generation else { return }
        let restoration = captureRestoration
        captureGeneration = nil
        captureRestoration = (false, false)
        captureTask = nil
        if restoration.pet {
            petController.show()
        }
    }

    private func chooseFiles() {
        guard !session.state.isSending, activeFilePanel == nil else {
            return
        }
        let generation = UUID()
        guard fileSelectionGate.begin(generation) else { return }
        let openPanel = NSOpenPanel()
        activeFilePanel = openPanel
        openPanel.title = "대화에 첨부할 파일 선택"
        openPanel.prompt = "첨부"
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = false
        openPanel.allowedContentTypes = [.image, .pdf, .plainText, .sourceCode]
        openPanel.begin { [weak self, weak openPanel] response in
            Task { @MainActor in
                guard let self,
                      self.fileSelectionGate.consume(generation) else {
                    return
                }
                self.activeFilePanel = nil
                guard response == .OK, let urls = openPanel?.urls else { return }
                for url in urls {
                    self.session.addAttachment(
                        ChatDraftAttachment(url: url, isTemporary: false)
                    )
                }
                self.viewController.focusComposer()
            }
        }
    }

    private func cancelFileSelection() {
        fileSelectionGate.invalidate()
        let panel = activeFilePanel
        activeFilePanel = nil
        panel?.cancel(nil)
    }

    private func sendDraft() {
        guard session.send(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) else { return }
        refreshAgentStateAfterFailure()
    }

    private func retrySend() {
        guard session.retry(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) else { return }
        refreshAgentStateAfterFailure()
    }

    private func cancelSend() {
        session.cancelSend()
        onExplicitCancel?()
        petController.setMouthOpen(false)
    }

    private func refreshAgentStateAfterFailure() {
        Task { @MainActor [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            await self.session.waitForCurrentSend()
            guard case .failed = self.session.state.phase else { return }
            await viewModel.refreshAgents(trigger: .manualRescan)
            self.update(snapshot: viewModel.agentSnapshot)
        }
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
    private static let autoScrollThreshold: CGFloat = 24

    var onClose: (() -> Void)?
    var onCapture: (() -> Void)?
    var onChooseFiles: (() -> Void)?
    var onDraftChanged: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onCancelSend: (() -> Void)?
    var onRetry: (() -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?

    private let transcriptStack = NSStackView()
    private let transcriptScroll = NSScrollView()
    private let attachmentStack = NSStackView()
    private let attachmentScroll = NSScrollView()
    private let captureButton = NSButton(title: "캡처", target: nil, action: nil)
    private let fileButton = NSButton(title: "파일", target: nil, action: nil)
    private let composer = NSTextField()
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "대화를 입력하거나 자료를 첨부하세요.")
    private let retryButton = NSButton(title: "재시도", target: nil, action: nil)
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    private var lastAnnouncedStatus = ""
    private var renderedMessages: [ChatMessage] = []

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        view = background

        let title = NSTextField(labelWithString: "YumYum")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: "닫기"
            )!,
            target: self,
            action: #selector(closePressed)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("대화 말풍선 닫기")
        let header = NSStackView(views: [title, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY

        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.setAccessibilityElement(true)
        transcriptStack.setAccessibilityRole(.list)
        transcriptStack.setAccessibilityLabel("대화 내용")

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(transcriptStack)
        transcriptScroll.documentView = document
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: transcriptScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),
            transcriptStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcriptStack.topAnchor.constraint(equalTo: document.topAnchor),
            transcriptStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        attachmentStack.orientation = .horizontal
        attachmentStack.alignment = .centerY
        attachmentStack.spacing = 6
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentStack.setAccessibilityElement(true)
        attachmentStack.setAccessibilityRole(.list)
        attachmentStack.setAccessibilityLabel("초안 첨부 파일")
        let attachmentDocument = NSView()
        attachmentDocument.translatesAutoresizingMaskIntoConstraints = false
        attachmentDocument.addSubview(attachmentStack)
        attachmentScroll.documentView = attachmentDocument
        attachmentScroll.hasHorizontalScroller = true
        attachmentScroll.hasVerticalScroller = false
        attachmentScroll.autohidesScrollers = true
        attachmentScroll.drawsBackground = false
        attachmentScroll.borderType = .noBorder
        NSLayoutConstraint.activate([
            attachmentDocument.leadingAnchor.constraint(equalTo: attachmentScroll.contentView.leadingAnchor),
            attachmentDocument.topAnchor.constraint(equalTo: attachmentScroll.contentView.topAnchor),
            attachmentDocument.heightAnchor.constraint(equalTo: attachmentScroll.contentView.heightAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: attachmentDocument.leadingAnchor),
            attachmentStack.trailingAnchor.constraint(equalTo: attachmentDocument.trailingAnchor),
            attachmentStack.topAnchor.constraint(equalTo: attachmentDocument.topAnchor),
            attachmentStack.bottomAnchor.constraint(equalTo: attachmentDocument.bottomAnchor),
        ])

        captureButton.target = self
        captureButton.action = #selector(capturePressed)
        captureButton.image = NSImage(
            systemSymbolName: "rectangle.dashed",
            accessibilityDescription: nil
        )
        captureButton.imagePosition = .imageLeading
        captureButton.setAccessibilityLabel("화면 영역 캡처 첨부")
        captureButton.setAccessibilityHelp("드래그한 화면 영역을 전송하지 않고 초안에 첨부합니다")

        fileButton.target = self
        fileButton.action = #selector(filePressed)
        fileButton.image = NSImage(
            systemSymbolName: "paperclip",
            accessibilityDescription: nil
        )
        fileButton.imagePosition = .imageLeading
        fileButton.setAccessibilityLabel("파일 첨부")
        fileButton.setAccessibilityHelp("선택한 파일을 전송하지 않고 초안에 첨부합니다")

        let inputButtons = NSStackView(views: [captureButton, fileButton, NSView()])
        inputButtons.orientation = .horizontal
        inputButtons.spacing = 8

        composer.placeholderString = "메시지 입력"
        composer.delegate = self
        composer.target = self
        composer.action = #selector(sendPressed)
        composer.setAccessibilityLabel("대화 메시지")
        composer.setAccessibilityHelp("Return을 눌러 전송합니다")

        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded
        sendButton.setAccessibilityLabel("메시지 보내기")
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let composerRow = NSStackView(views: [composer, sendButton])
        composerRow.orientation = .horizontal
        composerRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityLabel("YumYum 상태")

        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.setAccessibilityLabel("마지막 메시지 재시도")
        retryButton.isHidden = true

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.setAccessibilityLabel("응답 생성 취소")
        cancelButton.isHidden = true

        let statusRow = NSStackView(views: [statusLabel, retryButton, cancelButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let stack = NSStackView(views: [
            header,
            transcriptScroll,
            attachmentScroll,
            inputButtons,
            composerRow,
            statusRow,
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
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            transcriptScroll.heightAnchor.constraint(equalToConstant: 292),
            attachmentScroll.heightAnchor.constraint(equalToConstant: 34),
            composer.heightAnchor.constraint(equalToConstant: 32),
            captureButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            fileButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])

        render(state: ChatBubbleState(), canRetry: false, agentNotice: nil)
    }

    func render(
        state: ChatBubbleState,
        canRetry: Bool,
        agentNotice: String?
    ) {
        guard isViewLoaded else { return }
        if composer.stringValue != state.draftText {
            composer.stringValue = state.draftText
        }
        let streamingAssistantID = state.isSending
            ? state.messages.last(where: { $0.role == .assistant })?.id
            : nil
        renderTranscript(
            state.messages,
            streamingAssistantID: streamingAssistantID
        )
        rebuildAttachments(state.draftAttachments)

        let isBusy: Bool
        let status: String
        let isError: Bool
        switch state.phase {
        case .idle:
            isBusy = false
            status = agentNotice ?? "대화를 입력하거나 자료를 첨부하세요."
            isError = agentNotice != nil
        case .capturing:
            isBusy = true
            status = "드래그하여 캡처할 영역을 선택하세요."
            isError = false
        case .sending:
            isBusy = true
            status = "응답을 기다리는 중…"
            isError = false
        case .cancelled:
            isBusy = false
            status = "전송을 취소했습니다."
            isError = false
        case let .failed(message):
            isBusy = false
            status = UserFacingErrorRedactor.sanitize(message)
            isError = true
        }

        captureButton.isEnabled = !isBusy
        fileButton.isEnabled = !isBusy
        composer.isEnabled = !isBusy
        let hasDraft = !state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !state.draftAttachments.isEmpty
        sendButton.isEnabled = !isBusy && hasDraft
        retryButton.isHidden = !(canRetry && !isBusy)
        cancelButton.isHidden = !state.isSending
        setStatus(status, isError: isError)
    }

    func focusComposer() {
        guard composer.isEnabled else { return }
        view.window?.makeFirstResponder(composer)
    }

    func scrollToLatest() {
        guard let document = transcriptScroll.documentView else { return }
        transcriptScroll.contentView.scroll(
            to: CGPoint(
                x: 0,
                y: max(0, document.bounds.height - transcriptScroll.contentSize.height)
            )
        )
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    func controlTextDidChange(_ notification: Notification) {
        onDraftChanged?(composer.stringValue)
    }

    private func renderTranscript(
        _ messages: [ChatMessage],
        streamingAssistantID: UUID?
    ) {
        let shouldAutoScroll = isNearTranscriptBottom
        if canUpdateStreamingAssistant(with: messages),
           let message = messages.last,
           let row = transcriptStack.arrangedSubviews.last as? ChatMessageRowView {
            row.render(message, isStreaming: message.id == streamingAssistantID)
            renderedMessages = messages
            finishTranscriptUpdate(autoScroll: shouldAutoScroll)
            return
        }

        rebuildTranscript(
            messages,
            streamingAssistantID: streamingAssistantID
        )
        renderedMessages = messages
        finishTranscriptUpdate(autoScroll: shouldAutoScroll)
    }

    private func canUpdateStreamingAssistant(with messages: [ChatMessage]) -> Bool {
        guard messages.count == renderedMessages.count,
              messages.last?.role == .assistant else {
            return false
        }
        return messages.map(\.id) == renderedMessages.map(\.id)
    }

    private var isNearTranscriptBottom: Bool {
        guard let document = transcriptScroll.documentView else { return true }
        let distance = document.bounds.maxY
            - transcriptScroll.contentView.bounds.maxY
        return distance <= Self.autoScrollThreshold
    }

    private func finishTranscriptUpdate(autoScroll: Bool) {
        view.layoutSubtreeIfNeeded()
        guard autoScroll else { return }
        let origin = transcriptScroll.contentView.bounds.origin
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.transcriptScroll.contentView.bounds.origin == origin else {
                return
            }
            self.scrollToLatest()
        }
    }

    private func rebuildTranscript(
        _ messages: [ChatMessage],
        streamingAssistantID: UUID?
    ) {
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if messages.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: "캡처나 파일을 첨부하고 메시지를 보내면 대화가 여기에 쌓입니다."
            )
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.maximumNumberOfLines = 3
            empty.setAccessibilityLabel("아직 대화가 없습니다")
            transcriptStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor, constant: -8).isActive = true
        } else {
            for message in messages {
                let row = ChatMessageRowView(
                    message: message,
                    isStreaming: message.id == streamingAssistantID
                )
                transcriptStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor, constant: -8).isActive = true
            }
        }
    }

    private func rebuildAttachments(_ attachments: [ChatDraftAttachment]) {
        attachmentStack.arrangedSubviews.forEach {
            attachmentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        attachmentScroll.isHidden = attachments.isEmpty
        for attachment in attachments {
            let icon = NSImageView(
                image: NSWorkspace.shared.icon(forFile: attachment.url.path)
            )
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
            ])
            let label = NSTextField(labelWithString: attachment.displayName)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            let remove = NSButton(
                image: NSImage(
                    systemSymbolName: "xmark",
                    accessibilityDescription: "첨부 제거"
                )!,
                target: self,
                action: #selector(removeAttachmentPressed(_:))
            )
            remove.isBordered = false
            remove.identifier = NSUserInterfaceItemIdentifier(attachment.id.uuidString)
            remove.setAccessibilityLabel("\(attachment.displayName) 첨부 제거")
            let row = NSStackView(views: [icon, label, NSView(), remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            row.layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.7).cgColor
            row.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 5)
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.group)
            row.setAccessibilityLabel("첨부 파일 \(attachment.displayName)")
            attachmentStack.addArrangedSubview(row)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.setAccessibilityValue(text)
        guard lastAnnouncedStatus != text else { return }
        lastAnnouncedStatus = text
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    @objc private func closePressed() { onClose?() }
    @objc private func capturePressed() { onCapture?() }
    @objc private func filePressed() { onChooseFiles?() }

    @objc
    private func sendPressed() {
        onDraftChanged?(composer.stringValue)
        onSend?()
    }

    @objc private func cancelPressed() { onCancelSend?() }
    @objc private func retryPressed() { onRetry?() }

    @objc
    private func removeAttachmentPressed(_ sender: NSButton) {
        guard let rawID = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawID) else {
            return
        }
        onRemoveAttachment?(id)
    }
}

@MainActor
private final class ChatMessageRowView: NSStackView {
    private let bubble = NSView()
    private let spacer = NSView()
    private var messageContent: NSView?

    init(message: ChatMessage, isStreaming: Bool) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 13
        bubble.layer?.backgroundColor = (
            message.role == .user
                ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.86)
        ).cgColor
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        if message.role == .user {
            addArrangedSubview(spacer)
            addArrangedSubview(bubble)
        } else {
            addArrangedSubview(bubble)
            addArrangedSubview(spacer)
        }
        render(message, isStreaming: isStreaming)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ message: ChatMessage, isStreaming: Bool) {
        messageContent?.removeFromSuperview()

        let content: NSView
        if message.isLoading {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            let label = NSTextField(labelWithString: "응답을 기다리는 중…")
            label.font = .systemFont(ofSize: 13)
            let loading = NSStackView(views: [progress, label])
            loading.orientation = .horizontal
            loading.alignment = .centerY
            loading.spacing = 7
            content = loading
        } else {
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.maximumNumberOfLines = 0
            label.isSelectable = true
            if message.role == .assistant {
                label.attributedStringValue = AssistantMarkdownRenderer.render(
                    message.visibleText,
                    font: .systemFont(ofSize: 13),
                    textColor: .labelColor,
                    isStreaming: isStreaming
                )
            } else {
                label.stringValue = message.visibleText
            }
            content = label
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
        messageContent = content

        let role = message.role == .user ? "사용자" : "어시스턴트"
        let value = message.isLoading ? "응답을 기다리는 중" : message.visibleText
        setAccessibilityLabel("\(role): \(value)")
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class AppFeedFeedback: FeedFeedback, @unchecked Sendable {
    private weak var petController: FloatingPetWindowController?
    weak var quickMenuController: QuickMenuPanelController?
    private var statusGate = FeedStatusGenerationGate()

    init(petController: FloatingPetWindowController) {
        self.petController = petController
    }

    func setMouthPresentation(_ presentation: FeedMouthPresentation) async {
        switch presentation {
        case .resting:
            petController?.resetChewPresentation()
        case .open:
            petController?.applyChewFrame(.mouthOpen)
        case .reducedMotion:
            petController?.applyChewFrame(.reducedMotion)
        }
    }

    func animate(_ preview: FeedPreview, reduceMotion: Bool) async {
        await quickMenuController?.animatePreview(preview, reduceMotion: reduceMotion)
    }

    func setStatus(_ update: FeedStatusUpdate) async {
        guard statusGate.apply(update) else { return }
        quickMenuController?.applyFeedStatus(update)
    }
}
