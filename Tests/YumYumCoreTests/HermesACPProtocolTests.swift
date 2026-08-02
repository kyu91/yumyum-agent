import Foundation
import Testing
@testable import YumYumCore

@Suite
struct HermesACPProtocolTests {
    @Test
    func stoppingTransportDoesNotWaitForABlockedInputWrite() {
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let lifecycle = ACPProcessLifecycle(
            writeAction: { _ in
                writeStarted.signal()
                releaseWrite.wait()
            },
            stopAction: {
                stopFinished.signal()
            }
        )

        Thread {
            try? lifecycle.write(Data("request".utf8))
            writeFinished.signal()
        }.start()
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)

        Thread {
            lifecycle.stop()
        }.start()
        let stopCompletedWhileWriteWasBlocked =
            stopFinished.wait(timeout: .now() + 1) == .success

        releaseWrite.signal()
        #expect(writeFinished.wait(timeout: .now() + 1) == .success)
        if !stopCompletedWhileWriteWasBlocked {
            _ = stopFinished.wait(timeout: .now() + 1)
        }
        #expect(stopCompletedWhileWriteWasBlocked)
    }

    @Test
    func initializesACPAndCancelsUnapprovedToolRequests() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"분석 완료"}}}}"#,
                #"{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"tool-1"},"options":[]}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let client = HermesACPProtocolClient(
            transport: transport,
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let request = PromptRequest(
            id: UUID(),
            text: "설명해줘",
            attachments: [
                PromptAttachment(
                    url: URL(fileURLWithPath: "/selected/report.pdf"),
                    kind: .pdf,
                    byteCount: 1_024
                ),
            ]
        )

        let response = try await client.send(request)

        #expect(response.text == "분석 완료")
        let sent = try await transport.sentLines().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(sent.count == 4)
        #expect(sent[0]["method"] as? String == "initialize")
        #expect((sent[0]["params"] as? [String: Any])?["protocolVersion"] as? Int == 1)
        #expect(sent[1]["method"] as? String == "session/new")
        #expect(sent[2]["method"] as? String == "session/prompt")

        let promptParams = try #require(sent[2]["params"] as? [String: Any])
        let blocks = try #require(promptParams["prompt"] as? [[String: Any]])
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[1]["type"] as? String == "resource_link")
        #expect(blocks[1]["uri"] as? String == "file:///selected/report.pdf")

        #expect(sent[3]["id"] as? Int == 99)
        let permissionResult = try #require(sent[3]["result"] as? [String: Any])
        let outcome = try #require(permissionResult["outcome"] as? [String: Any])
        #expect(outcome["outcome"] as? String == "cancelled")
    }

    @Test
    func reusesInitializationAndSessionAcrossTurnsWhileStreamingDeltas() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"첫 "}}}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"둘째 응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let client = HermesACPProtocolClient(
            transport: transport,
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let events = LockedPromptEvents()

        let first = try await client.send(
            PromptRequest(
                text: "사용자: 첫 질문",
                currentTurnText: "첫 질문",
                soulMarkdown: SoulProfile(name: "Momo").markdown
            ),
            onEvent: { events.append($0) }
        )
        let second = try await client.send(
            PromptRequest(
                text: "사용자: 첫 질문\n어시스턴트: 첫 응답\n사용자: 둘째 질문",
                currentTurnText: "둘째 질문",
                attachments: [
                    PromptAttachment(
                        url: URL(fileURLWithPath: "/selected/follow-up.pdf"),
                        kind: .pdf,
                        byteCount: 42
                    ),
                ]
            ),
            onEvent: { events.append($0) }
        )

        #expect(first.text == "첫 응답")
        #expect(second.text == "둘째 응답")
        #expect(events.values() == [
            .textDelta("첫 "),
            .textDelta("응답"),
            .textDelta("둘째 응답"),
        ])

        let sent = try await transport.sentLines().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let methods = sent.compactMap { $0["method"] as? String }
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        #expect(methods.filter { $0 == "session/new" }.count == 1)
        #expect(methods.filter { $0 == "session/prompt" }.count == 2)
        #expect(sent.compactMap { $0["id"] as? Int }.contains(3))
        #expect(await transport.outputBudgetResetCount() == 2)
        let firstPrompt = try #require(sent[2]["params"] as? [String: Any])
        let firstBlocks = try #require(firstPrompt["prompt"] as? [[String: Any]])
        #expect((firstBlocks[0]["text"] as? String)?.contains("# YumYum Soul") == true)
        let secondPrompt = try #require(sent[3]["params"] as? [String: Any])
        let secondBlocks = try #require(secondPrompt["prompt"] as? [[String: Any]])
        #expect(secondBlocks[0]["text"] as? String == "둘째 질문")
        #expect((secondBlocks[0]["text"] as? String)?.contains("# YumYum Soul") == false)
        #expect(secondBlocks[1]["uri"] as? String == "file:///selected/follow-up.pdf")
    }

    @Test
    func suppressesUpdatesFromAStaleHermesSession() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"active-session"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stale-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"이전 응답"}}}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"active-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"현재 응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let client = HermesACPProtocolClient(
            transport: transport,
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let events = LockedPromptEvents()

        let response = try await client.send(
            PromptRequest(text: "현재 질문"),
            onEvent: { events.append($0) }
        )

        #expect(response == PromptResponse(text: "현재 응답"))
        #expect(events.values() == [.textDelta("현재 응답")])
    }

    @Test
    func processTransportKeepsOneConnectionForSequentialEventStreams() async throws {
        let lineTransport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"첫 응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"둘째 응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let factory = ScriptedACPLineTransportFactory(transport: lineTransport)
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let executable = URL(fileURLWithPath: "/mock/hermes")
        let environment = ["PATH": "/mock"]

        let first = try await collectEvents(
            transport.sendEvents(
                PromptRequest(text: "첫 질문"),
                executableURL: executable,
                environment: environment,
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )
        )
        let second = try await collectEvents(
            transport.sendEvents(
                PromptRequest(text: "둘째 질문"),
                executableURL: executable,
                environment: environment,
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )
        )

        #expect(first == [.textDelta("첫 응답"), .completed(.init(text: "첫 응답"))])
        #expect(second == [.textDelta("둘째 응답"), .completed(.init(text: "둘째 응답"))])
        #expect(await factory.makeCount() == 1)
        await transport.close()
        #expect(await lineTransport.isClosed())
    }

    @Test
    func cancellationNotifiesHermesClosesTheConnectionAndReconnects() async throws {
        let first = BlockingACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"cancelled-session"}}"#,
            ],
            blocksCancellationWrite: true
        )
        let second = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"reconnected-session"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"reconnected-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"재연결 완료"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let factory = SequencedACPLineTransportFactory(transports: [first, second])
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let executable = URL(fileURLWithPath: "/mock/hermes")

        let cancelled = Task {
            let events = try await collectEvents(
                transport.sendEvents(
                    PromptRequest(
                        text: "취소할 질문",
                        soulMarkdown: SoulProfile(name: "Momo").normalized.markdown
                    ),
                    executableURL: executable,
                    environment: ["PATH": "/mock"],
                    timeout: .seconds(2),
                    outputByteLimit: 4_096
                )
            )
            try Task.checkCancellation()
            return events
        }
        await first.waitUntilSent(method: "session/prompt")
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            Issue.record("Expected the active Hermes prompt to be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
        await first.waitUntilSent(method: "session/cancel")

        let reconnected = try await collectEvents(
            transport.sendEvents(
                PromptRequest(
                    text: "새 질문",
                    soulMarkdown: SoulProfile(name: "Momo").normalized.markdown
                ),
                executableURL: executable,
                environment: ["PATH": "/mock"],
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )
        )

        #expect(reconnected == [
            .textDelta("재연결 완료"),
            .completed(PromptResponse(text: "재연결 완료")),
        ])
        #expect(await first.isClosed())
        #expect(await factory.makeCount() == 2)
        let secondMethods = try await decodedMethods(second.sentLines())
        #expect(secondMethods == ["initialize", "session/new", "session/prompt"])
        #expect(try await decodedPromptTexts(second.sentLines()).first?.contains("# YumYum Soul") == true)
        await transport.close()
    }

    @Test
    func timeoutClosesBlockedHermesConnectionPromptlyAndReconnects() async throws {
        let first = BlockingACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"timed-out-session"}}"#,
            ],
            blocksCancellationWrite: true
        )
        let second = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"recovered-session"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"recovered-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"복구 완료"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let factory = SequencedACPLineTransportFactory(transports: [first, second])
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let completion = AsyncTestFlag()

        let timedOut = Task {
            defer { completion.signal() }
            do {
                _ = try await collectEvents(
                    transport.sendEvents(
                        PromptRequest(
                            text: "응답이 멈출 질문",
                            soulMarkdown: SoulProfile(name: "Momo").normalized.markdown
                        ),
                        executableURL: URL(fileURLWithPath: "/mock/hermes"),
                        environment: ["PATH": "/mock"],
                        timeout: .milliseconds(20),
                        outputByteLimit: 4_096
                    )
                )
                return HermesTimeoutOutcome.unexpectedSuccess
            } catch let error as AgentConnectorError where error == .timedOut {
                return .timedOut
            } catch {
                return .unexpectedError(String(describing: error))
            }
        }
        await first.waitUntilSent(method: "session/prompt")
        let completedPromptly = await completion.wait(timeout: .milliseconds(100))
        if !completedPromptly {
            await first.close()
        }

        #expect(completedPromptly)
        #expect(await timedOut.value == .timedOut)
        #expect(await first.isClosed())

        let recovered = try await collectEvents(
            transport.sendEvents(
                PromptRequest(
                    text: "복구 후 질문",
                    soulMarkdown: SoulProfile(name: "Momo").normalized.markdown
                ),
                executableURL: URL(fileURLWithPath: "/mock/hermes"),
                environment: ["PATH": "/mock"],
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )
        )
        #expect(recovered == [
            .textDelta("복구 완료"),
            .completed(PromptResponse(text: "복구 완료")),
        ])
        #expect(await factory.makeCount() == 2)
        #expect(try await decodedPromptTexts(second.sentLines()).first?.contains("# YumYum Soul") == true)
        await transport.close()
    }

    @Test
    func realProcessReadRespondsToCancellationBeforeExplicitClose() async throws {
        let transport = try ACPProcessLineTransport(
            executableURL: fixtureURL,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory,
            outputByteLimit: 4_096
        )
        let completion = AsyncTestFlag()
        let readTask = Task {
            defer { completion.signal() }
            do {
                _ = try await transport.receiveLine()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        readTask.cancel()
        let completedPromptly = await completion.wait(timeout: .milliseconds(100))
        if !completedPromptly {
            await transport.close()
        }
        let observedCancellation = await readTask.value

        await transport.close()
        #expect(completedPromptly)
        #expect(observedCancellation)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/yumyum-process-fixture")
    }
}

private func collectEvents(
    _ stream: PromptResponseEventStream
) async throws -> [PromptResponseEvent] {
    var events: [PromptResponseEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func decodedMethods(_ lines: [Data]) throws -> [String] {
    try lines.compactMap { line in
        let message = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        return message["method"] as? String
    }
}

private func decodedPromptTexts(_ lines: [Data]) throws -> [String] {
    try lines.compactMap { line in
        let message = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        guard message["method"] as? String == "session/prompt",
              let params = message["params"] as? [String: Any],
              let blocks = params["prompt"] as? [[String: Any]] else { return nil }
        return blocks.first?["text"] as? String
    }
}

private final class LockedPromptEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PromptResponseEvent] = []

    func append(_ event: PromptResponseEvent) {
        lock.withLock { events.append(event) }
    }

    func values() -> [PromptResponseEvent] {
        lock.withLock { events }
    }
}

private enum HermesTimeoutOutcome: Equatable, Sendable {
    case timedOut
    case unexpectedSuccess
    case unexpectedError(String)
}

private final class AsyncTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func signal() {
        lock.withLock { value = true }
    }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !currentValue, clock.now < deadline {
            await Task.yield()
        }
        return currentValue
    }

    private var currentValue: Bool {
        lock.withLock { value }
    }
}

