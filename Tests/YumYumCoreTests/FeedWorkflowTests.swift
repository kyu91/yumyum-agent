import Foundation
import Testing
@testable import YumYumCore

@Suite
struct FeedWorkflowTests {
    @Test
    func validFeedAnimatesBeforeSendingExactlyOnceAndCleansTemporaryFiles() async throws {
        let temporaryImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try Data("image".utf8).write(to: temporaryImage)
        defer { try? FileManager.default.removeItem(at: temporaryImage) }

        let events = FeedEventRecorder()
        let sender = OrderedPromptSender(events: events)
        let feedback = OrderedFeedFeedback(events: events)
        let workflow = FeedWorkflow(sender: sender, feedback: feedback)

        let response = try await workflow.submit(
            FeedInput(
                text: "무엇이 보이는지 알려줘",
                fileURLs: [temporaryImage],
                temporaryFileURLs: [temporaryImage]
            ),
            reduceMotion: true
        )

        #expect(response == PromptResponse(text: "answer"))
        #expect(await sender.requests.count == 1)
        #expect(await sender.requests[0].attachments.count == 1)
        #expect(
            await events.values
                == [
                    .status(.validating),
                    .status(.animating(temporaryImage.lastPathComponent)),
                    .mouth(.reducedMotion),
                    .animation(label: temporaryImage.lastPathComponent, reduceMotion: true),
                    .status(.sending),
                    .send,
                    .mouth(.resting),
                    .status(.completed("answer")),
                ]
        )
        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
    }

    @Test
    func structuredPromptEventsFlowThroughFeedSubmission() async throws {
        let expected: [PromptResponseEvent] = [
            .textDelta("부분"),
            .textSnapshot("교정된 부분"),
            .completed(PromptResponse(text: "최종 응답")),
        ]
        let feedback = RecordingFeedFeedback()
        let workflow = FeedWorkflow(
            sender: EventPromptSender(events: expected),
            feedback: feedback
        )

        var received: [PromptResponseEvent] = []
        for try await event in workflow.submitEvents(
            FeedInput(text: "질문"),
            reduceMotion: true
        ) {
            received.append(event)
        }

        #expect(received == expected)
        #expect(await feedback.statuses.contains(.sending))
        #expect(await feedback.statuses.last == .completed("최종 응답"))
    }

    @Test
    func firstCompletionIsTerminalAndSuppressesDuplicateOrStaleEvents() async throws {
        let feedback = RecordingFeedFeedback()
        let workflow = FeedWorkflow(
            sender: EventPromptSender(events: [
                .textDelta("부분"),
                .completed(PromptResponse(text: "첫 완료")),
                .completed(PromptResponse(text: "중복 완료")),
                .textDelta("늦은 변경"),
            ]),
            feedback: feedback
        )

        var received: [PromptResponseEvent] = []
        for try await event in workflow.submitEvents(
            FeedInput(text: "질문"),
            reduceMotion: true
        ) {
            received.append(event)
        }

        #expect(received == [
            .textDelta("부분"),
            .completed(PromptResponse(text: "첫 완료")),
        ])
        #expect(await feedback.statuses.last == .completed("첫 완료"))
    }

    @Test
    func invalidInputsNeverAnimateOrSendAPromptRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsupported = directory.appendingPathComponent("archive.zip")
        try Data("zip".utf8).write(to: unsupported)
        let oversized = directory.appendingPathComponent("large.pdf")
        try Data(count: FeedValidator.maximumAttachmentBytes + 1).write(to: oversized)

        let sender = CountingPromptSender()
        let feedback = RecordingFeedFeedback()
        let workflow = FeedWorkflow(sender: sender, feedback: feedback)

        await expectFeedError(.blankInput) {
            try await workflow.submit(FeedInput(text: "  \n"), reduceMotion: false)
        }
        await expectFeedError(.unsupportedFile(unsupported.path)) {
            try await workflow.submit(
                FeedInput(text: "검토", fileURLs: [unsupported]),
                reduceMotion: false
            )
        }
        await expectFeedError(
            .oversizedFile(
                path: oversized.path,
                maximumBytes: Int64(FeedValidator.maximumAttachmentBytes)
            )
        ) {
            try await workflow.submit(
                FeedInput(text: "검토", fileURLs: [oversized]),
                reduceMotion: false
            )
        }

        #expect(await sender.requests.isEmpty)
        #expect(await feedback.mouthPresentations.isEmpty)
        #expect(await feedback.animationCount == 0)
    }

    @Test
    func busySubmissionStillCleansItsTemporaryFiles() async throws {
        let sender = BlockingPromptSender()
        let workflow = FeedWorkflow(sender: sender, feedback: RecordingFeedFeedback())
        let activeSubmission = Task {
            try await workflow.submit(
                FeedInput(text: "first"),
                reduceMotion: true
            )
        }
        await sender.waitUntilStarted()

        let temporaryImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try Data("image".utf8).write(to: temporaryImage)
        defer { try? FileManager.default.removeItem(at: temporaryImage) }

        do {
            _ = try await workflow.submit(
                FeedInput(
                    fileURLs: [temporaryImage],
                    temporaryFileURLs: [temporaryImage]
                ),
                reduceMotion: true
            )
            Issue.record("Expected the concurrent submission to be rejected")
        } catch {
            #expect(error as? FeedWorkflowError == .busy)
        }

        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
        await sender.finish()
        _ = try await activeSubmission.value
    }

    @Test
    func removesOnlyStaleYumYumCaptureFilesAtStartup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleCapture = directory
            .appendingPathComponent("YumYum-Capture-\(UUID().uuidString).png")
        let unrelatedFile = directory.appendingPathComponent("Other-Capture.png")
        let matchingDirectory = directory
            .appendingPathComponent("YumYum-Capture-directory", isDirectory: true)
        try Data("capture".utf8).write(to: staleCapture)
        try Data("other".utf8).write(to: unrelatedFile)
        try FileManager.default.createDirectory(
            at: matchingDirectory,
            withIntermediateDirectories: true
        )

        CaptureTemporaryFileCleanup.removeStaleFiles(in: directory)

        #expect(!FileManager.default.fileExists(atPath: staleCapture.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
        #expect(FileManager.default.fileExists(atPath: matchingDirectory.path))
    }

    @Test
    func cancellationClosesTheMouthAndCleansTheTemporaryCapture() async throws {
        let temporaryImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("YumYum-Capture-\(UUID().uuidString).png")
        try Data("image".utf8).write(to: temporaryImage)
        defer { try? FileManager.default.removeItem(at: temporaryImage) }

        let sender = CancellationPromptSender()
        let feedback = RecordingFeedFeedback()
        let workflow = FeedWorkflow(sender: sender, feedback: feedback)
        let task = Task {
            try await workflow.submit(
                FeedInput(
                    text: "취소",
                    fileURLs: [temporaryImage],
                    temporaryFileURLs: [temporaryImage]
                ),
                reduceMotion: true
            )
        }
        await sender.waitUntilStarted()

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(!FileManager.default.fileExists(atPath: temporaryImage.path))
        #expect(
            await feedback.mouthPresentations == [.reducedMotion, .resting]
        )
        #expect(
            await feedback.mouthPresentations.filter { $0 == .resting }.count == 1
        )
        #expect(await feedback.statuses.last == .cancelled)
    }

    @Test
    func cancellationWhileValidationFeedbackIsSuspendedNeverOpensTheMouth() async {
        let sender = CountingPromptSender()
        let feedback = SuspendedValidationFeedback()
        let workflow = FeedWorkflow(sender: sender, feedback: feedback)
        let task = Task {
            try await workflow.submit(FeedInput(text: "취소"), reduceMotion: false)
        }
        await feedback.waitUntilValidating()

        task.cancel()
        await feedback.resumeValidation()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(await feedback.mouthPresentations.isEmpty)
        #expect(await feedback.animationCount == 0)
        #expect(await sender.requests.isEmpty)
    }
}

