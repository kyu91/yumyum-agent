import Foundation
import Testing
@testable import YumYumCore

@Suite
struct ChatBubbleStateTests {
    @Test
    func attachmentsAddedInsideChatRemainDraftsUntilTheUserSends() {
        var state = ChatBubbleState()
        let capture = ChatDraftAttachment(
            id: UUID(),
            url: URL(fileURLWithPath: "/private/tmp/YumYum-Capture-private.png"),
            isTemporary: true
        )
        let document = ChatDraftAttachment(
            id: UUID(),
            url: URL(fileURLWithPath: "/Users/person/private/report.pdf"),
            isTemporary: false
        )

        state.addAttachment(capture)
        state.addAttachment(document)

        #expect(state.messages.isEmpty)
        #expect(state.draftAttachments == [capture, document])

        state.removeAttachment(id: capture.id)
        #expect(state.draftAttachments == [document])
    }

    @Test
    func sendAddsUserThenLoadingAssistantAndCompletionPreservesOrderingWithoutVisiblePaths() throws {
        var state = ChatBubbleState()
        state.draftText = "이 문서를 요약해줘"
        state.addAttachment(
            ChatDraftAttachment(
                id: UUID(),
                url: URL(fileURLWithPath: "/Users/person/Secret Folder/report.pdf"),
                isTemporary: false
            )
        )

        let submission = try state.beginSend(id: UUID())

        #expect(state.phase == .sending(submission.id))
        #expect(state.draftText.isEmpty)
        #expect(state.draftAttachments.isEmpty)
        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages[0].text == "이 문서를 요약해줘")
        #expect(state.messages[0].attachmentNames == ["report.pdf"])
        #expect(!state.messages[0].visibleText.contains("/Users/"))
        #expect(state.messages[1].isLoading)

        state.completeSend(id: submission.id, response: "요약 결과")

