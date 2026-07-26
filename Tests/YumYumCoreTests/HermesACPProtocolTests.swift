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
}

private actor ScriptedACPLineTransport: ACPLineTransporting {
    private var incoming: [Data]
    private var sent: [Data] = []

    init(incoming: [String]) {
        self.incoming = incoming.map { Data($0.utf8) }
    }

    func sendLine(_ data: Data) throws {
        sent.append(data)
    }

    func receiveLine() throws -> Data? {
        incoming.isEmpty ? nil : incoming.removeFirst()
    }

    func close() {}

    func sentLines() -> [Data] {
        sent
    }
}
