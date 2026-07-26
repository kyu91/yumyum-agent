import AppKit
import SwiftUI
import YumYumCore

@MainActor
final class YumYumAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var petVisibility = FloatingPetVisibilityPolicy()
    @Published private(set) var shortcutChoice = GlobalShortcutChoice.load()

    private var petWindowController: FloatingPetWindowController?
    private var quickMenuController: QuickMenuPanelController?
    private var shortcutController: GlobalShortcutController?
    private var feedFeedback: AppFeedFeedback?
    private weak var viewModel: YumYumAppViewModel?
    private var mainWindow: NSWindow?
    private var openMainWindowAction: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        let controller = FloatingPetWindowController { [weak self] in
            self?.toggleQuickMenu()
        }
        petWindowController = controller
        assembleQuickMenuIfPossible()
        if petVisibility.isVisible {
            controller.show()
        }
        captureMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        quickMenuController?.prepareForTermination()
        shortcutController = nil
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

    @objc
    private func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is FloatingPetPanel) else {
            return
        }
        mainWindow = window
    }

    private func captureMainWindow() {
        if let window = NSApplication.shared.windows.first(where: {
            !($0 is NSPanel) && $0.title == "YumYum"
        }) {
            mainWindow = window
        }
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openMainWindowAction?()
        captureMainWindow()
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

        super.init()

        panel.identifier = Self.panelIdentifier
        panel.title = "YumYum Pet"
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

        let hostingView = FloatingPetHostingView(
            rootView: YumYumPetView(
                presentationModel: presentationModel,
                onClick: onClick
            ),
            onClick: onClick
        )
        hostingView.onDragEnded = { [weak self] in
            self?.clampToVisibleScreen()
        }
        panel.contentView = hostingView

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

    var mouthTargetFrame: CGRect {
        CGRect(
            x: panel.frame.midX - 11,
            y: panel.frame.midY - 16,
            width: 22,
            height: 14
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
}

final class FloatingPetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FloatingPetHostingView<Content: View>: NSHostingView<Content> {
    var onDragEnded: @MainActor () -> Void = {}

    private let onClick: @MainActor () -> Void
    private var mouseDownLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var didDrag = false

    init(
        rootView: Content,
        onClick: @escaping @MainActor () -> Void
    ) {
        self.onClick = onClick
        super.init(rootView: rootView)
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
}

private struct YumYumPetView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    @ObservedObject var presentationModel: PetPresentationModel
    let onClick: @MainActor () -> Void

    var body: some View {
        ZStack {
            Canvas { context, size in
                drawPet(in: &context, size: size)
            }
            .accessibilityHidden(true)

            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(red: 0.78, green: 0.25, blue: 0.08))
                .offset(y: 24)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(
            x: presentationModel.chewFrame.bodyScaleX,
            y: presentationModel.chewFrame.bodyScaleY,
            anchor: .center
        )
        .offset(y: presentationModel.chewFrame.bodyOffsetY)
        .contentShape(Rectangle())
        .scaleEffect(isHovered && !reduceMotion ? 1.025 : 1)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isHovered
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("YumYum 플로팅 펫")
        .accessibilityHint("클릭하면 빠른 메뉴를 엽니다. 드래그하여 이동할 수 있습니다.")
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

        let outline = Color(red: 0.42, green: 0.16, blue: 0.08)
        let bodyColor = Color(red: 1, green: 0.55, blue: 0.16)
        let innerEar = Color(red: 1, green: 0.75, blue: 0.48)

        var leftEar = Path()
        leftEar.move(to: point(25, 31))
        leftEar.addCurve(
            to: point(39, 24),
            control1: point(20, 13),
            control2: point(24, 8)
        )
        leftEar.addCurve(
            to: point(25, 31),
            control1: point(34, 26),
            control2: point(29, 29)
        )

        var rightEar = Path()
        rightEar.move(to: point(57, 24))
        rightEar.addCurve(
            to: point(71, 31),
            control1: point(72, 8),
            control2: point(76, 13)
        )
        rightEar.addCurve(
            to: point(57, 24),
            control1: point(67, 29),
            control2: point(62, 26)
        )

        for ear in [leftEar, rightEar] {
            context.fill(ear, with: .color(innerEar))
            context.stroke(
                ear,
                with: .color(outline),
                style: StrokeStyle(lineWidth: 2.2 * scale, lineJoin: .round)
            )
        }

        var body = Path()
        body.move(to: point(48, 20))
        body.addCurve(
            to: point(80, 49),
            control1: point(68, 19),
            control2: point(80, 30)
        )
        body.addCurve(
            to: point(68, 82),
            control1: point(80, 68),
            control2: point(76, 79)
        )
        body.addCurve(
            to: point(28, 82),
            control1: point(58, 89),
            control2: point(38, 89)
        )
        body.addCurve(
            to: point(16, 49),
            control1: point(20, 79),
            control2: point(16, 68)
        )
        body.addCurve(
            to: point(48, 20),
            control1: point(16, 30),
            control2: point(28, 19)
        )
        context.fill(body, with: .color(bodyColor))
        context.stroke(
            body,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 2.4 * scale, lineJoin: .round)
        )

        context.fill(
            Path(ellipseIn: rect(27, 51, 42, 31)),
            with: .color(Color(red: 1, green: 0.89, blue: 0.67))
        )
        context.fill(
            Path(
                ellipseIn: rect(
                    28 - presentationModel.chewFrame.cheekOffset,
                    45,
                    10,
                    6
                )
            ),
            with: .color(Color(red: 1, green: 0.43, blue: 0.37).opacity(0.7))
        )
        context.fill(
            Path(
                ellipseIn: rect(
                    58 + presentationModel.chewFrame.cheekOffset,
                    45,
                    10,
                    6
                )
            ),
            with: .color(Color(red: 1, green: 0.43, blue: 0.37).opacity(0.7))
        )

        for eyeX in [34.0, 56.0] {
            context.fill(
                Path(ellipseIn: rect(eyeX, 36, 7, 10)),
                with: .color(outline)
            )
            context.fill(
                Path(ellipseIn: rect(eyeX + 1.5, 37, 2.2, 2.8)),
                with: .color(.white)
            )
        }

        switch presentationModel.chewFrame.mouth {
        case .open:
            context.fill(
                Path(ellipseIn: rect(39, 48, 18, 16)),
                with: .color(outline)
            )
            context.fill(
                Path(ellipseIn: rect(43, 56, 10, 5)),
                with: .color(Color(red: 1, green: 0.43, blue: 0.37))
            )
        case .halfClosed:
            context.fill(
                Path(ellipseIn: rect(41, 51, 14, 6)),
                with: .color(outline)
            )
        case .closed:
            var smile = Path()
            smile.move(to: point(43, 49))
            smile.addQuadCurve(to: point(53, 49), control: point(48, 56))
            context.stroke(
                smile,
                with: .color(outline),
                style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round)
            )
        }

        for footX in [24.0, 60.0] {
            let foot = Path(ellipseIn: rect(footX, 78, 13, 8))
            context.fill(foot, with: .color(bodyColor))
            context.stroke(
                foot,
                with: .color(outline),
                style: StrokeStyle(lineWidth: 2 * scale)
            )
        }
    }
}