        #expect(state.phase == .idle)
        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages[1].text == "요약 결과")
        #expect(!state.messages[1].isLoading)
    }

    @Test
    func assistantDeltaUpdatesOnlyTheCurrentSubmission() throws {
        var state = ChatBubbleState()
        state.draftText = "질문"
        let submission = try state.beginSend(id: UUID())

        state.appendAssistantDelta("무시할 응답", submissionID: UUID())

        #expect(state.messages[1].text.isEmpty)
        #expect(state.messages[1].isLoading)

        state.appendAssistantDelta("부분 응답", submissionID: submission.id)

        #expect(state.messages[1].text == "부분 응답")
        #expect(!state.messages[1].isLoading)
        #expect(state.phase == .sending(submission.id))
    }

    @Test
    func responseEventsFinalizeTheSameAssistantRowAndPhase() throws {
        var state = ChatBubbleState()
        state.draftText = "질문"
        let submission = try state.beginSend(id: UUID())
        let assistantID = state.messages[1].id

        state.applyResponseEvent(
            .textDelta("부분"),
            submissionID: submission.id
        )
        state.applyResponseEvent(
            .textSnapshot("교정된 부분"),
            submissionID: submission.id
        )
        state.applyResponseEvent(
            .textDelta(" 응답"),
            submissionID: submission.id
        )

        #expect(state.messages[1].id == assistantID)
        #expect(state.messages[1].text == "교정된 부분 응답")
        #expect(!state.messages[1].isLoading)
        #expect(state.phase == .sending(submission.id))

        state.applyResponseEvent(
            .completed(PromptResponse(text: "최종 응답")),
            submissionID: submission.id
        )

        #expect(state.messages.count == 2)
        #expect(state.messages[1].id == assistantID)
        #expect(state.messages[1].text == "최종 응답")
        #expect(!state.messages[1].isLoading)
        #expect(state.phase == .idle)
    }

    @Test
    func responseEventsForCompletedOrCancelledSubmissionsAreIgnored() throws {
        var state = ChatBubbleState()
        state.draftText = "완료할 질문"
        let completed = try state.beginSend(id: UUID())
        state.applyResponseEvent(
            .completed(PromptResponse(text: "완료된 응답")),
            submissionID: completed.id
        )

        state.applyResponseEvent(
            .textDelta(" 늦은 변경"),
            submissionID: completed.id
        )
        #expect(state.messages.last?.text == "완료된 응답")

        state.draftText = "취소할 질문"
        let cancelled = try state.beginSend(id: UUID())
        state.applyResponseEvent(
            .textSnapshot("이전 요청의 늦은 응답"),
            submissionID: completed.id
        )
        #expect(state.messages.last?.text.isEmpty == true)
        #expect(state.messages.last?.isLoading == true)

        state.cancelSend(id: cancelled.id)
        let messagesAfterCancellation = state.messages
        state.applyResponseEvent(
            .textDelta("취소 후 늦은 변경"),
            submissionID: cancelled.id
        )
        state.applyResponseEvent(
            .completed(PromptResponse(text: "취소 후 늦은 완료")),
            submissionID: cancelled.id
        )

        #expect(state.phase == .cancelled)
        #expect(state.messages == messagesAfterCancellation)
    }

    @Test
    func followUpSubmissionIncludesConversationTextContextButNoAttachmentPath() throws {
        var state = ChatBubbleState()
        state.draftText = "첫 질문"
        state.addAttachment(
            ChatDraftAttachment(
                id: UUID(),
                url: URL(fileURLWithPath: "/private/tmp/hidden.png"),
                isTemporary: true
            )
        )
        let first = try state.beginSend(id: UUID())
        #expect(first.input.currentTurnText == "첫 질문")
        state.completeSend(id: first.id, response: "첫 답변")

        state.draftText = "후속 질문"
        let followUp = try state.beginSend(id: UUID())

        #expect(followUp.input.text.contains("User: 첫 질문"))
        #expect(followUp.input.text.contains("Assistant: 첫 답변"))
        #expect(followUp.input.text.hasSuffix("User: 후속 질문"))
        #expect(followUp.input.currentTurnText == "후속 질문")
        #expect(!followUp.input.text.contains("/private/tmp"))
        #expect(state.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test
    func cancellingRemovesOnlyTheLoadingAssistantAndLeavesARecoverableDraftState() throws {
        var state = ChatBubbleState()
        state.draftText = "오래 걸리는 요청"
        let submission = try state.beginSend(id: UUID())

        state.cancelSend(id: submission.id)

        #expect(state.phase == .cancelled)
        #expect(state.messages.map(\.role) == [.user])
        #expect(state.messages[0].text == "오래 걸리는 요청")

        state.draftText = "다시 질문"
        let next = try state.beginSend(id: UUID())
        #expect(state.phase == .sending(next.id))
        #expect(state.messages.map(\.role) == [.user, .user, .assistant])
        #expect(!next.input.text.contains("오래 걸리는 요청"))
    }

    @Test
    func captureCancelPermissionAndFailureAllReturnToTheExistingChat() {
        let draftAttachment = ChatDraftAttachment(
            url: URL(fileURLWithPath: "/private/tmp/YumYum-Capture-draft.png"),
            isTemporary: true
        )
        var state = ChatBubbleState(
            draftText: "작성 중인 질문",
            draftAttachments: [draftAttachment],
            messages: [ChatMessage(role: .assistant, text: "기존 답변")]
        )

        let beganCancelledCapture = state.beginCapture()
        #expect(beganCancelledCapture)
        state.finishCapture(.cancelled)
        #expect(state.phase == .idle)
        #expect(state.messages.map(\.text) == ["기존 답변"])

        let beganDeniedCapture = state.beginCapture()
        #expect(beganDeniedCapture)
        state.finishCapture(.permissionDenied)
        #expect(state.phase == .failed("화면 캡처 권한이 필요합니다."))
        #expect(state.messages.map(\.text) == ["기존 답변"])

        let beganFailedCapture = state.beginCapture()
        #expect(beganFailedCapture)
        state.finishCapture(.failed("디스플레이 캡처 실패"))
        #expect(
            state.phase
                == .failed("화면을 캡처하지 못했습니다. 다시 시도해 주세요.")
        )
        #expect(state.messages.map(\.text) == ["기존 답변"])
        #expect(state.draftText == "작성 중인 질문")
        #expect(state.draftAttachments == [draftAttachment])
    }
}

@Suite
struct ChatBubbleSessionTests {
    @Test
    @MainActor
    func emptySendIsRejectedWithoutStartingProductionTask() async {
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText(" \n ")

        #expect(!session.send(reduceMotion: true))
        #expect(await submitter.submissionCount == 0)
        #expect(!session.state.isSending)
    }

