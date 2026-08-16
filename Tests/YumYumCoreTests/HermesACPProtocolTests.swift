import Foundation
import Testing
@testable import YumYumCore

@Suite
struct HermesACPProtocolTests {
    @Test
    func eachACPConnectorUsesItsDocumentedArgumentVector() async throws {
        let cases: [(AgentDefinitionID, [String])] = [
            (.hermes, ["acp"]),
            (.gemini, ["--acp"]),
        ]

        for (definitionID, arguments) in cases {
            let lineTransport = ScriptedACPLineTransport(
                incoming: [
                    #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                    #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"응답"}}}}"#,
                    #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
                ]
            )
            let factory = ScriptedACPLineTransportFactory(transport: lineTransport)
            let transport = ACPProcessTransport(
                lineTransportFactory: factory,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: "/private/tmp")
            )
            let connector = ACPConnector(definitionID: definitionID, transport: transport)

            let response = try await connector.send(
                PromptRequest(text: "질문"),
                executableURL: URL(fileURLWithPath: "/mock/\(definitionID.rawValue)")
            )

            #expect(response == PromptResponse(text: "응답"))
            #expect(await factory.madeArguments() == arguments)
        }
    }

    @Test
    func skipsNonJSONLinesBetweenValidJSONRPCMessages() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                "cached credentials loaded",
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                "starting ACP session",
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                "agent log line",
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"완료"}}}}"#,
                "done",
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let client = ACPProtocolClient(transport: transport)

        #expect(try await client.send(PromptRequest(text: "질문")) == PromptResponse(text: "완료"))
    }

    @Test
    func nonJSONOutputStillStopsAtTheProcessOutputByteLimit() async throws {
        let transport = try ACPProcessLineTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            environment: ["PATH": "/usr/bin"],
            workingDirectory: FileManager.default.temporaryDirectory,
            outputByteLimit: 8
        )
        let client = ACPProtocolClient(transport: transport)

        do {
            _ = try await client.send(PromptRequest(text: "질문"))
            Issue.record("Expected ACP output limit to stop non-JSON garbage")
        } catch let error as ACPProtocolError {
            #expect(error == .outputLimitExceeded)
        }

        await transport.close()
    }

    @Test
    func sharedACPSessionBehaviorWorksForEachDocumentedArgumentVector() async throws {
        let argumentSets = [["acp"], ["--acp"], ["agent", "stdio"]]

        for arguments in argumentSets {
            let lineTransport = ScriptedACPLineTransport(
                incoming: [
                    #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                    #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                    #"{"jsonrpc":"2.0","id":90,"method":"session/request_permission","params":{"sessionId":"session-1","options":[]}}"#,
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"첫 응답"}}}}"#,
                    #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"둘째 응답"}}}}"#,
                    #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#,
                ]
            )
            let factory = ScriptedACPLineTransportFactory(transport: lineTransport)
            let transport = ACPProcessTransport(
                lineTransportFactory: factory,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: "/private/tmp")
            )

            let first = try await transport.send(
                PromptRequest(text: "첫 질문"),
                executableURL: URL(fileURLWithPath: "/mock/agent"),
                environment: ["PATH": "/mock"],
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )
            let second = try await transport.send(
                PromptRequest(text: "둘째 질문"),
                executableURL: URL(fileURLWithPath: "/mock/agent"),
                environment: ["PATH": "/mock"],
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )

            #expect(first == PromptResponse(text: "첫 응답"))
            #expect(second == PromptResponse(text: "둘째 응답"))
            #expect(await factory.makeCount() == 1)
            #expect(await factory.madeArguments() == arguments)
            #expect(try await decodedMethods(lineTransport.sentLines()) == [
                "initialize", "session/new", "session/prompt", "session/prompt",
            ])
        }
    }

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
        let client = ACPProtocolClient(
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
    func selectsRequestedHermesModelOnlyWhenCreatingTheSession() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[{"modelId":"anthropic:old","name":"Old"},{"modelId":"openai:gpt-5","name":"GPT-5"}],"currentModelId":"anthropic:old"}}}"#,
                #"{"jsonrpc":"2.0","id":90,"method":"session/request_permission","params":{"sessionId":"session-1","options":[]}}"#,
                #"{"jsonrpc":"2.0","id":91,"method":"fs/read_text_file","params":{}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"첫 응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"둘째 응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let client = ACPProtocolClient(transport: transport)

        _ = try await client.send(PromptRequest(text: "첫 질문", modelID: "openai:gpt-5"))
        _ = try await client.send(PromptRequest(text: "둘째 질문", modelID: "openai:gpt-5"))

        let sent = try await transport.sentLines().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let methods = sent.compactMap { $0["method"] as? String }
        #expect(methods == [
            "initialize",
            "session/new",
            "session/set_model",
            "session/prompt",
            "session/prompt",
        ])
        let setModel = try #require(sent.first { $0["method"] as? String == "session/set_model" })
        #expect(setModel["id"] as? Int == 2)
        let setParams = try #require(setModel["params"] as? [String: Any])
        #expect(setParams["sessionId"] as? String == "session-1")
        #expect(setParams["modelId"] as? String == "openai:gpt-5")
        #expect(sent.filter { $0["method"] as? String == "session/prompt" }.count == 2)
        #expect(sent.contains { message in
            (message["id"] as? Int) == 90
                && (message["result"] as? [String: Any])?["outcome"] as? [String: Any] != nil
        })
        #expect(sent.contains { message in
            (message["id"] as? Int) == 91
                && (message["error"] as? [String: Any])?["code"] as? Int == -32_601
        })
    }

    @Test
    func setModelErrorStopsPromptAndPropagatesRequestFailure() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[],"currentModelId":"anthropic:old"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"model unavailable"}}"#,
            ]
        )
        let client = ACPProtocolClient(transport: transport)

        do {
            _ = try await client.send(PromptRequest(text: "질문", modelID: "openai:gpt-5"))
            Issue.record("Expected session/set_model to fail")
        } catch let error as ACPProtocolError {
            #expect(error == .requestFailed("model unavailable"))
        }

        let sent = try await transport.sentLines().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(sent.compactMap { $0["method"] as? String } == [
            "initialize", "session/new", "session/set_model",
        ])
    }

    @Test
    func missingModelsFieldStillReturnsEmptyCatalogAndAttemptsSelection() async throws {
        let transport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":null}"#,
            ]
        )
        let client = ACPProtocolClient(transport: transport)

        #expect(try await client.modelCatalog(modelID: "openai:gpt-5").isEmpty)
        let sent = try await transport.sentLines().map { data in
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(sent.compactMap { $0["method"] as? String } == [
            "initialize", "session/new", "session/set_model",
        ])
    }

    @Test
    func modelCatalogFiltersProvidersButFallsBackWhenFilteringWouldBeEmpty() async throws {
        let filteredTransport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[{"modelId":"openai-codex:gpt-5.6-sol","name":"GPT-5.6 Sol"},{"modelId":"anthropic-claude:opus-5","name":"Opus 5"},{"modelId":"kimi:moonshot-v2","name":"Moonshot V2"},{"modelId":"openaifoo:model","name":"OpenAI Foo"}],"currentModelId":"openai-codex:gpt-5.6-sol"}}}"#,
            ]
        )
        let filteredClient = ACPProtocolClient(transport: filteredTransport)
        #expect(try await filteredClient.modelCatalog(modelID: nil).map(\.id) == [
            "openai-codex:gpt-5.6-sol", "anthropic-claude:opus-5",
        ])

        let fallbackTransport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[{"modelId":"groq:llama","name":"Llama"},{"modelId":"mistral:large","name":"Mistral"}],"currentModelId":"groq:llama"}}}"#,
            ]
        )
        let fallbackClient = ACPProtocolClient(transport: fallbackTransport)
        #expect(try await fallbackClient.modelCatalog(modelID: nil).map(\.id) == [
            "groq:llama", "mistral:large",
        ])
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
        let client = ACPProtocolClient(
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
                ],
                responseLanguage: .korean
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
        let secondText = secondBlocks[0]["text"] as? String
        #expect(secondText?.hasPrefix("둘째 질문") == true)
        #expect(secondText?.contains("Always respond in Korean") == true)
        #expect(secondText?.contains("# YumYum Soul") == false)
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
        let client = ACPProtocolClient(
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
            arguments: ["acp"],
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
    func modelCatalogWarmsTheConnectionForTheFollowingPrompt() async throws {
        let lineTransport = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[{"modelId":"anthropic:claude","name":"Claude"}],"currentModelId":"anthropic:claude"}}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"응답"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let factory = ScriptedACPLineTransportFactory(transport: lineTransport)
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            arguments: ["acp"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )
        let executable = URL(fileURLWithPath: "/mock/hermes")

        #expect(try await transport.models(
            executableURL: executable,
            environment: ["PATH": "/mock"],
            outputByteLimit: 4_096,
            modelID: nil
        ).map(\.id) == ["anthropic:claude"])
        _ = try await transport.send(
            PromptRequest(text: "질문"),
            executableURL: executable,
            environment: ["PATH": "/mock"],
            timeout: .seconds(1),
            outputByteLimit: 4_096
        )

        #expect(await factory.makeCount() == 1)
        #expect(try await decodedMethods(lineTransport.sentLines()) == [
            "initialize", "session/new", "session/prompt",
        ])
    }

    @Test
    func forcedModelCatalogRefreshRecreatesAnExistingSession() async throws {
        let first = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[{"modelId":"anthropic:old","name":"Old"}]}}}"#,
            ]
        )
        let second = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-2","models":{"availableModels":[{"modelId":"openai:new","name":"New"}]}}}"#,
            ]
        )
        let factory = SequencedACPLineTransportFactory(transports: [first, second])
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            arguments: ["acp"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )
        let executable = URL(fileURLWithPath: "/mock/hermes")
        let parameters = (
            executableURL: executable,
            environment: ["PATH": "/mock"],
            outputByteLimit: 4_096
        )

        #expect(try await transport.models(
            executableURL: parameters.executableURL,
            environment: parameters.environment,
            outputByteLimit: parameters.outputByteLimit,
            modelID: nil
        ).map(\.id) == ["anthropic:old"])
        #expect(try await transport.models(
            executableURL: parameters.executableURL,
            environment: parameters.environment,
            outputByteLimit: parameters.outputByteLimit,
            modelID: nil
        ).map(\.id) == ["anthropic:old"])
        #expect(try await transport.models(
            executableURL: parameters.executableURL,
            environment: parameters.environment,
            outputByteLimit: parameters.outputByteLimit,
            modelID: nil,
            force: true
        ).map(\.id) == ["openai:new"])

        #expect(await factory.makeCount() == 2)
        #expect(await first.isClosed())
        #expect(try await decodedMethods(first.sentLines()) == [
            "initialize", "session/new",
        ])
        #expect(try await decodedMethods(second.sentLines()) == [
            "initialize", "session/new",
        ])
        let firstMessages = try await first.sentLines().map { line in
            try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        }
        let secondMessages = try await second.sentLines().map { line in
            try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        }
        let firstIDs = firstMessages.compactMap { $0["id"] as? Int }
        let secondIDs = secondMessages.compactMap { $0["id"] as? Int }
        #expect(firstIDs == [0, 1])
        #expect(secondIDs == [0, 1])
    }

    @Test
    func modelCatalogThrowsWithoutIOWhilePromptIsInFlight() async throws {
        let lineTransport = BlockingACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1"}}"#,
            ]
        )
        let factory = ScriptedACPLineTransportFactory(transport: lineTransport)
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            arguments: ["acp"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )
        let promptTask = Task {
            try await transport.send(
                PromptRequest(text: "진행 중인 질문"),
                executableURL: URL(fileURLWithPath: "/mock/hermes"),
                environment: ["PATH": "/mock"],
                timeout: .seconds(1),
                outputByteLimit: 4_096
            )
        }
        await lineTransport.waitUntilSent(method: "session/prompt")

        do {
            _ = try await transport.models(
                executableURL: URL(fileURLWithPath: "/mock/hermes"),
                environment: ["PATH": "/mock"],
                outputByteLimit: 4_096,
                modelID: nil
            )
            Issue.record("Expected model catalog to report an in-flight prompt")
        } catch let error as ACPProtocolError {
            #expect(error == .requestInFlight)
        }
        #expect(await factory.makeCount() == 1)

        promptTask.cancel()
        _ = try? await promptTask.value
        await transport.close()
    }

    @Test
    func modelCatalogTimeoutResetsConnectionBeforeTheFollowingPrompt() async throws {
        let first = BlockingACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
            ]
        )
        let second = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-2"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-2","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"복구"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let factory = SequencedACPLineTransportFactory(transports: [first, second])
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            arguments: ["acp"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )
        let executable = URL(fileURLWithPath: "/mock/hermes")

        do {
            _ = try await transport.models(
                executableURL: executable,
                environment: ["PATH": "/mock"],
                outputByteLimit: 4_096,
                modelID: nil
            )
            Issue.record("Expected model catalog to time out")
        } catch let error as AgentConnectorError {
            #expect(error == .timedOut)
        }

        #expect(await first.isClosed())
        let response = try await transport.send(
            PromptRequest(text: "타임아웃 후 질문"),
            executableURL: executable,
            environment: ["PATH": "/mock"],
            timeout: .seconds(1),
            outputByteLimit: 4_096
        )
        #expect(response.text == "복구")
        #expect(await factory.makeCount() == 2)
        #expect(try await decodedMethods(second.sentLines()) == [
            "initialize", "session/new", "session/prompt",
        ])
    }

    @Test
    func failedModelBindingResetsTheConnectionBeforeTheNextPrompt() async throws {
        let first = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-1","models":{"availableModels":[],"currentModelId":"anthropic:old"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"model unavailable"}}"#,
            ]
        )
        let second = ScriptedACPLineTransport(
            incoming: [
                #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#,
                #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"session-2"}}"#,
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-2","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"복구"}}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#,
            ]
        )
        let factory = SequencedACPLineTransportFactory(transports: [first, second])
        let transport = ACPProcessTransport(
            lineTransportFactory: factory,
            arguments: ["acp"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )
        let executable = URL(fileURLWithPath: "/mock/hermes")

        #expect(try await transport.models(
            executableURL: executable,
            environment: ["PATH": "/mock"],
            outputByteLimit: 4_096,
            modelID: "openai:gpt-5"
        ).isEmpty)
        let response = try await transport.send(
            PromptRequest(text: "복구 후 질문"),
            executableURL: executable,
            environment: ["PATH": "/mock"],
            timeout: .seconds(1),
            outputByteLimit: 4_096
        )

        #expect(response.text == "복구")
        #expect(await first.isClosed())
        #expect(await factory.makeCount() == 2)
        #expect(try await decodedMethods(second.sentLines()) == [
            "initialize", "session/new", "session/prompt",
        ])
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
            arguments: ["acp"],
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
            arguments: ["acp"],
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
            arguments: ["acp"],
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
    private var arguments: [String]?

    init(transport: any ACPLineTransporting) {
        self.transport = transport
    }

    func makeLineTransport(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int,
        arguments: [String]
    ) async throws -> any ACPLineTransporting {
        count += 1
        self.arguments = arguments
        return transport
    }

    func makeCount() -> Int {
        count
    }

    func madeArguments() -> [String]? {
        arguments
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
        outputByteLimit: Int,
        arguments: [String]
    ) async throws -> any ACPLineTransporting {
        count += 1
        return transports.removeFirst()
    }

    func makeCount() -> Int {
        count
    }
}
