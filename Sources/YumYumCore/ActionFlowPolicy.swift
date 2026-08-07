import CoreGraphics
import Foundation

public enum ActionBubbleAction: Int, CaseIterable, Equatable, Sendable {
    case capture
    case findFile
    case openChat
    case settings
    case feedClipboard

    public var title: String {
        title(language: AppText.language)
    }

    public func title(language: AppLanguage) -> String {
        switch self {
        case .capture: AppText.localized(english: "Capture", korean: "캡처하기", language: language)
        case .findFile: AppText.localized(english: "Choose Files", korean: "파일 찾기", language: language)
        case .openChat: AppText.localized(english: "Open Chat", korean: "채팅 열기", language: language)
        case .settings: AppText.localized(english: "Settings", korean: "설정", language: language)
        case .feedClipboard: AppText.localized(english: "Add Clipboard to Chat", korean: "클립보드를 채팅에 담기", language: language)
        }
    }

    public var localizedTitle: String { title }

    public var symbolName: String {
        switch self {
        case .capture: "camera.viewfinder"
        case .findFile: "folder"
        case .openChat: "bubble.left.and.bubble.right"
        case .settings: "gearshape"
        case .feedClipboard: "doc.on.clipboard"
        }
    }
}

public enum ActionMenuFocusPolicy {
    public static func firstEnabledIndex(in enabled: [Bool]) -> Int? {
        enabled.firstIndex(of: true)
    }

    public static func rehomedIndex(
        current: Int?,
        enabled: [Bool]
    ) -> Int? {
        if let current,
           enabled.indices.contains(current),
           enabled[current] {
            return current
        }
        return firstEnabledIndex(in: enabled)
    }

    public static func nextEnabledIndex(
        from current: Int,
        delta: Int,
        enabled: [Bool]
    ) -> Int? {
        guard !enabled.isEmpty,
              enabled.contains(true),
              delta != 0 else {
            return rehomedIndex(current: current, enabled: enabled)
        }
        var candidate = enabled.indices.contains(current)
            ? current
            : (firstEnabledIndex(in: enabled) ?? 0)
        for _ in enabled.indices {
            candidate = (candidate + delta % enabled.count + enabled.count)
                % enabled.count
            if enabled[candidate] {
                return candidate
            }
        }
        return nil
    }
}

public struct CallbackGenerationGate: Equatable, Sendable {
    public private(set) var activeGeneration: UUID?

    public init() {}

    @discardableResult
    public mutating func begin(_ generation: UUID) -> Bool {
        guard activeGeneration == nil else { return false }
        activeGeneration = generation
        return true
    }

    @discardableResult
    public mutating func consume(_ generation: UUID) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }

    public mutating func invalidate() {
        activeGeneration = nil
    }
}

public struct ActionMeal: Equatable, Sendable {
    public let fileURLs: [URL]
    public let temporaryFileURLs: Set<URL>
    public let sourceRect: CGRect?

    public init(
        fileURLs: [URL],
        temporaryFileURLs: Set<URL> = [],
        sourceRect: CGRect? = nil
    ) {
        self.fileURLs = fileURLs
        self.temporaryFileURLs = temporaryFileURLs
        self.sourceRect = sourceRect
    }
}

public enum ActionCaptureOutcome: Equatable, Sendable {
    case selected(url: URL, region: CGRect)
    case cancelled
    case permissionDenied
    case failed(String)
}

public enum ActionFileOutcome: Equatable, Sendable {
    case selected([URL])
    case cancelled
}

public enum ActionFlowSurface: Equatable, Sendable {
    case petOnly
    case actionBubble
    case selectingCapture(UUID)
    case selectingFiles(UUID)
    case feeding(UUID)
    case chat
    case response
}

public enum ActionFlowEffect: Equatable, Sendable {
    case showPet
    case showActionBubble
    case hideActionBubble
    case hideAllForCapture
    case beginCapture(UUID)
    case beginFileSelection(UUID)
    case submitMeal(ActionMeal, UUID)
    case showChat(scrollToLatest: Bool)
    case hideChat
    case hideResponseBubble
    case openSettings
}