    @Test
    @MainActor
    func visibleDraftAttachmentAndTextAreSubmittedExactlyOnceWithoutPathInContext() async {
        let submitter = ControlledFeedSubmitter()
        let attachment = ChatDraftAttachment(
            url: URL(fileURLWithPath: "/private/tmp/secret-report.pdf"),
            isTemporary: false
        )
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("첨부 확인")
        session.addAttachment(attachment)

        #expect(session.send(reduceMotion: false))
        #expect(!session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(1)

        let input = await submitter.inputs[0]
        #expect(input.fileURLs == [attachment.url])
        #expect(input.text.contains("첨부 확인"))
        #expect(!input.text.contains("/private/"))
        await submitter.succeed(at: 0, text: "완료")
        await session.waitForCurrentSend()
    }

    @Test
    @MainActor
    func duplicateSendDoesNotReplaceTheActiveGenerationOrCreateAnotherPrompt() async {
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("한 번만 전송")

        session.send(reduceMotion: true)
        session.send(reduceMotion: true)
        await submitter.waitForSubmissionCount(1)

        #expect(session.state.isSending)
        #expect(session.state.messages.map(\.role) == [.user, .assistant])
        #expect(session.state.messages.last?.isLoading == true)
        #expect(await submitter.submissionCount == 1)

        await submitter.succeed(at: 0, text: "완료")
        await session.waitForCurrentSend()
        #expect(session.state.phase == .idle)
        #expect(session.state.messages.map(\.text) == ["한 번만 전송", "완료"])
    }

    @Test
    @MainActor
    func cancelRejectsImmediateResendUntilThePriorTaskFinishesWithoutAnOrphan() async {
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("첫 요청")
        session.send(reduceMotion: false)
        await submitter.waitForSubmissionCount(1)

        session.cancelSend()
        session.setDraftText("두 번째 요청")
        let immediateResendAccepted = session.send(reduceMotion: false)

        #expect(!immediateResendAccepted)
        #expect(await submitter.submissionCount == 1)
        #expect(session.state.messages.map(\.text) == ["첫 요청"])
        #expect(session.state.draftText == "두 번째 요청")

        await submitter.fail(at: 0, error: CancellationError())
        await session.waitForCurrentSend()

        #expect(session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(2)
        #expect(!(await submitter.inputs[1].text).contains("첫 요청"))
        await submitter.succeed(at: 1, text: "새 응답")
        await session.waitForCurrentSend()

        #expect(session.state.phase == .idle)
        #expect(session.state.messages.last?.text == "새 응답")
        #expect(!session.canRetry)
    }

    @Test
    @MainActor
    func cancelledLateSuccessNeverAppearsBeforeTheNextSend() async {
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("취소할 요청")
        session.send(reduceMotion: false)
        await submitter.waitForSubmissionCount(1)

        session.cancelSend()
        session.setDraftText("유효한 요청")

        await submitter.succeed(at: 0, text: "무시할 응답")
        await session.waitForCurrentSend()
        #expect(!session.state.messages.contains(where: { $0.text == "무시할 응답" }))

        #expect(session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(2)
        await submitter.succeed(at: 1, text: "최신 응답")
        await session.waitForCurrentSend()
        #expect(session.state.phase == .idle)
        #expect(session.state.messages.last?.text == "최신 응답")
        #expect(!session.canRetry)
    }

    @Test
    @MainActor
    func cancellingActiveSendDeletesItsTemporaryAttachmentBeforeLateCompletion() async throws {
        let temporaryImage = try makeTemporaryCapture()
        defer { try? FileManager.default.removeItem(at: temporaryImage) }
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.addAttachment(
            ChatDraftAttachment(url: temporaryImage, isTemporary: true)
        )
        session.send(reduceMotion: false)
        await submitter.waitForSubmissionCount(1)

        session.cancelSend()

        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
        #expect(!session.canRetry)
        await submitter.succeed(at: 0, text: "늦은 응답")
    }

    @Test
    @MainActor
    func aNewSendReleasesThePreviousFailedRetryAttachment() async throws {
        let temporaryImage = try makeTemporaryCapture()
        defer { try? FileManager.default.removeItem(at: temporaryImage) }
        let submitter = ScriptedFeedSubmitter(results: [
            .failure(TestSendError.retryable),
            .success(PromptResponse(text: "새 요청 성공")),
        ])
        let session = ChatBubbleSession(submitter: submitter)
        session.addAttachment(
            ChatDraftAttachment(url: temporaryImage, isTemporary: true)
        )
        session.send(reduceMotion: false)
        await session.waitForCurrentSend()
        #expect(FileManager.default.fileExists(atPath: temporaryImage.path))

        session.setDraftText("새 요청")
        session.send(reduceMotion: false)
        await session.waitForCurrentSend()

        #expect(session.state.phase == .idle)
        #expect(!session.canRetry)
        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
        #expect(session.state.messages.filter { $0.role == .user }.map(\.text) == ["새 요청"])
    }

