import Foundation

public struct ChatDraftAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let isTemporary: Bool
    public let sourceRect: CGRect?

    public init(
        id: UUID = UUID(),
        url: URL,
        isTemporary: Bool,
        sourceRect: CGRect? = nil
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.isTemporary = isTemporary
        self.sourceRect = sourceRect
    }

    public var displayName: String {
        url.lastPathComponent
    }
}

public enum ChatMessageRole: Equatable, Sendable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: ChatMessageRole
    public var text: String
    public let attachmentNames: [String]
    public var isLoading: Bool

    public init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        attachmentNames: [String] = [],
        isLoading: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachmentNames = attachmentNames
        self.isLoading = isLoading
    }

    public var visibleText: String {
        let attachmentText = attachmentNames.isEmpty
            ? ""
            : AppText.localized(english: "Attachments: \(attachmentNames.joined(separator: ", "))", korean: "첨부: \(attachmentNames.joined(separator: ", "))")
        if text.isEmpty {
            return attachmentText
        }
        if attachmentText.isEmpty {
            return text
        }
        return "\(text)\n\(attachmentText)"
    }
}

public enum ChatBubblePhase: Equatable, Sendable {
    case idle
    case capturing
    case sending(UUID)
    case cancelled
    case failed(String)
}

public enum ChatCaptureOutcome: Equatable, Sendable {
    case attachment(ChatDraftAttachment)
    case cancelled
    case permissionDenied
    case failed(String)
}

public enum ChatBubbleStateError: Error, Equatable, LocalizedError, Sendable {
    case blankDraft
    case busy

    public var errorDescription: String? {
        switch self {
        case .blankDraft:
            AppText.localized("대화 내용을 입력하거나 파일을 선택하세요.")
        case .busy:
            AppText.localized("현재 응답을 기다리는 중입니다.")
        }
    }
}

public struct ChatSubmission: Equatable, Sendable {
    public let id: UUID
    public let input: FeedInput

    public init(id: UUID, input: FeedInput) {
        self.id = id
        self.input = input
    }
}

public struct ChatBubbleState: Sendable {
    public var draftText: String
    public private(set) var draftAttachments: [ChatDraftAttachment]
    public private(set) var messages: [ChatMessage]
    public private(set) var phase: ChatBubblePhase
    private var excludedMessageIDs: Set<UUID>

    public init(
        draftText: String = "",
        draftAttachments: [ChatDraftAttachment] = [],
        messages: [ChatMessage] = [],
        phase: ChatBubblePhase = .idle
    ) {
        self.draftText = draftText
        self.draftAttachments = draftAttachments
        self.messages = messages
        self.phase = phase
        excludedMessageIDs = []
    }

    public mutating func addAttachment(_ attachment: ChatDraftAttachment) {
        guard !draftAttachments.contains(where: { $0.url == attachment.url }) else {
            return
        }
        draftAttachments.append(attachment)
        if case .cancelled = phase {
            phase = .idle
        }
    }

    public var isSending: Bool {
        if case .sending = phase {
            return true
        }
        return false
    }

    @discardableResult
    public mutating func removeAttachment(id: UUID) -> ChatDraftAttachment? {
        guard let index = draftAttachments.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return draftAttachments.remove(at: index)
    }

    public mutating func beginSend(id: UUID = UUID()) throws -> ChatSubmission {
        if case .sending = phase {
            throw ChatBubbleStateError.busy
        }
        if case .capturing = phase {
            throw ChatBubbleStateError.busy
        }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty else {
            throw ChatBubbleStateError.blankDraft
        }

        let attachments = draftAttachments
        let requestText = conversationText(currentUserText: text)
        let input = FeedInput(
            text: requestText,
            currentTurnText: text,
            fileURLs: attachments.map(\.url),
            temporaryFileURLs: Set(
                attachments.lazy.filter(\.isTemporary).map(\.url)
            ),
            cleanupTemporaryFilesAfterSubmit: false,
            sourceRect: attachments.compactMap(\.sourceRect).first
        )
        messages.append(
            ChatMessage(
                role: .user,
                text: text,
                attachmentNames: attachments.map(\.displayName)
            )
        )
        messages.append(
            ChatMessage(role: .assistant, text: "", isLoading: true)
        )
        draftText = ""
        draftAttachments.removeAll()
        phase = .sending(id)
        return ChatSubmission(id: id, input: input)
    }

    public mutating func beginAttachmentMeal(
        _ attachments: [ChatDraftAttachment],
        id: UUID = UUID()
    ) throws -> ChatSubmission {
        if case .sending = phase {
            throw ChatBubbleStateError.busy
        }
        if case .capturing = phase {
            throw ChatBubbleStateError.busy
        }
        guard !attachments.isEmpty else {
            throw ChatBubbleStateError.blankDraft
        }

        var seen: Set<URL> = []
        let uniqueAttachments = attachments.filter { seen.insert($0.url).inserted }
        let input = FeedInput(
            text: conversationText(currentUserText: ""),
            currentTurnText: "",
            fileURLs: uniqueAttachments.map(\.url),
            temporaryFileURLs: Set(
                uniqueAttachments.lazy.filter(\.isTemporary).map(\.url)
            ),
            cleanupTemporaryFilesAfterSubmit: false,
            sourceRect: uniqueAttachments.compactMap(\.sourceRect).first
        )
        messages.append(
            ChatMessage(
                role: .user,
                text: "",
                attachmentNames: uniqueAttachments.map(\.displayName)
            )
        )
        messages.append(
            ChatMessage(role: .assistant, text: "", isLoading: true)
        )
        phase = .sending(id)
        return ChatSubmission(id: id, input: input)
    }