public struct ActionFlowStateMachine: Equatable, Sendable {
    public private(set) var surface: ActionFlowSurface

    public init(surface: ActionFlowSurface = .petOnly) {
        self.surface = surface
    }

    @discardableResult
    public mutating func openActionBubble() -> [ActionFlowEffect] {
        switch surface {
        case .selectingCapture, .selectingFiles:
            return []
        default:
            surface = .actionBubble
            return [
                .hideResponseBubble,
                .hideChat,
                .showPet,
                .showActionBubble,
            ]
        }
    }

    public mutating func dismissActionBubble() -> [ActionFlowEffect] {
        guard surface == .actionBubble else { return [] }
        surface = .petOnly
        return [.hideActionBubble, .showPet]
    }

    public mutating func select(
        _ action: ActionBubbleAction,
        generation: UUID = UUID()
    ) -> [ActionFlowEffect] {
        guard surface == .actionBubble else { return [] }
        switch action {
        case .capture:
            surface = .selectingCapture(generation)
            return [.hideAllForCapture, .beginCapture(generation)]
        case .findFile:
            surface = .selectingFiles(generation)
            return [.hideActionBubble, .beginFileSelection(generation)]
        case .openChat:
            surface = .chat
            return [.hideActionBubble, .showChat(scrollToLatest: false)]
        case .settings:
            surface = .petOnly
            return [.hideActionBubble, .showPet, .openSettings]
        case .feedClipboard:
            surface = .petOnly
            return [.hideActionBubble, .showPet]
        }
    }

    public mutating func finishCapture(
        _ outcome: ActionCaptureOutcome,
        generation: UUID
    ) -> [ActionFlowEffect] {
        guard surface == .selectingCapture(generation) else { return [] }
        switch outcome {
        case let .selected(url, region):
            surface = .feeding(generation)
            return [
                .showPet,
                .submitMeal(
                    ActionMeal(
                        fileURLs: [url],
                        temporaryFileURLs: [url],
                        sourceRect: region
                    ),
                    generation
                ),
            ]
        case .cancelled, .permissionDenied, .failed:
            surface = .petOnly
            return [.showPet]
        }
    }

    public mutating func finishFiles(
        _ outcome: ActionFileOutcome,
        generation: UUID
    ) -> [ActionFlowEffect] {
        guard surface == .selectingFiles(generation) else { return [] }
        switch outcome {
        case let .selected(urls) where !urls.isEmpty:
            surface = .feeding(generation)
            return [
                .showPet,
                .submitMeal(ActionMeal(fileURLs: urls), generation),
            ]
        case .selected, .cancelled:
            surface = .petOnly
            return [.showPet]
        }
    }

    public mutating func showResponse() {
        surface = .response
    }

    public mutating func showChat() {
        surface = .chat
    }

    public mutating func responseClicked() -> [ActionFlowEffect] {
        guard surface == .response else { return [] }
        surface = .chat
        return [
            .hideResponseBubble,
            .showChat(scrollToLatest: true),
        ]
    }

    public mutating func hideChat() -> [ActionFlowEffect] {
        guard surface == .chat else { return [] }
        surface = .petOnly
        return [.hideChat, .showPet]
    }

    public mutating func returnToPet() {
        surface = .petOnly
    }
}

public struct FeedFlightKeyframe: Equatable, Sendable {
    public let milliseconds: Int
    public let frame: CGRect
    public let alpha: CGFloat

    public init(milliseconds: Int, frame: CGRect, alpha: CGFloat) {
        self.milliseconds = milliseconds
        self.frame = frame
        self.alpha = alpha
    }
}

public struct FeedPreviewFlightPolicy: Equatable, Sendable {
    public static let maximumPreviewSize = CGSize(width: 176, height: 110)

    public init() {}