    @Test
    @MainActor
    func failedTemporaryAttachmentSurvivesRetryAndIsDeletedAfterSuccess() async throws {
        let temporaryImage = try makeTemporaryCapture()
        defer { try? FileManager.default.removeItem(at: temporaryImage) }
        let submitter = ScriptedFeedSubmitter(results: [
            .failure(TestSendError.retryable),
            .success(PromptResponse(text: "재시도 성공")),
        ])
        let session = ChatBubbleSession(submitter: submitter)
        session.addAttachment(
            ChatDraftAttachment(url: temporaryImage, isTemporary: true)
        )

        session.send(reduceMotion: true)
        await session.waitForCurrentSend()

        #expect(session.canRetry)
        #expect(FileManager.default.fileExists(atPath: temporaryImage.path))

        session.retry(reduceMotion: true)
        await session.waitForCurrentSend()

        #expect(session.state.phase == .idle)
        #expect(!session.canRetry)
        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
        let submittedInputs = await submitter.inputs
        #expect(submittedInputs.count == 2)
        #expect(submittedInputs[0].fileURLs == submittedInputs[1].fileURLs)
    }

    @Test
    @MainActor
    func discardingAfterFailureDeletesRetryOwnedTemporaryAttachment() async throws {
        let temporaryImage = try makeTemporaryCapture()
        defer { try? FileManager.default.removeItem(at: temporaryImage) }
        let submitter = ScriptedFeedSubmitter(results: [
            .failure(TestSendError.retryable),
        ])
        let session = ChatBubbleSession(submitter: submitter)
        session.addAttachment(
            ChatDraftAttachment(url: temporaryImage, isTemporary: true)
        )
        session.send(reduceMotion: false)
        await session.waitForCurrentSend()
        #expect(FileManager.default.fileExists(atPath: temporaryImage.path))

        session.discardDraftAndCancel()

        #expect(!session.canRetry)
        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
    }

    @Test
    @MainActor
    func storesAndCancelsTheActiveSendTask() async {
        let submitter = CancellableFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("취소할 요청")

        session.send(reduceMotion: true)
        await submitter.waitUntilStarted()
        #expect(session.state.isSending)

        session.cancelSend()
        await submitter.waitUntilCancelled()

        #expect(session.state.phase == .cancelled)
        #expect(session.state.messages.map(\.role) == [.user])
    }