private actor ScriptedACPLineTransport: ACPLineTransporting {
    private var incoming: [Data]
    private var sent: [Data] = []
    private var closed = false
    private var budgetResetCount = 0

    init(incoming: [String]) {
        self.incoming = incoming.map { Data($0.utf8) }
    }

    func sendLine(_ data: Data) throws {
        sent.append(data)
    }

    func receiveLine() throws -> Data? {
        incoming.isEmpty ? nil : incoming.removeFirst()
    }

    func close() {
        closed = true
    }

    func resetOutputBudget() {
        budgetResetCount += 1
    }

    func sentLines() -> [Data] {
        sent
    }

    func isClosed() -> Bool {
        closed
    }

    func outputBudgetResetCount() -> Int {
        budgetResetCount
    }
}

private actor ScriptedACPLineTransportFactory: ACPLineTransportFactory {
    private let transport: any ACPLineTransporting
    private var count = 0

    init(transport: any ACPLineTransporting) {
        self.transport = transport
    }

    func makeLineTransport(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int
    ) async throws -> any ACPLineTransporting {
        count += 1
        return transport
    }

    func makeCount() -> Int {
        count
    }
}

private actor BlockingACPLineTransport: ACPLineTransporting {
    private var incoming: [Data]
    private var sent: [Data] = []
    private var receiver: CheckedContinuation<Data?, Never>?
    private var cancellationWriter: CheckedContinuation<Void, Never>?
    private var closed = false
    private let blocksCancellationWrite: Bool

    init(
        incoming: [String],
        blocksCancellationWrite: Bool = false
    ) {
        self.incoming = incoming.map { Data($0.utf8) }
        self.blocksCancellationWrite = blocksCancellationWrite
    }

    func sendLine(_ data: Data) async {
        sent.append(data)
        guard blocksCancellationWrite,
              decodedMethod(data) == "session/cancel",
              !closed else {
            return
        }
        await withCheckedContinuation { cancellationWriter = $0 }
    }

    func receiveLine() async -> Data? {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        if closed {
            return nil
        }
        return await withCheckedContinuation { receiver = $0 }
    }

    func close() {
        closed = true
        receiver?.resume(returning: nil)
        receiver = nil
        cancellationWriter?.resume()
        cancellationWriter = nil
    }

    func waitUntilSent(method: String) async {
        for _ in 0..<10_000 {
            if decodedSentMethods().contains(method) {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for Hermes method \(method)")
    }

    func isClosed() -> Bool {
        closed
    }

    private func decodedSentMethods() -> [String] {
        sent.compactMap(decodedMethod)
    }

    private func decodedMethod(_ data: Data) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            return nil
        }
        return message["method"] as? String
    }
}

private actor SequencedACPLineTransportFactory: ACPLineTransportFactory {
    private var transports: [any ACPLineTransporting]
    private var count = 0

    init(transports: [any ACPLineTransporting]) {
        self.transports = transports
    }

    func makeLineTransport(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int
    ) async throws -> any ACPLineTransporting {
        count += 1
        return transports.removeFirst()
    }

    func makeCount() -> Int {
        count
    }
}