    public func aspectFitSize(for contentSize: CGSize) -> CGSize {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return CGSize(width: 64, height: 48)
        }
        let scale = min(
            1,
            Self.maximumPreviewSize.width / contentSize.width,
            Self.maximumPreviewSize.height / contentSize.height
        )
        return CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )
    }

    public func keyframes(
        contentSize: CGSize,
        sourceRect: CGRect,
        targetRect: CGRect,
        reduceMotion: Bool
    ) -> [FeedFlightKeyframe] {
        let previewSize = aspectFitSize(for: contentSize)
        let initialFrame = CGRect(
            x: sourceRect.midX - previewSize.width / 2,
            y: sourceRect.midY - previewSize.height / 2,
            width: previewSize.width,
            height: previewSize.height
        )
        if reduceMotion {
            return [
                FeedFlightKeyframe(milliseconds: 0, frame: initialFrame, alpha: 1),
                FeedFlightKeyframe(milliseconds: 100, frame: initialFrame, alpha: 0),
            ]
        }

        let risenSize = CGSize(
            width: previewSize.width * 0.88,
            height: previewSize.height * 0.88
        )
        let risenFrame = CGRect(
            x: sourceRect.midX - risenSize.width / 2,
            y: sourceRect.midY + 6 - risenSize.height / 2,
            width: risenSize.width,
            height: risenSize.height
        )
        return [
            FeedFlightKeyframe(milliseconds: 0, frame: initialFrame, alpha: 1),
            FeedFlightKeyframe(milliseconds: 100, frame: risenFrame, alpha: 1),
            FeedFlightKeyframe(milliseconds: 420, frame: targetRect, alpha: 0.08),
        ]
    }
}

public enum PetMouthPose: Equatable, Sendable {
    case closed
    case open
    case halfClosed
}

public struct PetChewFrame: Equatable, Sendable {
    public let mouth: PetMouthPose
    public let bodyScaleX: CGFloat
    public let bodyScaleY: CGFloat
    public let bodyOffsetY: CGFloat
    public let cheekOffset: CGFloat

    public init(
        mouth: PetMouthPose,
        bodyScaleX: CGFloat,
        bodyScaleY: CGFloat,
        bodyOffsetY: CGFloat,
        cheekOffset: CGFloat
    ) {
        self.mouth = mouth
        self.bodyScaleX = bodyScaleX
        self.bodyScaleY = bodyScaleY
        self.bodyOffsetY = bodyOffsetY
        self.cheekOffset = cheekOffset
    }

    public static let resting = PetChewFrame(
        mouth: .closed,
        bodyScaleX: 1,
        bodyScaleY: 1,
        bodyOffsetY: 0,
        cheekOffset: 0
    )
    public static let mouthOpen = PetChewFrame(
        mouth: .open,
        bodyScaleX: 0.985,
        bodyScaleY: 1.025,
        bodyOffsetY: -2,
        cheekOffset: -1
    )
    public static let mouthClosedChew = PetChewFrame(
        mouth: .closed,
        bodyScaleX: 1.035,
        bodyScaleY: 0.955,
        bodyOffsetY: 2,
        cheekOffset: 3
    )
    public static let reducedMotion = PetChewFrame(
        mouth: .halfClosed,
        bodyScaleX: 1,
        bodyScaleY: 1,
        bodyOffsetY: 0,
        cheekOffset: 0
    )
}

public struct ThinkingAnimationPolicy: Equatable, Sendable {
    public static let cycleMilliseconds = 900

    public init() {}

    public var resetFrame: PetChewFrame { .resting }

    public func showsExternalBubble(
        isThinking: Bool,
        isChatVisible: Bool
    ) -> Bool {
        isThinking && !isChatVisible
    }

    public func frame(at milliseconds: Int, reduceMotion: Bool) -> PetChewFrame {
        guard !reduceMotion else { return .reducedMotion }
        let phase = normalizedPhase(milliseconds)
        switch phase {
        case 0..<150, 300..<450, 600..<750:
            return .mouthOpen
        default:
            return .mouthClosedChew
        }
    }

