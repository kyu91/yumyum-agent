import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import YumYumCore

enum ScreenCaptureCoordinatorError: LocalizedError {
    case alreadyPresenting
    case permissionDenied
    case noDisplays
    case regionTooSmall
    case captureFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyPresenting:
            AppText.localized("이미 화면 캡처 영역을 선택하고 있습니다.")
        case .permissionDenied:
            AppText.localized("화면 캡처 권한이 필요합니다.")
        case .noDisplays:
            AppText.localized("캡처할 디스플레이를 찾지 못했습니다.")
        case .regionTooSmall:
            AppText.localized("가로와 세로가 각각 8pt 이상인 영역을 선택하세요.")
        case .captureFailed:
            AppText.localized("선택한 영역을 캡처하지 못했습니다.")
        case .encodingFailed:
            AppText.localized("선택한 화면을 PNG로 저장하지 못했습니다.")
        }
    }
}

struct ScreenCaptureResult: Equatable, Sendable {
    let url: URL
    let selectedRegion: CGRect
}

@MainActor
final class ScreenCaptureCoordinator {
    private let selector = CaptureRegionOverlayController()
    private var isCapturing = false

    func cancel() {
        selector.cancel()
    }

    func capture() async throws -> ScreenCaptureResult {
        guard !isCapturing else {
            throw ScreenCaptureCoordinatorError.alreadyPresenting
        }
        isCapturing = true
        defer { isCapturing = false }

        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureCoordinatorError.permissionDenied
        }

        let region = try await selector.selectRegion()
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(60))
        let image = try await captureImage(in: region)
        try Task.checkCancellation()
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureCoordinatorError.encodingFailed
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(CaptureTemporaryFileCleanup.filenamePrefix)\(UUID().uuidString).png"
        )
        do {
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return ScreenCaptureResult(url: url, selectedRegion: region)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func captureImage(in region: CGRect) async throws -> CGImage {
        if #available(macOS 15.2, *) {
            return try await captureSingleRegionUsingScreenCaptureKit(in: region)
        }
        return try await captureDisplayFragments(in: region)
    }

    @available(macOS 15.2, *)
    private func captureSingleRegionUsingScreenCaptureKit(
        in region: CGRect
    ) async throws -> CGImage {
        let primaryMaxY = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        return try await Self.captureSingleRegion(
            in: region,
            primaryDisplayMaxY: primaryMaxY
        ) { screenCaptureKitRegion in
            try await SCScreenshotManager.captureImage(in: screenCaptureKitRegion)
        }
    }

    static func captureSingleRegion(
        in region: CGRect,
        primaryDisplayMaxY: CGFloat,
        capture: (CGRect) async throws -> CGImage
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let image = try await capture(
            CGRect(
                x: region.minX,
                y: primaryDisplayMaxY - region.maxY,
                width: region.width,
                height: region.height
            )
        )
        try Task.checkCancellation()
        return image
    }

    private func captureDisplayFragments(in region: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let screensByID = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                screen.displayID.map { ($0, screen) }
            }
        )
        let displaysByID = Dictionary(
            uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) }
        )
        let geometries = content.displays.compactMap { display -> CaptureDisplayGeometry? in
            guard let screen = screensByID[display.displayID] else {
                return nil
            }
            return CaptureDisplayGeometry(
                id: display.displayID,
                frame: screen.frame,
                scale: screen.backingScaleFactor
            )
        }
        return try await Self.captureDisplayFragments(
            in: region,
            displays: geometries,
            capture: { fragment in
                guard let display = displaysByID[fragment.displayID] else {
                    throw ScreenCaptureCoordinatorError.captureFailed
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = fragment.sourcePointRect
                configuration.width = max(1, Int(fragment.sourcePixelSize.width))
                configuration.height = max(1, Int(fragment.sourcePixelSize.height))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                return image
            },
            composite: Self.composite
        )
    }

    static func captureDisplayFragments(
        in region: CGRect,
        displays: [CaptureDisplayGeometry],
        capture: (CapturePixelFragment) async throws -> CGImage,
        composite: ([(CapturePixelFragment, CGImage)], CGSize) throws -> CGImage
    ) async throws -> CGImage {
        guard let plan = CaptureRegionPolicy().plan(region: region, displays: displays) else {
            throw ScreenCaptureCoordinatorError.noDisplays
        }
        var images: [(CapturePixelFragment, CGImage)] = []
        for fragment in plan.fragments {
            try Task.checkCancellation()
            images.append((fragment, try await capture(fragment)))
            try Task.checkCancellation()
        }
        return try composite(images, plan.pixelSize)
    }

    static func composite(
        _ images: [(CapturePixelFragment, CGImage)],
        size: CGSize
    ) throws -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureCoordinatorError.captureFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (fragment, image) in images {
            let destination = fragment.destinationPixelRect
            context.draw(
                image,
                in: CGRect(
                    x: destination.minX,
                    y: CGFloat(height) - destination.maxY,
                    width: destination.width,
                    height: destination.height
                )
            )
        }
        guard let image = context.makeImage() else {
            throw ScreenCaptureCoordinatorError.captureFailed
        }
        return image
    }
}

