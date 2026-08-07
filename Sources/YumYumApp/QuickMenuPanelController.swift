import AppKit
import Combine
import SwiftUI
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

enum AppTheme: String, CaseIterable, Identifiable {
    static let defaultsKey = "YumYum.appTheme"

    case light
    case dark

    var id: String { rawValue }
    var displayName: String {
        self == .light
            ? AppText.localized(english: "Light", korean: "라이트")
            : AppText.localized(english: "Dark", korean: "다크")
    }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var appearance: NSAppearance? {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)
    }
    var palette: AppThemePalette {
        switch self {
        case .light:
            AppThemePalette(
                surface: NSColor(calibratedWhite: 1, alpha: 1),
                secondarySurface: NSColor(calibratedWhite: 0.97, alpha: 1),
                text: NSColor(calibratedWhite: 0.10, alpha: 0.94),
                secondaryText: NSColor(calibratedWhite: 0.28, alpha: 1),
                border: NSColor(calibratedWhite: 0, alpha: 0.14),
                shadow: NSColor(calibratedWhite: 0, alpha: 0.16),
                chatCanvas: NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.93, alpha: 1),
                assistantMessage: NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.89, alpha: 1),
                userMessage: NSColor(calibratedRed: 0.94, green: 0.82, blue: 0.75, alpha: 1),
                composerSurface: NSColor(calibratedRed: 1.00, green: 0.995, blue: 0.98, alpha: 1),
                auxiliarySurface: NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.78, alpha: 1),
                chatText: NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.09, alpha: 1),
                chatSecondaryText: NSColor(calibratedRed: 0.34, green: 0.29, blue: 0.25, alpha: 1),
                chatBorder: NSColor(calibratedRed: 0.31, green: 0.24, blue: 0.20, alpha: 0.22),
                chatShadow: NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.12, alpha: 0.18),
                error: NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.16, alpha: 1),
                primaryAction: NSColor(calibratedRed: 0.60, green: 0.20, blue: 0.07, alpha: 1),
                secondaryAction: NSColor(calibratedRed: 0.64, green: 0.52, blue: 0.43, alpha: 1)
            )
        case .dark:
            AppThemePalette(
                surface: NSColor(calibratedWhite: 0.14, alpha: 0.96),
                secondarySurface: NSColor(calibratedWhite: 0.25, alpha: 0.92),
                text: NSColor(calibratedWhite: 1.00, alpha: 0.94),
                secondaryText: NSColor(calibratedWhite: 1.00, alpha: 0.68),
                border: NSColor(calibratedWhite: 1.00, alpha: 0.18),
                shadow: .clear,
                chatCanvas: NSColor(calibratedRed: 0.15, green: 0.13, blue: 0.11, alpha: 1),
                assistantMessage: NSColor(calibratedRed: 0.24, green: 0.21, blue: 0.18, alpha: 1),
                userMessage: NSColor(calibratedRed: 0.38, green: 0.23, blue: 0.17, alpha: 1),
                composerSurface: NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.16, alpha: 1),
                auxiliarySurface: NSColor(calibratedRed: 0.30, green: 0.27, blue: 0.23, alpha: 1),
                chatText: NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.87, alpha: 1),
                chatSecondaryText: NSColor(calibratedRed: 0.78, green: 0.72, blue: 0.65, alpha: 1),
                chatBorder: NSColor(calibratedRed: 0.86, green: 0.76, blue: 0.66, alpha: 0.22),
                chatShadow: .clear,
                error: NSColor(calibratedRed: 1, green: 0.38, blue: 0.42, alpha: 1),
                primaryAction: NSColor(calibratedRed: 0.68, green: 0.24, blue: 0.05, alpha: 1),
                secondaryAction: NSColor(calibratedRed: 0.48, green: 0.35, blue: 0.27, alpha: 1)
            )
        }
    }

    static func load(defaults: UserDefaults = .standard) -> AppTheme {
        AppTheme(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .dark
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct AppThemePalette {
    let surface: NSColor
    let secondarySurface: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let border: NSColor
    let shadow: NSColor
    let chatCanvas: NSColor
    let assistantMessage: NSColor
    let userMessage: NSColor
    let composerSurface: NSColor
    let auxiliarySurface: NSColor
    let chatText: NSColor
    let chatSecondaryText: NSColor
    let chatBorder: NSColor
    let chatShadow: NSColor
    let error: NSColor
    let primaryAction: NSColor
    let secondaryAction: NSColor
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
    enum AgentNotice: Equatable {
        case selectDefault
        case reselectDefault

        func text(language: AppLanguage) -> String {
            switch self {
            case .selectDefault:
                AppText.localized("설정에서 기본 에이전트를 선택하세요.", language: language)
            case .reselectDefault:
                AppText.localized("설정에서 기본 에이전트를 다시 선택하세요.", language: language)
            }
        }
    }

    static let panelSize = CGSize(width: 400, height: 520)

    private let petController: FloatingPetWindowController
    private weak var viewModel: YumYumAppViewModel?
    private let layout = QuickMenuLayout()
    private let viewController = QuickMenuViewController()
    private let captureCoordinator = ScreenCaptureCoordinator()
    private let session: ChatBubbleSession
    private let resetAgentSession: @Sendable () async -> Bool
    private let openSettings: @MainActor () -> Void
    private var stateObservation: AnyCancellable?
    private var restartObservation: AnyCancellable?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration: UUID?
    private var captureRestoration = (panel: false, pet: false)
    private var fileSelectionGate = CallbackGenerationGate()
    private var activeFilePanel: NSOpenPanel?
    private var isWorkflowBusy = false
    private var agentNotice: AgentNotice?
    private(set) var hasPresented = false

    var onWillBeginCapture: (() -> Void)?
    var onExplicitCancel: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onStateChanged: ((ChatBubbleState) -> Void)?

    let panel: QuickMenuPanel

    var isVisible: Bool { panel.isVisible }
    var isCapturing: Bool { captureTask != nil }
    var state: ChatBubbleState { session.state }

    init(
        petController: FloatingPetWindowController,
        viewModel: YumYumAppViewModel,
        workflow: FeedWorkflow,
        resetAgentSession: (@Sendable () async -> Bool)? = nil,
        openSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.petController = petController
        self.viewModel = viewModel
        self.openSettings = openSettings
        self.resetAgentSession = resetAgentSession ?? {
            await workflow.resetSession {
                await viewModel.saveSoulAndResetSession()
            }
        }
        session = ChatBubbleSession(submitter: workflow)
        panel = QuickMenuPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = AppText.localized("YumYum Agent 대화")
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
        viewController.onRestartSession = { [weak self] in self?.restartSession() }
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
                canRestart: self.canRestart,
                isRestarting: self.session.isRestarting,
                agentNotice: self.agentNotice
            )
            self.onStateChanged?(state)
        }
        restartObservation = session.$isRestarting.dropFirst().sink { [weak self] isRestarting in
            self?.renderCurrentState(isRestarting: isRestarting)
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
        viewController.setPresented(true)
        hasPresented = true
        panel.makeKeyAndOrderFront(nil)
        viewController.focusComposer()
        onVisibilityChanged?(true)
    }

    func hide(restorePetAfterCapture: Bool = true) {
        cancelFileSelection()
        cancelCapture(
            restorePanel: false,
            restorePet: restorePetAfterCapture
        )
        session.hide()
        viewController.setPresented(false)
        panel.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func applyTheme(_ theme: AppTheme) {
        panel.appearance = theme.appearance
        viewController.applyTheme(theme)
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        panel.title = AppText.localized(english: "YumYum Agent Chat", korean: "YumYum Agent 대화", language: language)
        viewController.applyLanguage(language)
    }

#if DEBUG
    func renderForTesting(_ state: ChatBubbleState) {
        viewController.render(
            state: state,
            canRetry: session.canRetry,
            canRestart: canRestart,
            isRestarting: session.isRestarting,
            agentNotice: agentNotice
        )
    }

    func addAttachmentForTesting(_ attachment: ChatDraftAttachment) {
        session.addAttachment(attachment)
    }

    func waitForSendForTesting() async {
        await session.waitForCurrentSend()
    }

    func waitForRestartForTesting() async {
        await session.waitForRestart()
    }
#endif

    func prepareForTermination() {
        cancelFileSelection()
        cancelCapture(restorePanel: false, restorePet: false)
        session.discardDraftAndCancel()
        viewController.setPresented(false)
        petController.setMouthOpen(false)
        panel.orderOut(nil)
        petController.hide()
    }

    func showCheckingStatus() {}

    var isSending: Bool { session.state.isSending }

    private var canRestart: Bool {
        session.canRestart && activeFilePanel == nil && !isWorkflowBusy
    }

    func setWorkflowBusy(_ isBusy: Bool) {
        isWorkflowBusy = isBusy
        viewController.setRestartEnabled(canRestart)
    }

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

    @discardableResult
    func feedText(_ text: String, reduceMotion: Bool) -> Bool {
        let didStart = session.feedText(text, reduceMotion: reduceMotion)
        if didStart {
            refreshAgentStateAfterFailure()
        }
        return didStart
    }

    func retryLastSend() {
        retrySend()
    }

    func setDraftText(_ text: String) {
        guard session.state.draftText != text else { return }
        session.setDraftText(text)
    }

    @discardableResult
    func sendDraftFromResponse() -> Bool {
        guard session.send(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) else { return false }
        refreshAgentStateAfterFailure()
        return true
    }

    func scrollToLatest() {
        viewController.scrollToLatest()
    }

    func update(snapshot: AgentRegistrySnapshot) {
        if viewModel?.canSendPrompt == true {
            agentNotice = nil
        } else if snapshot.requiresExplicitReselection {
            agentNotice = .reselectDefault
        } else {
            agentNotice = .selectDefault
        }
        viewController.render(
            state: session.state,
            canRetry: session.canRetry,
            canRestart: canRestart,
            isRestarting: session.isRestarting,
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
                        .failed(error.errorDescription ?? AppText.localized("화면을 캡처하지 못했습니다."))
                    )
                }
            } catch {
                session.finishCapture(.failed(AppText.localized("화면을 캡처하지 못했습니다.")))
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
        guard session.canRestart, activeFilePanel == nil else {
            return
        }
        let generation = UUID()
        guard fileSelectionGate.begin(generation) else { return }
        let openPanel = NSOpenPanel()
        activeFilePanel = openPanel
        renderCurrentState()
        openPanel.title = AppText.localized("대화에 첨부할 파일 선택")
        openPanel.prompt = AppText.localized("첨부")
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
                self.renderCurrentState()
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
        if panel != nil {
            renderCurrentState()
        }
    }

    private func restartSession() {
        guard activeFilePanel == nil else { return }
        session.restartSession(reset: resetAgentSession)
    }

    private func renderCurrentState() {
        renderCurrentState(isRestarting: session.isRestarting)
    }

    private func renderCurrentState(isRestarting: Bool) {
        let canRestart = (session.canRestart || session.isRestarting)
            && activeFilePanel == nil
            && !isWorkflowBusy
            && !isRestarting
        viewController.render(
            state: session.state,
            canRetry: session.canRetry,
            canRestart: canRestart,
            isRestarting: isRestarting,
            agentNotice: agentNotice
        )
    }

    private func sendDraft() {
        guard session.send(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) else { return }
        refreshAgentStateAfterFailure()
    }

    private func retrySend() {
        if case let .failed(message) = session.state.phase,
           UserFacingErrorRedactor.category(forSafeMessage: message) == .codexAuthenticationRequired {
            openSettings()
            return
        }
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
    var onRestartSession: (() -> Void)?
    var onCapture: (() -> Void)?
    var onChooseFiles: (() -> Void)?
    var onDraftChanged: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onCancelSend: (() -> Void)?
    var onRetry: (() -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?

    private let transcriptStack = NSStackView()
    private let transcriptScroll = NSScrollView()
    private let transcriptDocument = FlippedDocumentView()
    private let header = NSStackView()
    private let restartButton = NSButton(title: AppText.localized("새 세션"), target: nil, action: nil)
    private let attachmentStack = NSStackView()
    private let attachmentScroll = NSScrollView()
    private let captureButton = ChatAuxiliaryButton(title: AppText.localized("캡처"))
    private let fileButton = ChatAuxiliaryButton(title: AppText.localized("파일"))
    private let composer = NSTextField()
    private let sendButton = NSButton(title: AppText.localized("보내기"), target: nil, action: nil)
    private let statusLabel = ThinkingStatusField(
        wrappingLabelWithString: AppText.localized("대화를 입력하거나 자료를 첨부하세요.")
    )
    private weak var emptyTranscriptLabel: NSTextField?
    private let retryButton = NSButton(title: AppText.localized("재시도"), target: nil, action: nil)
    private let cancelButton = NSButton(title: AppText.localized("취소"), target: nil, action: nil)
    private var closeButton: NSButton?
    private var lastAnnouncedStatus = ""
    private var statusIsError = false
    private var renderedMessages: [ChatMessage] = []
    private var theme = AppTheme.dark
    private let thinkingPolicy = ThinkingAnimationPolicy()
    private var loadingTask: Task<Void, Never>?
    private var loadingElapsed = 0
    private var renderedState = ChatBubbleState()
    private var renderedCanRetry = false
    private var renderedAgentNotice: ChatPanelController.AgentNotice?
    private var isPresented = false
    private var language = AppText.language

    deinit {
        loadingTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func loadView() {
        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        view = background
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        let title = NSTextField(labelWithString: "YumYum Agent")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: AppText.localized("닫기")
            )!,
            target: self,
            action: #selector(closePressed)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel(AppText.localized("대화 말풍선 닫기"))
        self.closeButton = closeButton
        restartButton.target = self
        restartButton.action = #selector(restartSessionPressed)
        restartButton.bezelStyle = .inline
        restartButton.controlSize = .small
        restartButton.setAccessibilityLabel(AppText.localized("새 대화 세션"))
        restartButton.setAccessibilityHelp(AppText.localized("대화 내용을 지우고 현재 Soul을 다음 요청에 적용합니다"))
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(restartButton)
        header.addArrangedSubview(closeButton)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.wantsLayer = true

        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.wantsLayer = true
        transcriptStack.setAccessibilityElement(true)
        transcriptStack.setAccessibilityRole(.list)
        transcriptStack.setAccessibilityLabel(AppText.localized("대화 내용"))

        let document = transcriptDocument
        document.translatesAutoresizingMaskIntoConstraints = false
        document.wantsLayer = true
        document.addSubview(transcriptStack)
        transcriptScroll.documentView = document
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder
        transcriptScroll.wantsLayer = true
        transcriptScroll.contentView.wantsLayer = true
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
        attachmentStack.setAccessibilityLabel(AppText.localized("초안 첨부 파일"))
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
        captureButton.setAccessibilityLabel(AppText.localized("화면 영역 캡처 첨부"))
        captureButton.setAccessibilityHelp(AppText.localized("드래그한 화면 영역을 전송하지 않고 초안에 첨부합니다"))

        fileButton.target = self
        fileButton.action = #selector(filePressed)
        fileButton.image = NSImage(
            systemSymbolName: "paperclip",
            accessibilityDescription: nil
        )
        fileButton.imagePosition = .imageLeading
        fileButton.setAccessibilityLabel(AppText.localized("파일 첨부"))
        fileButton.setAccessibilityHelp(AppText.localized("선택한 파일을 전송하지 않고 초안에 첨부합니다"))

        let inputButtons = NSStackView(views: [captureButton, fileButton, NSView()])
        inputButtons.orientation = .horizontal
        inputButtons.spacing = 8

        composer.placeholderString = AppText.localized("메시지 입력")
        composer.delegate = self
        composer.target = self
        composer.action = #selector(sendPressed)
        composer.setAccessibilityLabel(AppText.localized("대화 메시지"))
        composer.setAccessibilityHelp(AppText.localized("Return을 눌러 전송합니다"))

        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded
        sendButton.setAccessibilityLabel(AppText.localized("메시지 보내기"))
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let composerRow = NSStackView(views: [composer, sendButton])
        composerRow.orientation = .horizontal
        composerRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("chat-loading-status")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityLabel(AppText.localized("YumYum Agent 상태"))

        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.setAccessibilityLabel(AppText.localized("마지막 메시지 재시도"))
        retryButton.isHidden = true

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.setAccessibilityLabel(AppText.localized("응답 생성 취소"))
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
        applyTheme(theme)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        view.appearance = theme.appearance
        let chatCanvas = theme.palette.chatCanvas.withAlphaComponent(1)
        view.layer?.backgroundColor = chatCanvas.cgColor
        view.layer?.borderWidth = theme == .light
            && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? 1
            : 0.5
        view.layer?.borderColor = theme.palette.chatBorder.cgColor
        view.layer?.shadowColor = theme.palette.chatShadow.cgColor
        view.layer?.shadowOpacity = theme == .light ? 1 : 0
        view.layer?.shadowRadius = 10
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        header.layer?.backgroundColor = chatCanvas.cgColor
        transcriptScroll.layer?.backgroundColor = chatCanvas.cgColor
        transcriptScroll.contentView.layer?.backgroundColor = chatCanvas.cgColor
        transcriptDocument.layer?.backgroundColor = chatCanvas.cgColor
        transcriptStack.layer?.backgroundColor = chatCanvas.cgColor
        applyComposerTheme()
        captureButton.applyTheme(theme)
        fileButton.applyTheme(theme)
        transcriptStack.arrangedSubviews
            .compactMap { $0 as? ChatMessageRowView }
            .forEach { $0.applyTheme(theme) }
        attachmentStack.arrangedSubviews.forEach {
            $0.layer?.backgroundColor = theme.palette.userMessage.cgColor
        }
        emptyTranscriptLabel?.textColor = theme.palette.chatSecondaryText
        statusLabel.textColor = statusIsError
            ? theme.palette.error
            : theme.palette.chatSecondaryText
    }

    func render(
        state: ChatBubbleState,
        canRetry: Bool,
        canRestart: Bool = true,
        isRestarting: Bool = false,
        agentNotice: ChatPanelController.AgentNotice?
    ) {
        guard isViewLoaded else { return }
        renderedState = state
        renderedCanRetry = canRetry
        renderedAgentNotice = agentNotice
        updateLoadingAnimation()
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

        var isBusy: Bool
        let status: String
        let isError: Bool
        switch state.phase {
        case .idle:
            isBusy = false
            status = agentNotice?.text(language: language)
                ?? AppText.localized("대화를 입력하거나 자료를 첨부하세요.", language: language)
            isError = agentNotice != nil
        case .capturing:
            isBusy = true
            status = AppText.localized("드래그하여 캡처할 영역을 선택하세요.", language: language)
            isError = false
        case .sending:
            isBusy = true
            status = loadingText
            isError = false
        case .cancelled:
            isBusy = false
            status = AppText.localized("전송을 취소했습니다.", language: language)
            isError = false
        case let .failed(message):
            isBusy = false
            status = UserFacingErrorRedactor.sanitize(message)
            isError = true
        }
        isBusy = isBusy || isRestarting

        captureButton.isEnabled = !isBusy
        restartButton.isEnabled = canRestart && !isBusy
        fileButton.isEnabled = !isBusy
        composer.isEnabled = !isBusy
        let hasDraft = !state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !state.draftAttachments.isEmpty
        sendButton.isEnabled = !isBusy && hasDraft
        retryButton.isHidden = !(canRetry && !isBusy)
        if case let .failed(message) = state.phase,
           UserFacingErrorRedactor.category(forSafeMessage: message) == .codexAuthenticationRequired {
            retryButton.title = AppText.localized(
                english: "Sign in again",
                korean: "다시 로그인",
                language: language
            )
            retryButton.setAccessibilityLabel(retryButton.title)
        }
        cancelButton.isHidden = !state.isSending
        applyComposerTheme()
        setStatus(status, isError: isError)
    }

    func setRestartEnabled(_ isEnabled: Bool) {
        restartButton.isEnabled = isEnabled
    }

#if DEBUG
    func renderForTesting(
        state: ChatBubbleState,
        elapsedMilliseconds: Int,
        reduceMotion: Bool
    ) {
        loadingTask?.cancel()
        loadingTask = nil
        loadingElapsed = elapsedMilliseconds
        renderedState = state
        renderTranscript(
            state.messages,
            streamingAssistantID: state.messages.last?.id
        )
        renderLoadingText(reduceMotion: reduceMotion)
    }

    var hasLoadingTaskForTesting: Bool { loadingTask != nil }

    func accessibilityDisplayOptionsDidChangeForTesting() {
        accessibilityDisplayOptionsDidChange(
            Notification(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        )
    }
#endif

    private var loadingText: String {
        thinkingPolicy.thought(
            at: loadingElapsed,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    func applyLanguage(_ language: AppLanguage = AppText.language) {
        self.language = language
        closeButton?.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: AppText.localized("닫기", language: language))
        closeButton?.setAccessibilityLabel(AppText.localized("대화 말풍선 닫기", language: language))
        restartButton.title = AppText.localized(english: "New Session", korean: "새 세션", language: language)
        restartButton.setAccessibilityLabel(AppText.localized(english: "New chat session", korean: "새 대화 세션", language: language))
        restartButton.setAccessibilityHelp(AppText.localized(english: "Clears the conversation and applies the current Soul to the next request", korean: "대화 내용을 지우고 현재 Soul을 다음 요청에 적용합니다", language: language))
        transcriptStack.setAccessibilityLabel(AppText.localized("대화 내용", language: language))
        attachmentStack.setAccessibilityLabel(AppText.localized("초안 첨부 파일", language: language))
        captureButton.title = AppText.localized(english: "Capture", korean: "캡처", language: language)
        captureButton.setAccessibilityLabel(AppText.localized("화면 영역 캡처 첨부", language: language))
        captureButton.setAccessibilityHelp(AppText.localized("드래그한 화면 영역을 전송하지 않고 초안에 첨부합니다", language: language))
        fileButton.title = AppText.localized(english: "Files", korean: "파일", language: language)
        fileButton.setAccessibilityLabel(AppText.localized("파일 첨부", language: language))
        fileButton.setAccessibilityHelp(AppText.localized("선택한 파일을 전송하지 않고 초안에 첨부합니다", language: language))
        sendButton.title = AppText.localized(english: "Send", korean: "보내기", language: language)
        sendButton.setAccessibilityLabel(AppText.localized("메시지 보내기", language: language))
        retryButton.title = AppText.localized(english: "Retry", korean: "재시도", language: language)
        retryButton.setAccessibilityLabel(AppText.localized("마지막 메시지 재시도", language: language))
        cancelButton.title = AppText.localized(english: "Cancel", korean: "취소", language: language)
        cancelButton.setAccessibilityLabel(AppText.localized("응답 생성 취소", language: language))
        composer.placeholderString = AppText.localized(
            english: "Type a message or attach something",
            korean: "대화를 입력하거나 자료를 첨부하세요.",
            language: language
        )
        composer.setAccessibilityLabel(AppText.localized("대화 메시지", language: language))
        composer.setAccessibilityHelp(AppText.localized("Return을 눌러 전송합니다", language: language))
        statusLabel.language = language
        statusLabel.setAccessibilityLabel(AppText.localized("YumYum Agent 상태", language: language))
        emptyTranscriptLabel?.stringValue = AppText.localized("캡처나 파일을 첨부하고 메시지를 보내면 대화가 여기에 쌓입니다.", language: language)
        emptyTranscriptLabel?.setAccessibilityLabel(AppText.localized("아직 대화가 없습니다", language: language))
        transcriptStack.arrangedSubviews.compactMap { $0 as? ChatMessageRowView }.forEach {
            $0.applyLanguage(language)
        }
        localizeAttachmentRows(language)
        let status: String
        let isError: Bool
        switch renderedState.phase {
        case .idle:
            status = renderedAgentNotice?.text(language: language)
                ?? AppText.localized("대화를 입력하거나 자료를 첨부하세요.", language: language)
            isError = renderedAgentNotice != nil
        case .capturing:
            status = AppText.localized("드래그하여 캡처할 영역을 선택하세요.", language: language)
            isError = false
        case .sending:
            status = loadingText
            isError = false
        case .cancelled:
            status = AppText.localized("전송을 취소했습니다.", language: language)
            isError = false
        case let .failed(message):
            status = UserFacingErrorRedactor.sanitize(message)
            isError = true
        }
        setStatus(status, isError: isError)
    }

    private func localizeAttachmentRows(_ language: AppLanguage) {
        for row in attachmentStack.arrangedSubviews.compactMap({ $0 as? NSStackView }) {
            guard row.arrangedSubviews.count >= 4,
                  let label = row.arrangedSubviews[1] as? NSTextField,
                  let remove = row.arrangedSubviews[3] as? NSButton else { continue }
            row.setAccessibilityLabel(AppText.localized(
                english: "Attached file \(label.stringValue)",
                korean: "첨부 파일 \(label.stringValue)",
                language: language
            ))
            remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: AppText.localized("첨부 제거", language: language))
            remove.setAccessibilityLabel(AppText.localized(
                english: "Remove \(label.stringValue)",
                korean: "\(label.stringValue) 첨부 제거",
                language: language
            ))
        }
    }

    private func updateLoadingAnimation() {
        guard renderedState.isSending, isPresented else {
            loadingTask?.cancel()
            loadingTask = nil
            loadingElapsed = 0
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            loadingTask?.cancel()
            loadingTask = nil
            loadingElapsed = 0
            return
        }
        guard loadingTask == nil else { return }
        loadingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.renderedState.isSending == true {
                self?.renderLoadingText(reduceMotion: false)
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                self?.advanceLoadingAnimation()
            }
            self?.loadingTask = nil
        }
    }

    private func advanceLoadingAnimation() {
        loadingElapsed = (
            loadingElapsed + 300
        ) % ThinkingAnimationPolicy.cycleMilliseconds
    }

    private func renderLoadingText(reduceMotion: Bool) {
        let text = thinkingPolicy.thought(
            at: loadingElapsed,
            reduceMotion: reduceMotion
        )
        statusLabel.stringValue = text
        statusLabel.setAccessibilityLabel(AppText.localized("응답 생성 중", language: language))
        statusLabel.setAccessibilityValue(AppText.localized("응답 생성 중", language: language))
        transcriptStack.arrangedSubviews
            .compactMap { $0 as? ChatMessageRowView }
            .forEach { $0.setLoadingText(text) }
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        loadingTask?.cancel()
        loadingTask = nil
        loadingElapsed = 0
        render(
            state: renderedState,
            canRetry: renderedCanRetry,
            agentNotice: renderedAgentNotice
        )
        applyTheme(theme)
    }

    func setPresented(_ presented: Bool) {
        isPresented = presented
        if presented {
            updateLoadingAnimation()
        } else {
            loadingTask?.cancel()
            loadingTask = nil
        }
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
            row.render(
                message,
                isStreaming: message.id == streamingAssistantID,
                loadingText: loadingText
            )
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
        emptyTranscriptLabel = nil
        if messages.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: AppText.localized("캡처나 파일을 첨부하고 메시지를 보내면 대화가 여기에 쌓입니다.")
            )
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = theme.palette.chatSecondaryText
            empty.alignment = .center
            empty.maximumNumberOfLines = 3
            empty.setAccessibilityLabel(AppText.localized("아직 대화가 없습니다"))
            emptyTranscriptLabel = empty
            transcriptStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor, constant: -8).isActive = true
        } else {
            for message in messages {
                let row = ChatMessageRowView(
                    message: message,
                    isStreaming: message.id == streamingAssistantID,
                    theme: theme,
                    loadingText: loadingText
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
            label.textColor = theme.palette.chatSecondaryText
            label.lineBreakMode = .byTruncatingMiddle
            let remove = NSButton(
                image: NSImage(
                    systemSymbolName: "xmark",
                    accessibilityDescription: AppText.localized("첨부 제거")
                )!,
                target: self,
                action: #selector(removeAttachmentPressed(_:))
            )
            remove.isBordered = false
            remove.identifier = NSUserInterfaceItemIdentifier(attachment.id.uuidString)
            remove.setAccessibilityLabel(AppText.localized(
                english: "Remove \(attachment.displayName)",
                korean: "\(attachment.displayName) 첨부 제거"
            ))
            let row = NSStackView(views: [icon, label, NSView(), remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            row.layer?.backgroundColor = theme.palette.userMessage.cgColor
            row.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 5)
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.group)
            row.setAccessibilityLabel(AppText.localized(
                english: "Attached file \(attachment.displayName)",
                korean: "첨부 파일 \(attachment.displayName)"
            ))
            attachmentStack.addArrangedSubview(row)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusIsError = isError
        statusLabel.stringValue = text
        statusLabel.setAccessibilityLabel(
            renderedState.isSending
                ? AppText.localized("응답 생성 중", language: language)
                : AppText.localized("YumYum Agent 상태", language: language)
        )
        statusLabel.textColor = isError
            ? theme.palette.error
            : theme.palette.chatSecondaryText
        let accessibilityStatus = renderedState.isSending
            ? AppText.localized("응답 생성 중", language: language)
            : text
        statusLabel.setAccessibilityValue(accessibilityStatus)
        guard lastAnnouncedStatus != accessibilityStatus else { return }
        lastAnnouncedStatus = accessibilityStatus
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: accessibilityStatus,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func applyComposerTheme() {
        composer.backgroundColor = composer.isEnabled
            ? theme.palette.composerSurface
            : .controlBackgroundColor
        composer.textColor = composer.isEnabled
            ? theme.palette.chatText
            : .disabledControlTextColor
    }

    @objc private func closePressed() { onClose?() }
    @objc private func restartSessionPressed() { onRestartSession?() }
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
    private var message: ChatMessage
    private var isStreaming: Bool
    private var theme: AppTheme
    private var loadingLabel: NSTextField?

    init(
        message: ChatMessage,
        isStreaming: Bool,
        theme: AppTheme,
        loadingText: String
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.theme = theme
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 13
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        if message.role == .user {
            addArrangedSubview(spacer)
            addArrangedSubview(bubble)
        } else {
            addArrangedSubview(bubble)
            addArrangedSubview(spacer)
        }
        applyTheme(theme)
        render(message, isStreaming: isStreaming, loadingText: loadingText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        _ message: ChatMessage,
        isStreaming: Bool,
        loadingText: String? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        messageContent?.removeFromSuperview()
        loadingLabel = nil

        let content: NSView
        if message.isLoading {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            let label = ThinkingStatusField(labelWithString: loadingText ?? "Yum.")
            label.identifier = NSUserInterfaceItemIdentifier("chat-loading-message")
            label.font = .systemFont(ofSize: 13)
            label.setAccessibilityLabel(AppText.localized("응답 생성 중"))
            label.setAccessibilityValue(AppText.localized("응답 생성 중"))
            loadingLabel = label
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
                    textColor: theme.palette.chatText,
                    isStreaming: isStreaming
                )
            } else {
                label.stringValue = message.visibleText
                label.textColor = theme.palette.chatText
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

        let role = message.role == .user ? AppText.localized("사용자") : AppText.localized("어시스턴트")
        let value = message.isLoading ? AppText.localized("응답 생성 중") : message.visibleText
        setAccessibilityLabel("\(role): \(value)")
    }

    func applyLanguage(_ language: AppLanguage) {
        let role = message.role == .user
            ? AppText.localized("사용자", language: language)
            : AppText.localized("어시스턴트", language: language)
        let value = message.isLoading
            ? AppText.localized("응답 생성 중", language: language)
            : message.visibleText
        setAccessibilityLabel("\(role): \(value)")
        if message.isLoading {
            (loadingLabel as? ThinkingStatusField)?.language = language
            loadingLabel?.setAccessibilityLabel(AppText.localized("응답 생성 중", language: language))
            loadingLabel?.setAccessibilityValue(AppText.localized("응답 생성 중", language: language))
        }
    }

    func setLoadingText(_ text: String) {
        loadingLabel?.stringValue = text
        loadingLabel?.setAccessibilityLabel(AppText.localized("응답 생성 중"))
        loadingLabel?.setAccessibilityValue(AppText.localized("응답 생성 중"))
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        bubble.layer?.backgroundColor = (
            message.role == .user
                ? theme.palette.userMessage
                : theme.palette.assistantMessage
        ).cgColor
        render(message, isStreaming: isStreaming, loadingText: loadingLabel?.stringValue)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ChatAuxiliaryButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            layer?.borderWidth = 0
        }
        return accepted
    }

    func applyTheme(_ theme: AppTheme) {
        layer?.backgroundColor = theme.palette.auxiliarySurface.cgColor
        contentTintColor = theme.palette.chatText
        updateAppearance()
    }

    private func updateAppearance() {
        alphaValue = isEnabled ? 1 : 0.42
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        layer?.borderWidth = focused ? 1 : 0
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }
}

private final class ThinkingStatusField: NSTextField {
    var language = AppText.language

    override func accessibilityValue() -> String? {
        stringValue.hasPrefix("Yum")
            ? AppText.localized("응답 생성 중", language: language)
            : super.accessibilityValue()
    }
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
