import Combine
import Foundation

@MainActor
public final class ChatBubbleSession: ObservableObject {
    @Published public private(set) var state: ChatBubbleState
    @Published public private(set) var isPresented: Bool
    @Published public private(set) var isRestarting = false

    private let submitter: any FeedSubmitting
    private var sendTask: Task<Void, Never>?
    private var activeSubmission: ChatSubmission?
    private var failedSubmission: ChatSubmission?

    public init(
        state: ChatBubbleState = ChatBubbleState(),
        submitter: any FeedSubmitting
    ) {
        self.state = state
        isPresented = false
        self.submitter = submitter
    }

    public var canRetry: Bool {
        failedSubmission != nil && activeSubmission == nil
    }

    public var canRestart: Bool {
        activeSubmission == nil && state.phase != .capturing && !isRestarting
    }

    public func show() {
        isPresented = true
    }

    public func hide() {
        isPresented = false
    }

    public func setDraftText(_ text: String) {
        guard !isRestarting else { return }
        state.draftText = text
    }

    public func addAttachment(_ attachment: ChatDraftAttachment) {
        guard !isRestarting else { return }
        state.addAttachment(attachment)
    }

    public func removeAttachment(id: UUID) {
        guard !isRestarting else { return }
        guard let attachment = state.removeAttachment(id: id),
              attachment.isTemporary else {
            return
        }
        try? FileManager.default.removeItem(at: attachment.url)
    }

    @discardableResult
    public func beginCapture() -> Bool {
        guard !isRestarting else { return false }
        return state.beginCapture()
    }

    @discardableResult
    public func restartSession(
        reset: @escaping @Sendable () async -> Bool
    ) -> Bool {
        guard canRestart else { return false }
        isRestarting = true
        Task { @MainActor [weak self] in
            let didReset = await reset()
            guard let self, self.isRestarting else { return }
            if didReset {
                self.removeFailedSubmission()
                self.state.resetConversation()
            }
            self.isRestarting = false
        }
        return true
    }

    public func finishCapture(_ outcome: ChatCaptureOutcome) {
        state.finishCapture(outcome)
    }

    @discardableResult
    public func send(reduceMotion: Bool) -> Bool {
        guard activeSubmission == nil, !isRestarting else {
            return false
        }
        let submission: ChatSubmission
        do {
            submission = try state.beginSend()
        } catch ChatBubbleStateError.busy {
            return false
        } catch {
            state.setFailure(UserFacingErrorRedactor.message(for: error))
            return false
        }
        state.discardExcludedUserMessages()
        if let failedSubmission {
            removeTemporaryFiles(for: failedSubmission)
        }
        failedSubmission = nil
        start(submission, reduceMotion: reduceMotion)
        return true
    }

    @discardableResult
    public func feedAttachments(
        _ attachments: [ChatDraftAttachment],
        reduceMotion: Bool
    ) -> Bool {
        guard activeSubmission == nil, !isRestarting else {
            return false
        }
        let submission: ChatSubmission
        do {
            submission = try state.beginAttachmentMeal(attachments)
        } catch ChatBubbleStateError.busy {
            return false
        } catch {
            state.setFailure(UserFacingErrorRedactor.message(for: error))
            return false
        }
        state.discardExcludedUserMessages()
        if let failedSubmission {
            removeTemporaryFiles(for: failedSubmission)
        }
        failedSubmission = nil
        start(submission, reduceMotion: reduceMotion)
        return true
    }

    @discardableResult
    public func retry(reduceMotion: Bool) -> Bool {
        guard activeSubmission == nil, !isRestarting,
              let previous = failedSubmission else {
            return false
        }
        let submission = ChatSubmission(id: UUID(), input: previous.input)
        do {
            try state.beginRetry(id: submission.id)
        } catch {
            state.setFailure(UserFacingErrorRedactor.message(for: error))
            return false
        }
        failedSubmission = nil
        start(submission, reduceMotion: reduceMotion)
        return true
    }

    public func cancelSend() {
        guard let submission = activeSubmission else {
            return
        }
        sendTask?.cancel()
        failedSubmission = nil
        state.cancelSend(id: submission.id)
        removeTemporaryFiles(for: submission)
    }

    public func discardDraftAndCancel() {
        cancelSend()
        removeFailedSubmission()
        state.discardExcludedUserMessages()
        for attachment in state.discardDraftAttachments() where attachment.isTemporary {
            try? FileManager.default.removeItem(at: attachment.url)
        }
    }

    public func cancelAndCleanupTemporaryFiles() {
        cancelSend()
        removeFailedSubmission()
        state.discardExcludedUserMessages()
        for attachment in state.removeTemporaryDraftAttachments() {
            try? FileManager.default.removeItem(at: attachment.url)
        }
    }

    private func removeFailedSubmission() {
        if let failedSubmission {
            removeTemporaryFiles(for: failedSubmission)
            self.failedSubmission = nil
        }
    }

    public func waitForCurrentSend() async {
        let task = sendTask
        await task?.value
    }

    public func waitForRestart() async {
        while isRestarting {
            await Task.yield()
        }
    }

    private func start(_ submission: ChatSubmission, reduceMotion: Bool) {
        activeSubmission = submission
        let submitter = self.submitter
        sendTask = Task { @MainActor [weak self] in
            do {
                let events = submitter.submitEvents(
                    submission.input,
                    reduceMotion: reduceMotion
                )
                for try await event in events {
                    try Task.checkCancellation()
                    guard let self,
                          self.activeSubmission?.id == submission.id else {
                        return
                    }
                    if case .completed = event {
                        self.removeTemporaryFiles(for: submission)
                        self.finishTask(id: submission.id)
                        self.state.applyResponseEvent(
                            event,
                            submissionID: submission.id
                        )
                        return
                    }
                    self.state.applyResponseEvent(
                        event,
                        submissionID: submission.id
                    )
                }
                try Task.checkCancellation()
                throw AgentConnectorError.emptyResponse
            } catch is CancellationError {
                guard let self,
                      self.activeSubmission?.id == submission.id else {
                    return
                }
                self.state.cancelSend(id: submission.id)
                self.removeTemporaryFiles(for: submission)
                self.finishTask(id: submission.id)
            } catch {
                guard let self,
                      self.activeSubmission?.id == submission.id else {
                    return
                }
                if Task.isCancelled {
                    self.state.cancelSend(id: submission.id)
                    self.removeTemporaryFiles(for: submission)
                    self.finishTask(id: submission.id)
                    return
                }
                let message = UserFacingErrorRedactor.message(for: error)
                self.failedSubmission = submission
                self.finishTask(id: submission.id, preserveFailure: true)
                self.state.failSend(id: submission.id, message: message)
            }
        }
    }

    private func finishTask(id: UUID, preserveFailure: Bool = false) {
        guard activeSubmission?.id == id else {
            return
        }
        activeSubmission = nil
        sendTask = nil
        if !preserveFailure {
            failedSubmission = nil
        }
    }

    private func removeTemporaryFiles(for submission: ChatSubmission) {
        for url in submission.input.temporaryFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