    @Test
    @MainActor
    func unavailableSelectedAgentBecomesRetryableWithoutFallback() async {
        let submitter = ImmediateFeedSubmitter(
            result: .failure(AgentSelectionError.explicitReselectionRequired)
        )
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("질문")

        session.send(reduceMotion: false)
        await session.waitForCurrentSend()

        #expect(
            session.state.phase
                == .failed("선택한 에이전트를 사용할 수 없어 명시적으로 다시 선택해야 합니다.")
        )
        #expect(session.canRetry)
        #expect(await submitter.inputs.count == 1)
    }

    @Test
    @MainActor
    func rawSubmitterErrorNeverEntersChatState() async {
        let submitter = ImmediateFeedSubmitter(
            result: .failure(
                SensitiveSubmitError(
                    "stderr: token=TEST_ONLY at /Users/example/private/tool"
                )
            )
        )
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("질문")

        session.send(reduceMotion: false)
        await session.waitForCurrentSend()

        #expect(
            session.state.phase
                == .failed("입력을 처리하지 못했습니다. 다시 시도해 주세요.")
        )
    }

    @Test
    @MainActor
    func hidingChatDoesNotCancelAnActiveBackgroundSend() async {
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.show()
        session.setDraftText("백그라운드에서 계속")
        session.send(reduceMotion: false)
        await submitter.waitForSubmissionCount(1)

        session.hide()

        #expect(!session.isPresented)
        #expect(session.state.isSending)
        #expect(await submitter.submissionCount == 1)

        await submitter.succeed(at: 0, text: "숨겨진 동안 완료")
        await session.waitForCurrentSend()
        #expect(session.state.messages.last?.text == "숨겨진 동안 완료")
    }

    @Test
    @MainActor
    func immediateAttachmentMealPreservesChatDraftAndSubmitsTheSelectionOnce() async {
        let submitter = ControlledFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        let sourceRect = CGRect(x: -200, y: 80, width: 320, height: 180)
        let attachments = [
            ChatDraftAttachment(
                url: URL(fileURLWithPath: "/private/tmp/capture.png"),
                isTemporary: true,
                sourceRect: sourceRect
            ),
            ChatDraftAttachment(
                url: URL(fileURLWithPath: "/Users/person/report.pdf"),
                isTemporary: false
            ),
        ]
        session.setDraftText("보존할 채팅 초안")

        #expect(session.feedAttachments(attachments, reduceMotion: false))
        #expect(!session.feedAttachments(attachments, reduceMotion: false))
        await submitter.waitForSubmissionCount(1)

        let inputs = await submitter.inputs
        #expect(inputs.count == 1)
        #expect(inputs[0].fileURLs == attachments.map(\.url))
        #expect(inputs[0].sourceRect == sourceRect)
        #expect(session.state.draftText == "보존할 채팅 초안")

        await submitter.succeed(at: 0, text: "처리 완료")
        await session.waitForCurrentSend()
    }

    @Test
    @MainActor
    func streamFailureRemovesPartialAssistantContentFromFollowUpContext() async {
        let submitter = ControlledEventFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("실패할 질문")
        #expect(session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(1)

        await submitter.yield(.textDelta("실패 전 부분 응답"), at: 0)
        await waitUntil { session.state.messages.last?.text == "실패 전 부분 응답" }
        await submitter.fail(
            at: 0,
            error: SensitiveSubmitError("stderr: token=TEST_ONLY")
        )
        await session.waitForCurrentSend()

        #expect(
            session.state.phase
                == .failed("입력을 처리하지 못했습니다. 다시 시도해 주세요.")
        )
        #expect(!session.state.messages.contains { $0.text == "실패 전 부분 응답" })

        session.setDraftText("후속 질문")
        #expect(session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(2)
        let followUp = await submitter.inputs[1]
        #expect(!followUp.text.contains("실패할 질문"))
        #expect(!followUp.text.contains("실패 전 부분 응답"))
        #expect(followUp.text == "User: 후속 질문")

        await submitter.yield(
            .completed(PromptResponse(text: "후속 응답")),
            at: 1
        )
        await submitter.finish(at: 1)
        await session.waitForCurrentSend()
    }

    @Test
    @MainActor
    func streamCancellationRemovesPartialAssistantContentFromFollowUpContext() async {
        let submitter = ControlledEventFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("취소될 질문")
        #expect(session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(1)

        await submitter.yield(.textSnapshot("취소 전 부분 응답"), at: 0)
        await waitUntil { session.state.messages.last?.text == "취소 전 부분 응답" }
        await submitter.fail(at: 0, error: CancellationError())
        await session.waitForCurrentSend()

        #expect(session.state.phase == .cancelled)
        #expect(!session.state.messages.contains { $0.text == "취소 전 부분 응답" })

        session.setDraftText("새 질문")
        #expect(session.send(reduceMotion: false))
        await submitter.waitForSubmissionCount(2)
        let followUp = await submitter.inputs[1]
        #expect(!followUp.text.contains("취소될 질문"))
        #expect(!followUp.text.contains("취소 전 부분 응답"))
        #expect(followUp.text == "User: 새 질문")

        await submitter.yield(
            .completed(PromptResponse(text: "새 응답")),
            at: 1
        )
        await submitter.finish(at: 1)
        await session.waitForCurrentSend()
    }

    @Test
    @MainActor
    func completedOnlySubmitterRetainsItsExistingBehavior() async {
        let submitter = ImmediateFeedSubmitter(
            result: .success(PromptResponse(text: "기존 완료 응답"))
        )
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("기존 요청")

        #expect(session.send(reduceMotion: true))
        await session.waitForCurrentSend()

        #expect(await submitter.inputs.count == 1)
        #expect(session.state.phase == .idle)
        #expect(session.state.messages.map(\.text) == ["기존 요청", "기존 완료 응답"])
        #expect(session.state.messages.last?.isLoading == false)
        #expect(!session.canRetry)
    }

    @Test
    @MainActor
    func completionEndsTheSendBeforeDuplicateCompletionOrTrailingFailure() async {
        let submitter = ControlledEventFeedSubmitter()
        let session = ChatBubbleSession(submitter: submitter)
        session.setDraftText("질문")
        #expect(session.send(reduceMotion: true))
        await submitter.waitForSubmissionCount(1)

        await submitter.yield(
            .completed(PromptResponse(text: "첫 완료")),
            at: 0
        )
        await submitter.yield(
            .completed(PromptResponse(text: "중복 완료")),
            at: 0
        )
        await submitter.yield(.textDelta("늦은 변경"), at: 0)
        await submitter.fail(at: 0, error: TestSendError.retryable)
        await session.waitForCurrentSend()

        #expect(session.state.phase == .idle)
        #expect(session.state.messages.map(\.text) == ["질문", "첫 완료"])
        #expect(!session.canRetry)
    }
}