    public func thought(at milliseconds: Int, reduceMotion: Bool) -> String {
        guard !reduceMotion else { return "Yum..." }
        switch normalizedPhase(milliseconds) {
        case 0..<300: return "Yum."
        case 300..<600: return "Yum.."
        default: return "Yum..."
        }
    }

    private func normalizedPhase(_ milliseconds: Int) -> Int {
        let remainder = milliseconds % Self.cycleMilliseconds
        return remainder >= 0 ? remainder : remainder + Self.cycleMilliseconds
    }
}

public struct PetResponseContent: Equatable, Sendable {
    private let storedFullText: String
    private let storedDisplayText: String
    public let errorCategory: UserFacingErrorCategory?
    public var fullText: String { fullText(language: AppText.language) }
    public var displayText: String { displayText(language: AppText.language) }
    public func fullText(language: AppLanguage) -> String {
        errorCategory?.message(language: language) ?? storedFullText
    }
    public func displayText(language: AppLanguage) -> String {
        errorCategory?.message(language: language) ?? storedDisplayText
    }
    public let isExcerpt: Bool
    public let showsOpenChat: Bool
    public let showsRetry: Bool
    public let isError: Bool

    public init(
        fullText: String,
        displayText: String,
        isExcerpt: Bool,
        showsOpenChat: Bool,
        showsRetry: Bool = false,
        isError: Bool = false,
        errorCategory: UserFacingErrorCategory? = nil
    ) {
        storedFullText = fullText
        storedDisplayText = displayText
        self.errorCategory = errorCategory
        self.isExcerpt = isExcerpt
        self.showsOpenChat = showsOpenChat
        self.showsRetry = showsRetry
        self.isError = isError
    }
}

public enum PetResponsePolicy {
    public static func content(for response: String) -> PetResponseContent {
        return PetResponseContent(
            fullText: response,
            displayText: response,
            isExcerpt: false,
            showsOpenChat: false
        )
    }

    public static func error(message: String) -> PetResponseContent {
        let category = UserFacingErrorRedactor.category(forSafeMessage: message)
        let safeMessage = category.message
        return PetResponseContent(
            fullText: safeMessage,
            displayText: safeMessage,
            isExcerpt: false,
            showsOpenChat: true,
            showsRetry: true,
            isError: true,
            errorCategory: category
        )
    }
}

public struct FeedStatusUpdate: Equatable, Sendable {
    public let generation: UUID
    public let status: FeedStatus

    public init(generation: UUID, status: FeedStatus) {
        self.generation = generation
        self.status = status
    }
}

public struct FeedStatusGenerationGate: Equatable, Sendable {
    public static let retainedGenerationLimit = 32

    public private(set) var activeGeneration: UUID?
    public private(set) var status: FeedStatus
    private var retiredGenerations: [UUID]

    public var retiredGenerationCount: Int { retiredGenerations.count }

    public init() {
        activeGeneration = nil
        status = .idle
        retiredGenerations = []
    }

    @discardableResult
    public mutating func apply(_ update: FeedStatusUpdate) -> Bool {
        if update.status == .validating {
            guard !retiredGenerations.contains(update.generation) else {
                return false
            }
            if let activeGeneration,
               activeGeneration != update.generation {
                retire(activeGeneration)
            }
            activeGeneration = update.generation
            status = update.status
            return true
        }
        guard activeGeneration == update.generation else { return false }
        status = update.status
        return true
    }

    public mutating func invalidate() {
        if let activeGeneration {
            retire(activeGeneration)
        }
        activeGeneration = nil
        status = .idle
    }

    private mutating func retire(_ generation: UUID) {
        guard !retiredGenerations.contains(generation) else { return }
        retiredGenerations.append(generation)
        if retiredGenerations.count > Self.retainedGenerationLimit {
            retiredGenerations.removeFirst(
                retiredGenerations.count - Self.retainedGenerationLimit
            )
        }
    }
}
