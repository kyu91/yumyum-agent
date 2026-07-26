import Combine
import Foundation

@MainActor
public final class ChatBubbleSession: ObservableObject {
    @Published public private(set) var state: ChatBubbleState

    private let submitter: any FeedSubmitting
    private var sendTask: Task<Void, Never>?
    private var activeSubmission: ChatSubmission?
    private var failedSubmission: ChatSubmission?

    public init(
        state: ChatBubbleState = ChatBubbleState(),
        submitter: any FeedSubmitting
    ) {
        self.state = state
        self.submitter = submitter
    }

    public var canRetry: Bool {
        failedSubmission != nil && activeSubmission == nil
    }

    public func setDraftText(_ text: String) {
        state.draftText = text
    }

    public func addAttachment(_ attachment: ChatDraftAttachment) {
        state.addAttachment(attachment)
    }

    public func removeAttachment(id: UUID) {
        guard let attachment = state.removeAttachment(id: id),
              attachment.isTemporary else {
            return
        }
        try? FileManager.default.removeItem(at: attachment.url)
    }

    @discardableResult
    public func beginCapture() -> Bool {
        state.beginCapture()
    }

    public func finishCapture(_ outcome: ChatCaptureOutcome) {
        state.finishCapture(outcome)
    }

    @discardableResult
    public func send(reduceMotion: Bool) -> Bool {
        guard activeSubmission == nil else {
            return false
        }
        let submission: ChatSubmission
        do {
            submission = try state.beginSend()
        } catch ChatBubbleStateError.busy {
            return false
        } catch {
            state.setFailure(error.localizedDescription)
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
        guard activeSubmission == nil,
              let previous = failedSubmission else {
            return false
        }
        let submission = ChatSubmission(id: UUID(), input: previous.input)
        do {
            try state.beginRetry(id: submission.id)
        } catch {
            state.setFailure(error.localizedDescription)
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
        sendTask = nil
        activeSubmission = nil
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

    private func start(_ submission: ChatSubmission, reduceMotion: Bool) {
        activeSubmission = submission
        let submitter = self.submitter
        sendTask = Task { @MainActor [weak self] in
            do {
                let response = try await submitter.submit(
                    submission.input,
                    reduceMotion: reduceMotion
                )
                try Task.checkCancellation()
                guard let self,
                      self.activeSubmission?.id == submission.id else {
                    return
                }
                self.state.completeSend(id: submission.id, response: response.text)
                self.removeTemporaryFiles(for: submission)
                self.finishTask(id: submission.id)
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
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "입력을 보내지 못했습니다."
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