private actor ImmediateFeedSubmitter: FeedSubmitting {
    let result: Result<PromptResponse, any Error & Sendable>
    private(set) var inputs: [FeedInput] = []

    init(result: Result<PromptResponse, any Error & Sendable>) {
        self.result = result
    }

    func submit(_ input: FeedInput, reduceMotion: Bool) async throws -> PromptResponse {
        inputs.append(input)
        return try result.get()
    }
}

private enum TestSendError: Error, Equatable, Sendable {
    case lateFailure
    case retryable
}

private struct SensitiveSubmitError: LocalizedError, Sendable {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    var errorDescription: String? { raw }
}

private actor ScriptedFeedSubmitter: FeedSubmitting {
    private var results: [Result<PromptResponse, any Error & Sendable>]
    private(set) var inputs: [FeedInput] = []

    init(results: [Result<PromptResponse, any Error & Sendable>]) {
        self.results = results
    }

    func submit(_ input: FeedInput, reduceMotion: Bool) async throws -> PromptResponse {
        inputs.append(input)
        guard !results.isEmpty else {
            throw TestSendError.retryable
        }
        return try results.removeFirst().get()
    }
}

private actor ControlledFeedSubmitter: FeedSubmitting {
    private var continuations: [CheckedContinuation<PromptResponse, any Error>?] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var inputs: [FeedInput] = []

    var submissionCount: Int { continuations.count }

    func submit(_ input: FeedInput, reduceMotion: Bool) async throws -> PromptResponse {
        try await withCheckedThrowingContinuation { continuation in
            inputs.append(input)
            continuations.append(continuation)
            let ready = countWaiters.filter { continuations.count >= $0.0 }
            countWaiters.removeAll { continuations.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForSubmissionCount(_ count: Int) async {
        guard continuations.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func succeed(at index: Int, text: String) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(returning: PromptResponse(text: text))
    }

    func fail(at index: Int, error: any Error) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(throwing: error)
    }
}

private actor CancellableFeedSubmitter: FeedSubmitting {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func submit(_ input: FeedInput, reduceMotion: Bool) async throws -> PromptResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled = true
            let waiters = cancelWaiters
            cancelWaiters.removeAll()
            waiters.forEach { $0.resume() }
            throw CancellationError()
        }
        return PromptResponse(text: "unexpected")
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
}

private actor ControlledEventFeedSubmitter: FeedSubmitting {
    private var continuations: [
        AsyncThrowingStream<PromptResponseEvent, Error>.Continuation
    ] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var inputs: [FeedInput] = []

    func submit(_ input: FeedInput, reduceMotion: Bool) async throws -> PromptResponse {
        throw TestSendError.retryable
    }

    nonisolated func submitEvents(
        _ input: FeedInput,
        reduceMotion: Bool
    ) -> AsyncThrowingStream<PromptResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.register(input: input, continuation: continuation)
            }
        }
    }

    func waitForSubmissionCount(_ count: Int) async {
        guard continuations.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func yield(_ event: PromptResponseEvent, at index: Int) {
        continuations[index].yield(event)
    }

    func finish(at index: Int) {
        continuations[index].finish()
    }

    func fail(at index: Int, error: any Error) {
        continuations[index].finish(throwing: error)
    }

    private func register(
        input: FeedInput,
        continuation: AsyncThrowingStream<PromptResponseEvent, Error>.Continuation
    ) {
        inputs.append(input)
        continuations.append(continuation)
        let ready = countWaiters.filter { continuations.count >= $0.0 }
        countWaiters.removeAll { continuations.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for chat state")
}

private func makeTemporaryCapture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("YumYum-Capture-\(UUID().uuidString).png")
    try Data("image".utf8).write(to: url)
    return url
}