private enum FeedEvent: Equatable, Sendable {
    case status(FeedStatus)
    case mouth(FeedMouthPresentation)
    case animation(label: String, reduceMotion: Bool)
    case send
}

private actor FeedEventRecorder {
    private(set) var values: [FeedEvent] = []

    func append(_ event: FeedEvent) {
        values.append(event)
    }
}

private actor OrderedPromptSender: PromptSending {
    private let events: FeedEventRecorder
    private(set) var requests: [PromptRequest] = []

    init(events: FeedEventRecorder) {
        self.events = events
    }

    func send(_ request: PromptRequest) async throws -> PromptResponse {
        requests.append(request)
        await events.append(.send)
        return PromptResponse(text: "answer")
    }
}

private struct EventPromptSender: PromptSending {
    let events: [PromptResponseEvent]

    func send(_ request: PromptRequest) async throws -> PromptResponse {
        PromptResponse(text: "legacy response")
    }

    func sendEvents(
        _ request: PromptRequest
    ) -> AsyncThrowingStream<PromptResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private actor OrderedFeedFeedback: FeedFeedback {
    private let events: FeedEventRecorder

    init(events: FeedEventRecorder) {
        self.events = events
    }

    func setMouthPresentation(_ presentation: FeedMouthPresentation) async {
        await events.append(.mouth(presentation))
    }

    func animate(_ preview: FeedPreview, reduceMotion: Bool) async {
        await events.append(.animation(label: preview.label, reduceMotion: reduceMotion))
    }

    func setStatus(_ update: FeedStatusUpdate) async {
        await events.append(.status(update.status))
    }
}

private func expectFeedError(
    _ expected: FeedValidationError,
    operation: () async throws -> PromptResponse
) async {
    do {
        _ = try await operation()
        Issue.record("Expected feed validation to fail with \(expected)")
    } catch {
        #expect(error as? FeedValidationError == expected)
    }
}

private actor CountingPromptSender: PromptSending {
    private(set) var requests: [PromptRequest] = []

    func send(_ request: PromptRequest) async throws -> PromptResponse {
        requests.append(request)
        return PromptResponse(text: "done")
    }
}

private actor BlockingPromptSender: PromptSending {
    private var sendContinuation: CheckedContinuation<PromptResponse, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: PromptRequest) async throws -> PromptResponse {
        await withCheckedContinuation { continuation in
            sendContinuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilStarted() async {
        guard sendContinuation == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        sendContinuation?.resume(returning: PromptResponse(text: "done"))
        sendContinuation = nil
    }
}

private actor CancellationPromptSender: PromptSending {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: PromptRequest) async throws -> PromptResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(30))
        return PromptResponse(text: "unexpected")
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor RecordingFeedFeedback: FeedFeedback {
    private(set) var mouthPresentations: [FeedMouthPresentation] = []
    private(set) var animationCount = 0
    private(set) var statuses: [FeedStatus] = []

    func setMouthPresentation(_ presentation: FeedMouthPresentation) {
        mouthPresentations.append(presentation)
    }

    func animate(_ preview: FeedPreview, reduceMotion: Bool) {
        animationCount += 1
    }

    func setStatus(_ update: FeedStatusUpdate) {
        statuses.append(update.status)
    }
}

private actor SuspendedValidationFeedback: FeedFeedback {
    private var validationContinuation: CheckedContinuation<Void, Never>?
    private var validationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var mouthPresentations: [FeedMouthPresentation] = []
    private(set) var animationCount = 0

    func setMouthPresentation(_ presentation: FeedMouthPresentation) {
        mouthPresentations.append(presentation)
    }

    func animate(_ preview: FeedPreview, reduceMotion: Bool) {
        animationCount += 1
    }

    func setStatus(_ update: FeedStatusUpdate) async {
        guard update.status == .validating else { return }
        let waiters = validationWaiters
        validationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { validationContinuation = $0 }
    }

    func waitUntilValidating() async {
        guard validationContinuation == nil else { return }
        await withCheckedContinuation { validationWaiters.append($0) }
    }

    func resumeValidation() {
        validationContinuation?.resume()
        validationContinuation = nil
    }
}