    public mutating func beginTextMeal(
        _ text: String,
        id: UUID = UUID()
    ) throws -> ChatSubmission {
        if case .sending = phase {
            throw ChatBubbleStateError.busy
        }
        if case .capturing = phase {
            throw ChatBubbleStateError.busy
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChatBubbleStateError.blankDraft
        }

        let input = FeedInput(
            text: conversationText(currentUserText: trimmed),
            currentTurnText: trimmed,
            cleanupTemporaryFilesAfterSubmit: false
        )
        messages.append(ChatMessage(role: .user, text: trimmed))
        messages.append(
            ChatMessage(role: .assistant, text: "", isLoading: true)
        )
        phase = .sending(id)
        return ChatSubmission(id: id, input: input)
    }

    public mutating func appendAssistantDelta(
        _ delta: String,
        submissionID: UUID
    ) {
        guard phase == .sending(submissionID),
              !delta.isEmpty,
              let index = messages.lastIndex(where: { $0.role == .assistant }) else {
            return
        }
        messages[index].text.append(delta)
        messages[index].isLoading = false
    }

    public mutating func applyResponseEvent(
        _ event: PromptResponseEvent,
        submissionID: UUID
    ) {
        guard phase == .sending(submissionID) else {
            return
        }
        switch event {
        case let .textDelta(delta):
            appendAssistantDelta(delta, submissionID: submissionID)
        case let .textSnapshot(snapshot):
            guard let index = messages.lastIndex(where: {
                $0.role == .assistant
            }) else {
                return
            }
            messages[index].text = snapshot
            messages[index].isLoading = false
        case let .completed(response):
            completeSend(id: submissionID, response: response.text)
        }
    }

    public mutating func completeSend(id: UUID, response: String) {
        guard phase == .sending(id),
              let index = messages.lastIndex(where: {
                  $0.role == .assistant
              }) else {
            return
        }
        messages[index].text = response
        messages[index].isLoading = false
        includeLatestUserMessageInContext()
        phase = .idle
    }

    public mutating func cancelSend(id: UUID) {
        guard phase == .sending(id) else {
            return
        }
        excludeLatestUserMessageFromContext()
        removeCurrentAssistantMessage()
        phase = .cancelled
    }

    public mutating func failSend(id: UUID, message: String) {
        guard phase == .sending(id) else {
            return
        }
        excludeLatestUserMessageFromContext()
        removeCurrentAssistantMessage()
        phase = .failed(UserFacingErrorRedactor.sanitize(message))
    }

    public mutating func beginRetry(id: UUID) throws {
        if case .sending = phase {
            throw ChatBubbleStateError.busy
        }
        messages.append(
            ChatMessage(role: .assistant, text: "", isLoading: true)
        )
        phase = .sending(id)
    }

    @discardableResult
    public mutating func beginCapture() -> Bool {
        guard !isSending, phase != .capturing else {
            return false
        }
        phase = .capturing
        return true
    }

    public mutating func finishCapture(_ outcome: ChatCaptureOutcome) {
        guard phase == .capturing else {
            return
        }
        switch outcome {
        case let .attachment(attachment):
            addAttachment(attachment)
            phase = .idle
        case .cancelled:
            phase = .idle
        case .permissionDenied:
            phase = .failed(UserFacingErrorCategory.capturePermission.message)
        case .failed:
            phase = .failed(UserFacingErrorCategory.captureFailure.message)
        }
    }

    public mutating func setFailure(_ message: String) {
        phase = .failed(UserFacingErrorRedactor.sanitize(message))
    }

    public mutating func discardDraftAttachments() -> [ChatDraftAttachment] {
        defer { draftAttachments.removeAll() }
        return draftAttachments
    }

    public mutating func removeTemporaryDraftAttachments() -> [ChatDraftAttachment] {
        let temporary = draftAttachments.filter(\.isTemporary)
        draftAttachments.removeAll(where: \.isTemporary)
        return temporary
    }

    public mutating func discardExcludedUserMessages() {
        messages.removeAll {
            $0.role == .user && excludedMessageIDs.remove($0.id) != nil
        }
    }

    public mutating func resetConversation() {
        messages.removeAll()
        excludedMessageIDs.removeAll()
        phase = .idle
    }

    private func conversationText(currentUserText: String) -> String {
        var lines = messages.compactMap { message -> String? in
            guard !message.isLoading,
                  !message.text.isEmpty,
                  !excludedMessageIDs.contains(message.id) else {
                return nil
            }
            switch message.role {
            case .user:
                return "User: \(message.text)"
            case .assistant:
                return "Assistant: \(message.text)"
            }
        }
        let currentText = currentUserText.isEmpty
            ? "Analyze the selected attachments."
            : currentUserText
        lines.append("User: \(currentText)")
        return lines.joined(separator: "\n")
    }


    private mutating func excludeLatestUserMessageFromContext() {
        guard let message = messages.last(where: { $0.role == .user }) else {
            return
        }
        excludedMessageIDs.insert(message.id)
    }

    private mutating func includeLatestUserMessageInContext() {
        guard let message = messages.last(where: { $0.role == .user }) else {
            return
        }
        excludedMessageIDs.remove(message.id)
    }

    private mutating func removeCurrentAssistantMessage() {
        guard let index = messages.lastIndex(where: {
            $0.role == .assistant
        }) else {
            return
        }
        messages.remove(at: index)
    }
}