@MainActor
private final class CaptureRegionOverlayController {
    private let policy = CaptureRegionPolicy()
    private var windows: [CaptureOverlayWindow] = []
    private var gate: CaptureCallbackGate<CGRect>?
    private var selectionError: ScreenCaptureCoordinatorError?
    private var eventMonitor: Any?
    private var didPushCursor = false
    private var dragStart: CGPoint?
    private var selection: CGRect?

    func cancel() {
        finish(.cancelled)
    }

    func selectRegion() async throws -> CGRect {
        guard gate == nil else {
            throw ScreenCaptureCoordinatorError.alreadyPresenting
        }
        guard !NSScreen.screens.isEmpty else {
            throw ScreenCaptureCoordinatorError.noDisplays
        }

        let gate = CaptureCallbackGate<CGRect>()
        self.gate = gate
        selectionError = nil
        installWindows()
        installEventMonitor()
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKey()
        NSCursor.crosshair.push()
        didPushCursor = true
        defer {
            tearDown()
            selectionError = nil
        }

        let outcome = await gate.value()
        if let selectionError {
            throw selectionError
        }
        switch outcome {
        case let .selected(region):
            return region
        case .cancelled:
            throw CancellationError()
        }
    }

    private func installWindows() {
        windows = NSScreen.screens.map { screen in
            let window = CaptureOverlayWindow(screen: screen)
            let overlay = CaptureOverlayView(screenFrame: screen.frame)
            window.onCancel = { [weak self] in
                self?.finish(.cancelled)
            }
            window.contentView = overlay
            return window
        }
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            self?.route(event) ?? event
        }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            finish(.cancelled)
            return nil
        }

        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            guard windows.contains(where: { $0 === event.window }) else {
                return event
            }
            guard dragStart == nil else {
                return nil
            }
            event.window?.makeKey()
            dragStart = point
            selection = nil
            updateOverlays()
            return event
        case .leftMouseDragged:
            guard let dragStart else { return event }
            selection = CGRect(
                x: min(dragStart.x, point.x),
                y: min(dragStart.y, point.y),
                width: abs(point.x - dragStart.x),
                height: abs(point.y - dragStart.y)
            )
            updateOverlays()
            return nil
        case .leftMouseUp:
            guard dragStart != nil else { return event }
            finishDrag(at: point)
            return nil
        default:
            return event
        }
    }

    private func finishDrag(at point: CGPoint) {
        guard let dragStart else { return }
        guard let region = policy.region(from: dragStart, to: point) else {
            finish(.cancelled, error: .regionTooSmall)
            return
        }
        finish(.selected(region))
    }

    private func finish(
        _ outcome: CaptureCallbackOutcome<CGRect>,
        error: ScreenCaptureCoordinatorError? = nil
    ) {
        guard let gate, gate.resolve(outcome) else {
            return
        }
        selectionError = error
        tearDown()
    }

    private func updateOverlays() {
        for window in windows {
            (window.contentView as? CaptureOverlayView)?.selection = selection
        }
    }

    private func tearDown() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        gate = nil
        dragStart = nil
        selection = nil
    }
}

private final class CaptureOverlayWindow: NSWindow {
    var onCancel: (() -> Void)?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        title = AppText.localized("YumYum Agent 캡처 영역 선택")
        setAccessibilityLabel(AppText.localized("화면 캡처 영역 선택"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class CaptureOverlayView: NSView {
    let screenFrame: CGRect
    var selection: CGRect? {
        didSet { needsDisplay = true }
    }

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppText.localized("드래그하여 캡처할 영역 선택, Escape로 취소"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dimPath = NSBezierPath(rect: bounds)
        if let selection {
            dimPath.appendRect(localRect(for: selection))
            dimPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dimPath.fill()

        if let selection {
            let border = NSBezierPath(rect: localRect(for: selection))
            border.lineWidth = 2
            NSColor.systemOrange.setStroke()
            border.stroke()
        }

        let instruction = AppText.localized("드래그하여 영역 선택 · Esc 취소") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.58),
        ]
        let size = instruction.size(withAttributes: attributes)
        instruction.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 28),
            withAttributes: attributes
        )
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: globalRect.minY - screenFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map(\.uint32Value)
    }
}
