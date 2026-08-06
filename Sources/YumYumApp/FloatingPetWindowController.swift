import AppKit
import Combine
import SwiftUI
import YumYumCore

@MainActor
final class YumYumAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var petVisibility = FloatingPetVisibilityPolicy()
    @Published private(set) var shortcutChoice: GlobalShortcutChoice
    @Published private(set) var currentTheme: AppTheme
    @Published private(set) var currentLanguage: AppLanguage

    private let languageStore: AppLanguageStore

    private var petWindowController: FloatingPetWindowController?
    private var quickMenuController: QuickMenuPanelController?
    private var shortcutController: GlobalShortcutController?
    private var feedFeedback: AppFeedFeedback?
    private weak var viewModel: YumYumAppViewModel?
    private weak var mainWindow: NSWindow?
    private var openMainWindowAction: (@MainActor () -> Void)?
    private var runtimeShutdownTask: Task<Void, Never>?
    private var didShutdownRuntime = false
    private var terminationReplyPending = false
    private var connectedAgentCancellable: AnyCancellable?

    override init() {
        LegacyPreferencesMigration.migrate()
        shortcutChoice = GlobalShortcutChoice.load()
        currentTheme = AppTheme.load()
        let languageStore = AppLanguageStore()
        let language = languageStore.load()
        self.languageStore = languageStore
        currentLanguage = language
        AppText.setLanguage(language)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = FloatingPetWindowController { [weak self] in
            self?.toggleQuickMenu()
        }
        petWindowController = controller
        controller.applyConnectedAgent(viewModel?.agentSnapshot.selectedInstallation?.definitionID)
        assembleQuickMenuIfPossible()
        if petVisibility.isVisible {
            controller.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        quickMenuController?.prepareForTermination()
        shortcutController = nil
        Task { @MainActor [weak self] in
            await self?.shutdown()
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard viewModel != nil, !didShutdownRuntime else {
            return .terminateNow
        }
        guard !terminationReplyPending else {
            return .terminateLater
        }
        terminationReplyPending = true
        Task { @MainActor [weak self] in
            await self?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func shutdown() async {
        if let runtimeShutdownTask {
            await runtimeShutdownTask.value
            return
        }
        quickMenuController?.prepareForTermination()
        shortcutController = nil
        let viewModel = viewModel
        let task = Task { @MainActor in
            if let viewModel {
                await viewModel.shutdown()
            }
        }
        runtimeShutdownTask = task
        await task.value
        didShutdownRuntime = true
    }

    func setPetVisible(_ isVisible: Bool) {
        petVisibility.setVisible(isVisible)
        quickMenuController?.setPresentationEnabled(isVisible)
        if isVisible {
            petWindowController?.show()
        } else {
            quickMenuController?.hide(restorePetAfterCapture: false)
            petWindowController?.hide()
        }
    }

    func configure(viewModel: YumYumAppViewModel) {
        self.viewModel = viewModel
        assembleQuickMenuIfPossible()
        connectedAgentCancellable = viewModel.$agentSnapshot
            .map(\.selectedInstallation?.definitionID)
            .removeDuplicates()
            .sink { [weak self] definitionID in
                self?.petWindowController?.applyConnectedAgent(definitionID)
            }
    }

    private func assembleQuickMenuIfPossible() {
        guard quickMenuController == nil,
              let viewModel,
              let petWindowController else {
            return
        }

        let feedback = AppFeedFeedback(petController: petWindowController)
        let workflow = FeedWorkflow(
            sender: viewModel.agentRuntime,
            feedback: feedback
        )
        let quickMenuController = QuickMenuPanelController(
            petController: petWindowController,
            viewModel: viewModel,
            workflow: workflow,
            openSettings: { [weak self] in
                self?.openMainWindow()
            }
        )
        quickMenuController.applyTheme(currentTheme)
        feedback.quickMenuController = quickMenuController
        self.feedFeedback = feedback
        self.quickMenuController = quickMenuController
        shortcutController = GlobalShortcutController(
            choice: shortcutChoice
        ) { [weak self] in
            self?.showQuickMenu()
        }
    }

    func setShortcutChoice(_ choice: GlobalShortcutChoice) {
        shortcutChoice = choice
        choice.save()
        shortcutController?.update(choice: choice)
    }

    func setTheme(_ theme: AppTheme) {
        currentTheme = theme
        theme.save()
        mainWindow?.appearance = theme.appearance
        quickMenuController?.applyTheme(theme)
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        languageStore.save(language)
        AppText.setLanguage(language)
        petWindowController?.applyLanguage(language)
        quickMenuController?.applyLanguage(language)
    }

    func showQuickMenu() {
        guard petVisibility.isVisible,
              let quickMenuController,
              let viewModel else {
            return
        }
        quickMenuController.showCheckingStatus()
        quickMenuController.show()
        Task { @MainActor [weak quickMenuController, weak viewModel] in
            guard let quickMenuController, let viewModel else { return }
            await viewModel.refreshAgents(trigger: .quickMenuOpened)
            quickMenuController.update(snapshot: viewModel.agentSnapshot)
        }
    }

    private func toggleQuickMenu() {
        guard let quickMenuController else {
            openMainWindow()
            return
        }
        if quickMenuController.isVisible {
            quickMenuController.dismissActionBubble()
        } else {
            showQuickMenu()
        }
    }

    func setOpenMainWindowAction(_ action: @escaping @MainActor () -> Void) {
        openMainWindowAction = action
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.appearance = currentTheme.appearance
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openMainWindowAction?()
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class FloatingPetWindowController: NSObject {
    static let panelIdentifier = NSUserInterfaceItemIdentifier(
        "YumYumFloatingPetPanel"
    )

    let panel: FloatingPetPanel
    let presentationModel = PetPresentationModel()

    var isVisible: Bool { panel.isVisible }

    private let layout = FloatingPetLayout()
    private let hostingView: FloatingPetHostingView<YumYumPetView>

    init(onClick: @escaping @MainActor () -> Void) {
        let screen = Self.screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(
            origin: .zero,
            size: FloatingPetLayout.preferredSize
        )
        panel = FloatingPetPanel(
            contentRect: layout.initialFrame(in: visibleFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = FloatingPetHostingView(
            rootView: YumYumPetView(
                presentationModel: presentationModel,
                onClick: onClick
            ),
            onClick: onClick
        )

        super.init()

        panel.identifier = Self.panelIdentifier
        panel.title = "YumYum Agent Pet"
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

        hostingView.onDragEnded = { [weak self] in
            self?.clampToVisibleScreen()
        }
        panel.contentView = hostingView
        applyLanguage(AppText.language)

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
        clampToVisibleScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setMouthOpen(_ isOpen: Bool) {
        applyChewFrame(isOpen ? .mouthOpen : .resting)
    }

    func applyChewFrame(_ frame: PetChewFrame) {
        guard presentationModel.chewFrame != frame else { return }
        presentationModel.chewFrame = frame
    }

    func resetChewPresentation() {
        applyChewFrame(.resting)
    }

    func applyConnectedAgent(_ definitionID: AgentDefinitionID?) {
        guard presentationModel.connectedAgentID != definitionID else { return }
        presentationModel.connectedAgentID = definitionID
    }

    func applyLanguage(_ language: AppLanguage) {
        presentationModel.language = language
        hostingView.setAccessibilityElement(true)
        hostingView.setAccessibilityRole(.button)
        hostingView.setAccessibilityLabel(presentationModel.accessibilityLabel)
        hostingView.setAccessibilityHelp(presentationModel.accessibilityHint)
    }

    func configureFileDrop(
        canAccept: @escaping @MainActor ([URL]) -> Bool,
        perform: @escaping @MainActor ([URL]) -> Bool
    ) {
        hostingView.canAcceptFileDrop = canAccept
        hostingView.performFileDrop = perform
    }

    var mouthTargetFrame: CGRect {
        CGRect(
            x: panel.frame.midX - 15,
            y: panel.frame.midY - 18,
            width: 30,
            height: 20
        )
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        clampToVisibleScreen()
    }

    private func clampToVisibleScreen() {
        guard let screen = Self.bestScreen(for: panel.frame) else {
            return
        }

        var preferredFrame = panel.frame
        preferredFrame.size = FloatingPetLayout.preferredSize
        let frame = layout.clampedFrame(
            preferredFrame,
            inside: screen.visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func bestScreen(for frame: CGRect) -> NSScreen? {
        let intersectingScreen = NSScreen.screens.max { first, second in
            intersectionArea(first.frame, frame) < intersectionArea(second.frame, frame)
        }
        if let intersectingScreen,
           intersectionArea(intersectingScreen.frame, frame) > 0 {
            return intersectingScreen
        }
        return screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}

@MainActor
final class PetPresentationModel: ObservableObject {
    @Published var chewFrame = PetChewFrame.resting
    @Published var isFileDropTarget = false
    @Published var language = AppText.language
    @Published var connectedAgentID: AgentDefinitionID?

    var accessibilityLabel: String {
        AppText.localized("YumYum Agent 플로팅 펫", language: language)
    }

    var accessibilityHint: String {
        AppText.localized(
            "클릭하면 빠른 메뉴를 엽니다. 드래그하여 이동할 수 있습니다.",
            language: language
        )
    }
}

final class FloatingPetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPetHostingView<Content: View>: NSHostingView<Content> {
    var onDragEnded: @MainActor () -> Void = {}
    var canAcceptFileDrop: @MainActor ([URL]) -> Bool = { _ in false }
    var performFileDrop: @MainActor ([URL]) -> Bool = { _ in false }

    private let onClick: @MainActor () -> Void
    private var dropLifecycle = PetDropLifecycle()
    private var dropGeneration: UUID?
    private var dropPreviousChewFrame: PetChewFrame?
    private var mouseDownLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var didDrag = false

    init(
        rootView: Content,
        onClick: @escaping @MainActor () -> Void
    ) {
        self.onClick = onClick
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation,
              let windowOriginAtMouseDown,
              let window else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - mouseDownLocation.x
        let deltaY = currentLocation.y - mouseDownLocation.y
        if abs(deltaX) > 3 || abs(deltaY) > 3 {
            didDrag = true
        }
        window.setFrameOrigin(
            NSPoint(
                x: windowOriginAtMouseDown.x + deltaX,
                y: windowOriginAtMouseDown.y + deltaY
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            windowOriginAtMouseDown = nil
            didDrag = false
        }

        if didDrag {
            onDragEnded()
        } else {
            onClick()
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(pasteboard: sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(pasteboard: sender.draggingPasteboard)
    }

    func draggingEntered(pasteboard: NSPasteboard) -> NSDragOperation {
        resetDropPresentation()
        let urls = Self.fileURLs(from: pasteboard)
        dropGeneration = dropLifecycle.enter(
            isAccepted: !urls.isEmpty && canAcceptFileDrop(urls)
        )
        if dropGeneration != nil {
            dropPreviousChewFrame = petPresentationModel?.chewFrame
        }
        setDropPresentation(dropLifecycle.isHovering)
        return dropLifecycle.isHovering ? .copy : []
    }

    func draggingUpdated(pasteboard: NSPasteboard) -> NSDragOperation {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty,
              canAcceptFileDrop(urls),
              dropLifecycle.isHovering else {
            resetDropPresentation()
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cancelFileDrop()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        cancelFileDrop()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingUpdated(sender) == .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        performDragOperation(pasteboard: sender.draggingPasteboard)
    }

    func performDragOperation(pasteboard: NSPasteboard) -> Bool {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty,
              canAcceptFileDrop(urls),
              dropLifecycle.consume(dropGeneration) else {
            resetDropPresentation()
            return false
        }
        releaseDropPresentation()
        return performFileDrop(urls)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        cancelFileDrop()
    }

    func cancelFileDrop() {
        resetDropPresentation()
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private var petPresentationModel: PetPresentationModel? {
        (rootView as? YumYumPetView)?.presentationModel
    }

    private func setDropPresentation(_ isTarget: Bool) {
        petPresentationModel?.isFileDropTarget = isTarget
        if isTarget {
            petPresentationModel?.chewFrame = .mouthOpen
        }
    }

    private func resetDropPresentation() {
        guard dropLifecycle.cancel(dropGeneration) else { return }
        releaseDropPresentation()
    }

    private func releaseDropPresentation() {
        dropGeneration = nil
        petPresentationModel?.isFileDropTarget = false
        if petPresentationModel?.chewFrame == .mouthOpen,
           let dropPreviousChewFrame {
            petPresentationModel?.chewFrame = dropPreviousChewFrame
        }
        dropPreviousChewFrame = nil
    }
}

extension AgentDefinitionID {
    var headbandColor: Color {
        switch self {
        case .hermes: Color(red: 0.42, green: 0.36, blue: 0.91)
        case .openCode: Color(red: 0.16, green: 0.55, blue: 0.82)
        case .codex: Color(red: 0.22, green: 0.66, blue: 0.40)
        case .claudeCode: Color(red: 0.72, green: 0.25, blue: 0.48)
        }
    }

    var headbandIconName: String {
        switch self {
        case .hermes: "AgentIcon-Hermes"
        case .openCode: "AgentIcon-OpenCode"
        case .codex: "AgentIcon-Codex"
        case .claudeCode: "AgentIcon-ClaudeCode"
        }
    }
}

struct YumYumPetView: View {
    struct MouthDetails: Equatable {
        let noseCount: Int
        let mouthStrokeCount: Int
        let toothCount: Int
        let tongueCount: Int
    }

    enum ContourStrokeRole {
        case outer
        case leftInnerEar
        case rightInnerEar
    }

    static let contourStrokeRoles: [ContourStrokeRole] = [.outer]

    static func mouthDetails(for mouth: PetMouthPose) -> MouthDetails {
        switch mouth {
        case .closed:
            MouthDetails(noseCount: 1, mouthStrokeCount: 2, toothCount: 0, tongueCount: 0)
        case .halfClosed:
            MouthDetails(noseCount: 0, mouthStrokeCount: 0, toothCount: 0, tongueCount: 0)
        case .open:
            MouthDetails(noseCount: 0, mouthStrokeCount: 0, toothCount: 1, tongueCount: 1)
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    @ObservedObject var presentationModel: PetPresentationModel
    let onClick: @MainActor () -> Void

    static let silhouettePath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 14, y: 31))
        path.addLine(to: CGPoint(x: 20, y: 28))
        path.addCurve(to: CGPoint(x: 39, y: 29), control1: CGPoint(x: 14, y: 10), control2: CGPoint(x: 23, y: 9))
        path.addLine(to: CGPoint(x: 61, y: 29))
        path.addCurve(to: CGPoint(x: 79, y: 31), control1: CGPoint(x: 75, y: 15), control2: CGPoint(x: 80, y: 10))
        path.addCurve(to: CGPoint(x: 84, y: 78), control1: CGPoint(x: 86, y: 50), control2: CGPoint(x: 87, y: 66))
        path.addCurve(to: CGPoint(x: 15, y: 79), control1: CGPoint(x: 63, y: 85), control2: CGPoint(x: 35, y: 84))
        path.addCurve(to: CGPoint(x: 14, y: 31), control1: CGPoint(x: 10, y: 61), control2: CGPoint(x: 10, y: 45))
        path.closeSubpath()
        return path
    }()

    var body: some View {
        Canvas { context, size in
            drawPet(in: &context, size: size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(
            x: presentationModel.chewFrame.bodyScaleX,
            y: presentationModel.chewFrame.bodyScaleY,
            anchor: .center
        )
        .offset(y: presentationModel.chewFrame.bodyOffsetY)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    Color(nsColor: .keyboardFocusIndicatorColor),
                    lineWidth: presentationModel.isFileDropTarget ? 2 : 0
                )
                .padding(5)
                .accessibilityHidden(true)
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.025 : 1)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isHovered
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentationModel.accessibilityLabel)
        .accessibilityHint(presentationModel.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onClick()
        }
    }

    private func drawPet(in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 96
        let offset = CGPoint(
            x: (size.width - 96 * scale) / 2,
            y: (size.height - 96 * scale) / 2
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: offset.x + x * scale,
                y: offset.y + y * scale,
                width: width * scale,
                height: height * scale
            )
        }

        let outline = Color(red: 0.25, green: 0.12, blue: 0.08)
        let bodyColor = Color(red: 0.91, green: 0.45, blue: 0.16)
        let innerEar = Color(red: 0.98, green: 0.64, blue: 0.38)

        let silhouette = Self.silhouettePath.applying(
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y)
        )
        context.fill(silhouette, with: .color(bodyColor))
        for role in Self.contourStrokeRoles where role == .outer {
            context.stroke(
                silhouette,
                with: .color(outline),
                style: StrokeStyle(lineWidth: 2 * scale, lineJoin: .round)
            )
        }

        var leftInnerEar = Path()
        leftInnerEar.move(to: point(21, 27))
        leftInnerEar.addCurve(to: point(34, 27), control1: point(17, 14), control2: point(22, 13))
        leftInnerEar.addLine(to: point(21, 27))
        context.fill(leftInnerEar, with: .color(innerEar))
        for role in Self.contourStrokeRoles where role == .leftInnerEar {
            context.stroke(leftInnerEar, with: .color(outline))
        }

        var rightInnerEar = Path()
        rightInnerEar.move(to: point(66, 28))
        rightInnerEar.addCurve(to: point(77, 29), control1: point(76, 16), control2: point(78, 14))
        rightInnerEar.addLine(to: point(66, 28))
        context.fill(rightInnerEar, with: .color(innerEar))
        for role in Self.contourStrokeRoles where role == .rightInnerEar {
            context.stroke(rightInnerEar, with: .color(outline))
        }

        for (start, end) in [(CGPoint(x: 23, y: 37), CGPoint(x: 72, y: 40)), (CGPoint(x: 20, y: 45), CGPoint(x: 75, y: 48)), (CGPoint(x: 24, y: 72), CGPoint(x: 73, y: 69))] {
            var accent = Path()
            accent.move(to: point(start.x, start.y))
            accent.addLine(to: point(end.x, end.y))
            context.stroke(accent, with: .color(Color(red: 0.98, green: 0.56, blue: 0.20)), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
        }

        if let connectedAgentID = presentationModel.connectedAgentID {
            var band = Path()
            band.move(to: point(19, 29))
            band.addQuadCurve(to: point(79, 30), control: point(49, 35))
            context.stroke(band, with: .color(outline), style: StrokeStyle(lineWidth: 11 * scale, lineCap: .round))
            context.stroke(band, with: .color(connectedAgentID.headbandColor), style: StrokeStyle(lineWidth: 8 * scale, lineCap: .round))

            let badgeCenter = point(49, 31)
            let badgeRadius = 10 * scale
            let badgeRect = CGRect(
                x: badgeCenter.x - badgeRadius,
                y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )
            let badgePath = Path(ellipseIn: badgeRect)
            context.fill(badgePath, with: .color(.white))
            context.drawLayer { layer in
                layer.clip(to: badgePath)
                layer.draw(
                    Image(nsImage: NSImage(named: connectedAgentID.headbandIconName) ?? NSImage()),
                    in: badgeRect
                )
            }
            context.stroke(badgePath, with: .color(outline), style: StrokeStyle(lineWidth: 1.5 * scale))
        }

        context.fill(
            Path(
                ellipseIn: rect(
                    27 - presentationModel.chewFrame.cheekOffset,
                    50,
                    10,
                    6
                )
            ),
            with: .color(Color(red: 0.91, green: 0.36, blue: 0.29).opacity(0.72))
        )
        context.fill(
            Path(
                ellipseIn: rect(
                    59 + presentationModel.chewFrame.cheekOffset,
                    49,
                    12,
                    7
                )
            ),
            with: .color(Color(red: 0.91, green: 0.36, blue: 0.29).opacity(0.72))
        )

        context.fill(Path(ellipseIn: rect(31, 43, 6, 8)), with: .color(outline))
        context.fill(Path(ellipseIn: rect(61, 45, 7, 9)), with: .color(outline))

        switch presentationModel.chewFrame.mouth {
        case .open:
            context.fill(
                Path(ellipseIn: rect(33, 50, 32, 25)),
                with: .color(outline)
            )
            context.fill(
                Path(ellipseIn: rect(39, 66, 20, 7)),
                with: .color(Color(red: 0.96, green: 0.43, blue: 0.39))
            )
            var tooth = Path()
            tooth.move(to: point(43, 51))
            tooth.addLine(to: point(50, 51))
            tooth.addLine(to: point(47, 58))
            tooth.closeSubpath()
            context.fill(tooth, with: .color(.white))
            context.stroke(tooth, with: .color(outline), style: StrokeStyle(lineWidth: scale))
        case .halfClosed:
            context.fill(
                Path(ellipseIn: rect(38, 57, 22, 6)),
                with: .color(outline)
            )
        case .closed:
            var nose = Path()
            nose.move(to: point(46, 55.5))
            nose.addLine(to: point(52.5, 56.2))
            nose.addLine(to: point(49, 59.5))
            nose.closeSubpath()
            context.fill(nose, with: .color(outline))

            var mouth = Path()
            mouth.move(to: point(49, 62.5))
            mouth.addLine(to: point(43, 67))
            mouth.move(to: point(49, 62.5))
            mouth.addLine(to: point(56, 68))
            context.stroke(
                mouth,
                with: .color(outline),
                style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
