import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AgentConnectorTests {
    @Test
    func runtimeLoadsCurrentSoulAtTheCommonRequestBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SoulProfileStore(fileURL: directory.appendingPathComponent("SOUL.md"))
        try await store.save(SoulProfile(name: "Momo"))
        let connector = RuntimeConnector(definitionID: .openCode)
        let runtime = AgentRuntime(
            selection: RuntimeSelection(installation: AgentInstallation(
                definitionID: .openCode,
                path: "/selected/opencode",
                version: "1",
                runtimeContract: .openCodeRun,
                availability: .available
            )),
            connectors: [connector],
            soulStore: store
        )

        _ = try await runtime.send(PromptRequest(text: "hello"))

        let request = try #require(await connector.requests.first)
        #expect(request.text == "hello")
        #expect(request.soulMarkdown?.contains("## Name\n\nMomo") == true)
        #expect(request.soulMarkdown?.contains("## Response Style") == true)
        #expect(request.soulMarkdown?.contains("context needed to act") == true)
        #expect(request.attachments.isEmpty)
        #expect(request.responseLanguage != nil)
    }

    @Test
    func koreanResponseLanguageAppendsDirectiveToFirstAndResumedPrompts() throws {
        let attachment = PromptAttachment(
            url: URL(fileURLWithPath: "/selected/report.pdf"),
            kind: .pdf,
            byteCount: 42
        )
        let request = PromptRequest(
            text: "hello",
            attachments: [attachment],
            soulMarkdown: "some soul",
            responseLanguage: .korean
        )
        let directive = "respond in Korean"
        let firstPrompt = firstSessionPromptText(
            for: request,
            visibleAttachments: request.attachments
        )
        let directiveRange = try #require(firstPrompt.range(of: directive))
        let soulRange = try #require(firstPrompt.range(of: "some soul"))
        let attachmentRange = try #require(firstPrompt.range(of: attachment.url.path))

        #expect(firstPrompt.contains(directive))
        #expect(firstPrompt.components(separatedBy: directive).count - 1 == 1)
        #expect(directiveRange.lowerBound > soulRange.lowerBound)
        #expect(directiveRange.lowerBound > attachmentRange.lowerBound)

        let resumedPrompt = promptText(
            for: request,
            text: request.currentTurnText,
            visibleAttachments: request.attachments
        )
        #expect(resumedPrompt.contains(directive))
    }

    @Test
    func englishResponseLanguageLeavesPromptTextUnchanged() {
        let attachment = PromptAttachment(
            url: URL(fileURLWithPath: "/selected/report.pdf"),
            kind: .pdf,
            byteCount: 42
        )
        let english = PromptRequest(
            text: "hello",
            attachments: [attachment],
            soulMarkdown: "some soul",
            responseLanguage: .english
        )
        let nilLanguage = PromptRequest(
            text: "hello",
            attachments: [attachment],
            soulMarkdown: "some soul",
            responseLanguage: nil
        )
        let beforeChange = PromptRequest(
            text: "hello",
            attachments: [attachment],
            soulMarkdown: "some soul"
        )
        let englishPrompt = promptText(
            for: english,
            visibleAttachments: english.attachments
        )
        let nilPrompt = promptText(
            for: nilLanguage,
            visibleAttachments: nilLanguage.attachments
        )
        let beforeChangePrompt = promptText(
            for: beforeChange,
            visibleAttachments: beforeChange.attachments
        )

        #expect(!englishPrompt.contains("Korean"))
        #expect(!nilPrompt.contains("Korean"))
        #expect(englishPrompt == nilPrompt)
        #expect(nilPrompt == beforeChangePrompt)
    }

    @Test
    func runtimeAttachesCurrentLanguageOnEverySendIncludingMidSessionSwitch() async throws {
        let previousLanguage = AppText.language
        defer { AppText.setLanguage(previousLanguage) }
        let connector = RuntimeConnector(definitionID: .openCode)
        let runtime = AgentRuntime(
            selection: RuntimeSelection(installation: AgentInstallation(
                definitionID: .openCode,
                path: "/selected/opencode",
                version: "1",
                runtimeContract: .openCodeRun,
                availability: .available
            )),
            connectors: [connector],
            soulStore: nil
        )
        let request = PromptRequest(text: "hello", soulMarkdown: "request soul")

        AppText.setLanguage(.korean)
        _ = try await runtime.send(request)
        AppText.setLanguage(.english)
        _ = try await runtime.send(request)

        let requests = await connector.requests
        #expect(requests.count == 2)
        #expect(requests[0].responseLanguage == .korean)
        #expect(requests[1].responseLanguage == .english)
        #expect(requests[0].soulMarkdown == "request soul")
        #expect(requests[1].soulMarkdown == "request soul")
    }

    @Test
    func soulIsInjectedForNewConnectorSessionsOnly() async throws {
        let runner = StructuredConnectorProcessRunner()
        let executableDirectory = URL(fileURLWithPath: "/safe/bin", isDirectory: true)
        let soul = SoulProfile(name: "Momo").markdown
        let first = PromptRequest(text: "first", currentTurnText: "first", soulMarkdown: soul)
        let second = PromptRequest(
            text: "history second", currentTurnText: "second",
            attachments: [PromptAttachment(
                url: URL(fileURLWithPath: "/selected/follow-up.swift"),
                kind: .source, byteCount: 12
            )],
            soulMarkdown: soul
        )
        let codex = CodexConnector(processRunner: runner)
        let claude = ClaudeCodeConnector(processRunner: runner)

        _ = try await OpenCodeConnector(processRunner: runner).send(
            first, executableURL: executableDirectory.appendingPathComponent("opencode")
        )
        _ = try await OpenCodeConnector(processRunner: runner).send(
            second, executableURL: executableDirectory.appendingPathComponent("opencode")
        )
        _ = try await codex.send(first, executableURL: executableDirectory.appendingPathComponent("codex"))
        _ = try await codex.send(second, executableURL: executableDirectory.appendingPathComponent("codex"))
        _ = try await claude.send(first, executableURL: executableDirectory.appendingPathComponent("claude"))
        _ = try await claude.send(second, executableURL: executableDirectory.appendingPathComponent("claude"))

        let openCodePrompts = await runner.commands(for: "opencode").compactMap(\.arguments.last)
        #expect(openCodePrompts.allSatisfy { $0.contains("# YumYum Soul") })
        for name in ["codex", "claude"] {
            let inputs = await runner.commands(for: name)
                .compactMap { $0.standardInput.map { String(decoding: $0, as: UTF8.self) } }
            #expect(inputs.count == 2)
            #expect(inputs[0].contains("# YumYum Soul"))
            #expect(inputs[0].components(separatedBy: "# YumYum Soul").count == 2)
            #expect(!inputs[1].contains("# YumYum Soul"))
            #expect(inputs[1].contains("second"))
            #expect(inputs[1].components(separatedBy: "/selected/follow-up.swift").count == 2)
            #expect(!inputs[1].contains("history second"))
        }
    }

    @Test
    func runtimeRevalidatesTheExactSelectionBeforeEverySend() async throws {
        let selected = AgentInstallation(
            definitionID: .openCode,
            path: "/selected/opencode",
            version: "1.18.5",
            runtimeContract: .openCodeRun,
            availability: .available
        )
        let selection = RuntimeSelection(installation: selected)
        let openCode = RuntimeConnector(definitionID: .openCode)
        let codex = RuntimeConnector(definitionID: .codex)
        let runtime = AgentRuntime(
            selection: selection,
            connectors: [openCode, codex]
        )
        let request = PromptRequest(text: "hello")

        let response = try await runtime.send(request)

        await selection.setResult(.failure(AgentSelectionError.explicitReselectionRequired))
        do {
            _ = try await runtime.send(PromptRequest(text: "second"))
            Issue.record("Expected exact selection revalidation to block the second send")
        } catch {
            #expect(error as? AgentSelectionError == .explicitReselectionRequired)
        }

        #expect(response == PromptResponse(text: "OpenCode response"))
        #expect(await selection.validationCount == 2)
        let expectedRequest = PromptRequest(
            id: request.id,
            text: request.text,
            currentTurnText: request.currentTurnText,
            attachments: request.attachments,
            soulMarkdown: request.soulMarkdown,
            responseLanguage: AppText.language
        )
        #expect(await openCode.requests == [expectedRequest])
        #expect(await openCode.executablePaths == ["/selected/opencode"])
        #expect(await codex.requests.isEmpty)
    }

    @Test
    func runtimeForwardsStructuredConnectorEvents() async throws {
        let selected = AgentInstallation(
            definitionID: .openCode,
            path: "/selected/opencode",
            version: "1.18.5",
            runtimeContract: .openCodeRun,
            availability: .available
        )
        let expected: [PromptResponseEvent] = [
            .textDelta("부분"),
            .textSnapshot("교정된 부분"),
            .completed(PromptResponse(text: "최종 응답")),
        ]
        let runtime = AgentRuntime(
            selection: RuntimeSelection(installation: selected),
            connectors: [
                RuntimeEventConnector(definitionID: .openCode, events: expected),
            ]
        )

        var received: [PromptResponseEvent] = []
        for try await event in runtime.sendEvents(PromptRequest(text: "hello")) {
            received.append(event)
        }

        #expect(received == expected)
    }

    @Test
    func eachAgentUsesItsVerifiedDedicatedLocalContract() async throws {
        let executableDirectory = URL(fileURLWithPath: "/safe/bin", isDirectory: true)
        let request = PromptRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            text: "이 자료를 설명해줘",
            attachments: [
                PromptAttachment(
                    url: URL(fileURLWithPath: "/selected/screen.png"),
                    kind: .image,
                    byteCount: 12
                ),
                PromptAttachment(
                    url: URL(fileURLWithPath: "/selected/code.swift"),
                    kind: .source,
                    byteCount: 34
                ),
            ]
        )
        let runner = ConnectorProcessRunner()
        let hermesTransport = RecordingHermesTransport()

        _ = try await HermesACPConnector(transport: hermesTransport).send(
            request,
            executableURL: executableDirectory.appendingPathComponent("hermes")
        )
        _ = try await OpenCodeConnector(processRunner: runner).send(
            request,
            executableURL: executableDirectory.appendingPathComponent("opencode")
        )
        _ = try await CodexConnector(processRunner: runner).send(
            request,
            executableURL: executableDirectory.appendingPathComponent("codex")
        )
        _ = try await ClaudeCodeConnector(processRunner: runner).send(
            request,
            executableURL: executableDirectory.appendingPathComponent("claude")
        )

        let hermesInvocation = try #require(await hermesTransport.invocation)
        #expect(hermesInvocation.executableURL.path == "/safe/bin/hermes")
        #expect(hermesInvocation.request == request)

        let invocations = await runner.invocations
        #expect(invocations.count == 3)
        let openCode = invocations[0].command
        #expect(openCode.executableURL.path == "/safe/bin/opencode")
        #expect(
            openCode.arguments
                == [
                    "run", "--pure", "--format", "json",
                    "--file", "/selected/screen.png",
                    "--file", "/selected/code.swift",
                    "이 자료를 설명해줘",
                ]
        )

        let codex = invocations[1].command
        #expect(codex.executableURL.path == "/safe/bin/codex")
        #expect(codex.arguments.prefix(7) == [
            "--ask-for-approval", "untrusted", "exec", "--json", "--sandbox", "read-only",
            "--skip-git-repo-check",
        ])
        #expect(codex.arguments.contains("--image"))
        #expect(codex.arguments.contains("/selected/screen.png"))
        let codexInput = String(
            decoding: try #require(codex.standardInput),
            as: UTF8.self
        )
        #expect(codexInput.contains("이 자료를 설명해줘"))
        #expect(codexInput.contains("/selected/code.swift"))
        #expect(!codex.arguments.contains { $0.contains("이 자료를 설명해줘") })

        let claude = invocations[2].command
        #expect(claude.executableURL.path == "/safe/bin/claude")
        #expect(claude.arguments.prefix(7) == [
            "--print", "--verbose", "--output-format", "stream-json",
            "--include-partial-messages", "--permission-mode", "plan",
        ])
        #expect(claude.arguments.contains("--session-id"))
        #expect(!claude.arguments.contains("--safe-mode"))
        let claudeInput = String(
            decoding: try #require(claude.standardInput),
            as: UTF8.self
        )
        #expect(claudeInput.contains("이 자료를 설명해줘"))
        #expect(claudeInput.contains("/selected/screen.png"))
        #expect(claudeInput.contains("/selected/code.swift"))
        #expect(!claude.arguments.contains { $0.contains("이 자료를 설명해줘") })

        for invocation in invocations {
            #expect(invocation.timeout == .seconds(120))
            #expect(invocation.command.outputByteLimit == 2_097_152)
            #expect(invocation.command.environment?.keys.sorted() == [
                "HOME", "LANG", "LC_ALL", "LOGNAME", "PATH", "TERM", "USER",
            ])
            #expect(invocation.command.executableURL.path != "/bin/sh")
        }
    }

    @Test
    func codexStreamsFragmentedExecJSONAndResumesTheExactSession() async throws {
        let runner = StructuredConnectorProcessRunner()
        let connector = CodexConnector(processRunner: runner)
        let executable = URL(fileURLWithPath: "/safe/bin/codex")

        let first = try await collectConnectorEvents(
            connector.sendEvents(
                PromptRequest(
                    text: "사용자: 첫 질문",
                    currentTurnText: "첫 질문"
                ),
                executableURL: executable
            )
        )
        let second = try await collectConnectorEvents(
            connector.sendEvents(
                PromptRequest(
                    text: "사용자: 첫 질문\n어시스턴트: 첫 응답\n사용자: 둘째 질문",
                    currentTurnText: "둘째 질문",
                    attachments: [
                        PromptAttachment(
                            url: URL(fileURLWithPath: "/selected/follow-up.png"),
                            kind: .image,
                            byteCount: 12
                        ),
                    ]
                ),
                executableURL: executable
            )
        )

        #expect(first == [
            .textSnapshot("안녕"),
            .textSnapshot("안녕하세요 👋"),
            .completed(PromptResponse(text: "안녕하세요 👋")),
        ])
        #expect(second == [
            .textSnapshot("둘째 응답"),
            .completed(PromptResponse(text: "둘째 응답")),
        ])
        #expect(first.filter(\.isCompletion).count == 1)
        #expect(second.filter(\.isCompletion).count == 1)

        let commands = await runner.commands(for: "codex")
        #expect(commands.count == 2)
        #expect(commands[0].arguments.contains("--json"))
        #expect(commands[0].arguments.contains("exec"))
        #expect(!commands[0].arguments.contains("resume"))
        #expect(!commands[0].arguments.contains("--ephemeral"))
        #expect(commands[0].standardInput == Data("사용자: 첫 질문".utf8))
        #expect(commands[1].arguments == [
            "--ask-for-approval", "untrusted", "exec",
            "--json", "--sandbox", "read-only", "--skip-git-repo-check",
            "--image", "/selected/follow-up.png",
            "resume", "codex-session-1",
        ])
        #expect(!commands[1].arguments.contains("--ephemeral"))
        #expect(commands[1].standardInput == Data("둘째 질문".utf8))
    }

    @Test
    func claudeStreamsFragmentedPartialMessagesAndResumesTheExactSession() async throws {
        let runner = StructuredConnectorProcessRunner()
        let connector = ClaudeCodeConnector(processRunner: runner)
        let executable = URL(fileURLWithPath: "/safe/bin/claude")

        let first = try await collectConnectorEvents(
            connector.sendEvents(
                PromptRequest(
                    text: "사용자: 첫 질문",
                    currentTurnText: "첫 질문"
                ),
                executableURL: executable
            )
        )
        let second = try await collectConnectorEvents(
            connector.sendEvents(
                PromptRequest(
                    text: "사용자: 첫 질문\n어시스턴트: 첫 응답\n사용자: 둘째 질문",
                    currentTurnText: "둘째 질문",
                    attachments: [
                        PromptAttachment(
                            url: URL(fileURLWithPath: "/selected/follow-up.swift"),
                            kind: .source,
                            byteCount: 24
                        ),
                    ]
                ),
                executableURL: executable
            )
        )

        #expect(first == [
            .textDelta("안녕"),
            .textDelta("하세요 🌊"),
            .completed(PromptResponse(text: "안녕하세요 🌊")),
        ])
        #expect(second == [
            .textDelta("둘째 응답"),
            .completed(PromptResponse(text: "둘째 응답")),
        ])
        #expect(first.filter(\.isCompletion).count == 1)
        #expect(second.filter(\.isCompletion).count == 1)

        let commands = await runner.commands(for: "claude")
        #expect(commands.count == 2)
        let sessionIDIndex = try #require(
            commands[0].arguments.firstIndex(of: "--session-id")
        )
        let sessionID = commands[0].arguments[sessionIDIndex + 1]
        #expect(UUID(uuidString: sessionID) != nil)
        #expect(commands[0].arguments.contains("stream-json"))
        #expect(commands[0].arguments.contains("--include-partial-messages"))
        #expect(!commands[0].arguments.contains("--safe-mode"))
        #expect(!commands[0].arguments.contains("--resume"))
        #expect(!commands[0].arguments.contains("--no-session-persistence"))
        #expect(commands[0].standardInput == Data("사용자: 첫 질문".utf8))
        let resumeIndex = try #require(
            commands[1].arguments.firstIndex(of: "--resume")
        )
        #expect(commands[1].arguments[resumeIndex + 1] == sessionID)
        #expect(!commands[1].arguments.contains("--session-id"))
        #expect(commands[1].arguments.contains("stream-json"))
        #expect(commands[1].arguments.contains("--include-partial-messages"))
        let resumedInput = String(
            decoding: try #require(commands[1].standardInput),
            as: UTF8.self
        )
        #expect(resumedInput.contains("둘째 질문"))
        #expect(resumedInput.contains("/selected/follow-up.swift"))
        #expect(!resumedInput.contains("첫 질문"))
        #expect(!resumedInput.contains("첫 응답"))
    }

    @Test
    func openCodeContinuesAcrossToolCallStepsUntilVerifiedTerminalFinish() async throws {
        let runner = StructuredConnectorProcessRunner()
        let connector = OpenCodeConnector(processRunner: runner)
        let executable = URL(fileURLWithPath: "/safe/bin/opencode")

        let first = try await collectConnectorEvents(
            connector.sendEvents(
                PromptRequest(text: "첫 질문"),
                executableURL: executable
            )
        )
        let second = try await collectConnectorEvents(
            connector.sendEvents(
                PromptRequest(
                    text: "사용자: 첫 질문\n어시스턴트: 첫 응답\n사용자: 둘째 질문",
                    currentTurnText: "둘째 질문"
                ),
                executableURL: executable
            )
        )

        #expect(first == [
            .textSnapshot("첫"),
            .textSnapshot("첫 응답"),
            .completed(PromptResponse(text: "첫 응답")),
        ])
        #expect(second == [
            .textSnapshot("둘째 응답"),
            .completed(PromptResponse(text: "둘째 응답")),
        ])
        #expect(first.filter(\.isCompletion).count == 1)
        #expect(second.filter(\.isCompletion).count == 1)

        let commands = await runner.commands(for: "opencode")
        #expect(commands.count == 2)
        for command in commands {
            #expect(command.arguments.prefix(4) == ["run", "--pure", "--format", "json"])
            #expect(!command.arguments.contains("--session"))
            #expect(!command.arguments.contains("--continue"))
        }
        #expect(
            commands[1].arguments.last
                == "사용자: 첫 질문\n어시스턴트: 첫 응답\n사용자: 둘째 질문"
        )
    }

    @Test
    func codexAndClaudeDiscardUncommittedSessionsAfterProcessCrash() async throws {
        let codexRunner = CrashRecoveryProcessRunner()
        let codex = CodexConnector(processRunner: codexRunner)
        let codexURL = URL(fileURLWithPath: "/safe/bin/codex")

        do {
            _ = try await collectConnectorEvents(
                codex.sendEvents(
                    PromptRequest(text: "중단될 Codex 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
                    executableURL: codexURL
                )
            )
            Issue.record("Expected the first Codex process to crash")
        } catch let error as AgentConnectorError {
            #expect(error == .failed(exitStatus: 70, message: "fixture crash"))
        } catch {
            Issue.record("Unexpected Codex error: \(error)")
        }
        let recoveredCodex = try await collectConnectorEvents(
            codex.sendEvents(
                PromptRequest(text: "복구된 Codex 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
                executableURL: codexURL
            )
        )
        #expect(recoveredCodex == [
            .textSnapshot("Codex 복구"),
            .completed(PromptResponse(text: "Codex 복구")),
        ])
        let codexCommands = await codexRunner.commands(for: "codex")
        #expect(codexCommands.count == 2)
        #expect(!codexCommands[1].arguments.contains("resume"))
        #expect(codexCommands.allSatisfy { command in
            command.standardInput.map {
                String(decoding: $0, as: UTF8.self).contains("# YumYum Soul")
            } == true
        })

        let claudeRunner = CrashRecoveryProcessRunner()
        let claude = ClaudeCodeConnector(processRunner: claudeRunner)
        let claudeURL = URL(fileURLWithPath: "/safe/bin/claude")

        do {
            _ = try await collectConnectorEvents(
                claude.sendEvents(
                    PromptRequest(text: "중단될 Claude 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
                    executableURL: claudeURL
                )
            )
            Issue.record("Expected the first Claude process to crash")
        } catch let error as AgentConnectorError {
            #expect(error == .failed(exitStatus: 70, message: "fixture crash"))
        } catch {
            Issue.record("Unexpected Claude error: \(error)")
        }
        let recoveredClaude = try await collectConnectorEvents(
            claude.sendEvents(
                PromptRequest(text: "복구된 Claude 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
                executableURL: claudeURL
            )
        )
        #expect(recoveredClaude == [
            .textDelta("Claude 복구"),
            .completed(PromptResponse(text: "Claude 복구")),
        ])
        let claudeCommands = await claudeRunner.commands(for: "claude")
        #expect(claudeCommands.count == 2)
        let firstSessionIndex = try #require(
            claudeCommands[0].arguments.firstIndex(of: "--session-id")
        )
        let secondSessionIndex = try #require(
            claudeCommands[1].arguments.firstIndex(of: "--session-id")
        )
        #expect(
            claudeCommands[0].arguments[firstSessionIndex + 1]
                != claudeCommands[1].arguments[secondSessionIndex + 1]
        )
        #expect(!claudeCommands[1].arguments.contains("--resume"))
        #expect(claudeCommands.allSatisfy { command in
            command.standardInput.map {
                String(decoding: $0, as: UTF8.self).contains("# YumYum Soul")
            } == true
        })
    }

    @Test
    func codexAndClaudeRejectSessionCommitWhenCompletionDeliveryLosesRace() async throws {
        let runner = StructuredConnectorProcessRunner()
        let executableDirectory = URL(fileURLWithPath: "/safe/bin", isDirectory: true)
        let codex = CodexStreamingSession(
            processRunner: runner,
            timeout: .seconds(1),
            outputByteLimit: 4_096
        )

        do {
            _ = try await codex.send(
                PromptRequest(text: "취소된 Codex 요청"),
                executableURL: executableDirectory.appendingPathComponent("codex"),
                onEvent: { _ in },
                acceptCompletion: { _ in false }
            )
            Issue.record("Expected rejected Codex completion delivery to cancel")
        } catch {
            #expect(error is CancellationError)
        }
        _ = try await codex.send(
            PromptRequest(text: "새 Codex 요청"),
            executableURL: executableDirectory.appendingPathComponent("codex"),
            onEvent: { _ in }
        )
        let codexCommands = await runner.commands(for: "codex")
        #expect(codexCommands.count == 2)
        #expect(!codexCommands[1].arguments.contains("resume"))

        let claude = ClaudeStreamingSession(
            processRunner: runner,
            timeout: .seconds(1),
            outputByteLimit: 4_096
        )
        do {
            _ = try await claude.send(
                PromptRequest(text: "취소된 Claude 요청"),
                executableURL: executableDirectory.appendingPathComponent("claude"),
                onEvent: { _ in },
                acceptCompletion: { _ in false }
            )
            Issue.record("Expected rejected Claude completion delivery to cancel")
        } catch {
            #expect(error is CancellationError)
        }
        _ = try await claude.send(
            PromptRequest(text: "새 Claude 요청"),
            executableURL: executableDirectory.appendingPathComponent("claude"),
            onEvent: { _ in }
        )
        let claudeCommands = await runner.commands(for: "claude")
        #expect(claudeCommands.count == 2)
        #expect(!claudeCommands[1].arguments.contains("--resume"))
    }

    @Test
    func runtimeLifecycleDiscardsStructuredSessionsAndClosesIdleHermes() async throws {
        let runner = StructuredConnectorProcessRunner()
        let executableDirectory = URL(fileURLWithPath: "/safe/bin", isDirectory: true)
        let codex = CodexConnector(processRunner: runner)
        _ = try await codex.send(
            PromptRequest(text: "첫 Codex 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
            executableURL: executableDirectory.appendingPathComponent("codex")
        )
        await codex.reset()
        _ = try await codex.send(
            PromptRequest(text: "새 Codex 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
            executableURL: executableDirectory.appendingPathComponent("codex")
        )
        let codexCommands = await runner.commands(for: "codex")
        #expect(codexCommands.count == 2)
        #expect(!codexCommands[1].arguments.contains("resume"))
        #expect(codexCommands.allSatisfy { command in
            command.standardInput.map {
                String(decoding: $0, as: UTF8.self).contains("# YumYum Soul")
            } == true
        })

        let claude = ClaudeCodeConnector(processRunner: runner)
        _ = try await claude.send(
            PromptRequest(text: "첫 Claude 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
            executableURL: executableDirectory.appendingPathComponent("claude")
        )
        await claude.reset()
        _ = try await claude.send(
            PromptRequest(text: "새 Claude 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
            executableURL: executableDirectory.appendingPathComponent("claude")
        )
        let claudeCommands = await runner.commands(for: "claude")
        #expect(claudeCommands.count == 2)
        #expect(!claudeCommands[1].arguments.contains("--resume"))
        #expect(claudeCommands.allSatisfy { command in
            command.standardInput.map {
                String(decoding: $0, as: UTF8.self).contains("# YumYum Soul")
            } == true
        })

        let hermesTransport = RecordingHermesTransport()
        let soulDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: soulDirectory) }
        let soulStore = SoulProfileStore(fileURL: soulDirectory.appendingPathComponent("SOUL.md"))
        try await soulStore.save(SoulProfile(name: "Before Reset"))
        let hermesRuntime = AgentRuntime(
            selection: RuntimeSelection(
                installation: AgentInstallation(
                    definitionID: .hermes,
                    path: "/safe/bin/hermes",
                    version: "1.0.0",
                    runtimeContract: .hermesACP,
                    availability: .available
                )
            ),
            connectors: [HermesACPConnector(transport: hermesTransport)],
            soulStore: soulStore
        )
        _ = try await hermesRuntime.send(PromptRequest(text: "Hermes 요청"))

        try await soulStore.save(SoulProfile(name: "After Reset"))
        await hermesRuntime.reset()
        _ = try await hermesRuntime.send(PromptRequest(text: "새 Hermes 요청"))
        await hermesRuntime.close()

        #expect(await hermesTransport.closeCount == 2)
        #expect(await hermesTransport.invocation?.request.soulMarkdown?.contains("After Reset") == true)
    }

    @Test
    func codexCancellationSuppressesLateEventsAndStartsAFreshSession() async throws {
        let runner = ControlledStreamingProcessRunner()
        let connector = CodexConnector(processRunner: runner)
        let executable = URL(fileURLWithPath: "/safe/bin/codex")
        let cancelledEvents = LockedConnectorEvents()

        let cancelled = Task {
            do {
                for try await event in connector.sendEvents(
                    PromptRequest(text: "취소할 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
                    executableURL: executable
                ) {
                    cancelledEvents.append(event)
                }
            } catch {
                #expect(error is CancellationError)
            }
        }
        await runner.waitForInvocationCount(1)
        await runner.emit(
            [
                #"{"type":"thread.started","thread_id":"cancelled-codex"}"#,
                #"{"type":"item.updated","item":{"id":"item-1","type":"agent_message","text":"취소 전 부분"}}"#,
            ].joined(separator: "\n") + "\n",
            at: 0
        )
        await cancelledEvents.waitForCount(1)
        cancelled.cancel()
        await runner.waitForCancellationCount(1)
        await cancelled.value

        await runner.emit(
            [
                #"{"type":"item.updated","item":{"id":"item-1","type":"agent_message","text":"취소 후 늦은 변경"}}"#,
                #"{"type":"turn.completed","usage":{}}"#,
            ].joined(separator: "\n") + "\n",
            at: 0
        )

        let recoveredTask = Task {
            try await collectConnectorEvents(
                connector.sendEvents(
                    PromptRequest(text: "새 요청", soulMarkdown: SoulProfile(name: "Momo").normalized.markdown),
                    executableURL: executable
                )
            )
        }
        await runner.waitForInvocationCount(2)
        let recoveredOutput = [
            #"{"type":"thread.started","thread_id":"fresh-codex"}"#,
            #"{"type":"item.completed","item":{"id":"item-2","type":"agent_message","text":"새 응답"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ].joined(separator: "\n") + "\n"
        await runner.emit(recoveredOutput, at: 1)
        await runner.succeed(output: recoveredOutput, at: 1)

        #expect(cancelledEvents.values() == [.textSnapshot("취소 전 부분")])
        #expect(try await recoveredTask.value == [
            .textSnapshot("새 응답"),
            .completed(PromptResponse(text: "새 응답")),
        ])
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(!commands[1].arguments.contains("resume"))
        #expect(commands.allSatisfy { command in
            command.standardInput.map {
                String(decoding: $0, as: UTF8.self).contains("# YumYum Soul")
            } == true
        })
    }
}

private extension PromptResponseEvent {
    var isCompletion: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

private func collectConnectorEvents(
    _ stream: PromptResponseEventStream
) async throws -> [PromptResponseEvent] {
    var events: [PromptResponseEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private actor RuntimeSelection: AgentSelectionValidating {
    private var result: Result<AgentInstallation, AgentSelectionError>
    private(set) var validationCount = 0

    init(installation: AgentInstallation) {
        result = .success(installation)
    }

    func validatedSelection() async throws -> AgentInstallation {
        validationCount += 1
        return try result.get()
    }

    func setResult(_ result: Result<AgentInstallation, AgentSelectionError>) {
        self.result = result
    }
}

private actor RuntimeConnector: AgentConnecting {
    nonisolated let definitionID: AgentDefinitionID
    private(set) var requests: [PromptRequest] = []
    private(set) var executablePaths: [String] = []

    init(definitionID: AgentDefinitionID) {
        self.definitionID = definitionID
    }

    func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        requests.append(request)
        executablePaths.append(executableURL.path)
        return PromptResponse(text: "\(definitionID.displayName) response")
    }
}

private struct RuntimeEventConnector: AgentConnecting {
    let definitionID: AgentDefinitionID
    let events: [PromptResponseEvent]

    func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        PromptResponse(text: "legacy response")
    }

    func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> AsyncThrowingStream<PromptResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private actor ConnectorProcessRunner: ProcessRunning {
    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration?
    }

    private(set) var invocations: [Invocation] = []

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        invocations.append(Invocation(command: command, timeout: timeout))
        let output: String
        switch command.executableURL.lastPathComponent {
        case "opencode":
            output = [
                #"{"type":"step_start","sessionID":"contract-session"}"#,
                #"{"type":"text","sessionID":"contract-session","part":{"id":"part-1","type":"text","text":"완료"}}"#,
                #"{"type":"step_finish","sessionID":"contract-session","part":{"type":"step-finish","reason":"stop"}}"#,
            ].joined(separator: "\n") + "\n"
        case "codex":
            output = [
                #"{"type":"thread.started","thread_id":"contract-session"}"#,
                #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"완료"}}"#,
                #"{"type":"turn.completed","usage":{}}"#,
            ].joined(separator: "\n") + "\n"
        case "claude":
            let sessionIndex = command.arguments.firstIndex(of: "--session-id")
            let sessionID = sessionIndex.map { command.arguments[$0 + 1] } ?? ""
            output = [
                #"{"type":"system","subtype":"init","session_id":"\#(sessionID)"}"#,
                #"{"type":"result","subtype":"success","is_error":false,"session_id":"\#(sessionID)","result":"완료"}"#,
            ].joined(separator: "\n") + "\n"
        default:
            output = "완료"
        }
        return ProcessRunResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }
}

private actor StructuredConnectorProcessRunner: ProcessRunning {
    private var recordedCommands: [ProcessCommand] = []
    private var invocationCounts: [String: Int] = [:]

    func run(
        _ command: ProcessCommand,
        timeout: Duration?
    ) async throws -> ProcessRunResult {
        let output = scriptedOutput(for: command)
        recordedCommands.append(command)
        return ProcessRunResult(
            standardOutput: output,
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }

    func runStreaming(
        _ command: ProcessCommand,
        timeout: Duration?,
        onStandardOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> ProcessRunResult {
        let output = scriptedOutput(for: command)
        recordedCommands.append(command)
        for chunk in fragmented(output) {
            onStandardOutput(chunk)
            await Task.yield()
        }
        return ProcessRunResult(
            standardOutput: output,
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }

    func commands(for executableName: String) -> [ProcessCommand] {
        recordedCommands.filter { $0.executableURL.lastPathComponent == executableName }
    }

    private func scriptedOutput(for command: ProcessCommand) -> Data {
        let executable = command.executableURL.lastPathComponent
        let invocation = invocationCounts[executable, default: 0]
        invocationCounts[executable] = invocation + 1
        switch executable {
        case "opencode":
            return openCodeOutput(invocation: invocation)
        case "codex":
            return codexOutput(invocation: invocation)
        case "claude":
            return claudeOutput(command: command, invocation: invocation)
        default:
            return Data()
        }
    }

    private func openCodeOutput(invocation: Int) -> Data {
        let values = invocation == 0 ? ["첫", "첫 응답"] : ["둘째 응답"]
        var lines = [
            #"{"type":"step_start","sessionID":"opencode-session-\#(invocation)"}"#,
        ]
        if invocation == 0 {
            lines.append(
                #"{"type":"step_start","sessionID":"stale-opencode-session"}"#
            )
            lines.append(
                #"{"type":"step_finish","sessionID":"opencode-session-0","part":{"type":"step-finish","reason":"tool-calls"}}"#
            )
            lines.append(
                #"{"type":"step_start","sessionID":"opencode-session-0"}"#
            )
        }
        lines.append(contentsOf: values.map { value in
            #"{"type":"text","sessionID":"opencode-session-\#(invocation)","part":{"id":"part-1","type":"text","text":"\#(value)"}}"#
        })
        lines.append(
            #"{"type":"step_finish","sessionID":"opencode-session-\#(invocation)","part":{"type":"step-finish","reason":"stop"}}"#
        )
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func codexOutput(invocation: Int) -> Data {
        let lines: [String]
        if invocation == 0 {
            lines = [
                #"{"type":"thread.started","thread_id":"codex-session-1"}"#,
                #"{"type":"item.started","item":{"id":"item-1","type":"agent_message","text":""}}"#,
                #"{"type":"item.updated","item":{"id":"item-1","type":"agent_message","text":"안녕"}}"#,
                #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"안녕하세요 👋"}}"#,
                #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}"#,
            ]
        } else {
            lines = [
                #"{"type":"thread.started","thread_id":"codex-session-1"}"#,
                #"{"type":"item.completed","item":{"id":"item-2","type":"agent_message","text":"둘째 응답"}}"#,
                #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}"#,
            ]
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func claudeOutput(command: ProcessCommand, invocation: Int) -> Data {
        let sessionID: String
        if let index = command.arguments.firstIndex(of: "--session-id"),
           command.arguments.indices.contains(index + 1) {
            sessionID = command.arguments[index + 1]
        } else if let index = command.arguments.firstIndex(of: "--resume"),
                  command.arguments.indices.contains(index + 1) {
            sessionID = command.arguments[index + 1]
        } else {
            sessionID = "00000000-0000-0000-0000-000000000001"
        }
        let deltas = invocation == 0 ? ["안녕", "하세요 🌊"] : ["둘째 응답"]
        let result = deltas.joined()
        var lines = [
            #"{"type":"system","subtype":"init","session_id":"\#(sessionID)"}"#,
        ]
        lines.append(contentsOf: deltas.map { delta in
            #"{"type":"stream_event","session_id":"\#(sessionID)","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(delta)"}}}"#
        })
        lines.append(
            #"{"type":"assistant","session_id":"\#(sessionID)","message":{"role":"assistant","content":[{"type":"text","text":"\#(result)"}]}}"#
        )
        lines.append(
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"\#(sessionID)","result":"\#(result)"}"#
        )
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func fragmented(_ data: Data) -> [Data] {
        let widths = [1, 2, 5, 3, 8, 1, 13]
        var chunks: [Data] = []
        var offset = 0
        var widthIndex = 0
        while offset < data.count {
            let width = min(widths[widthIndex % widths.count], data.count - offset)
            chunks.append(data.subdata(in: offset..<(offset + width)))
            offset += width
            widthIndex += 1
        }
        return chunks
    }
}

private actor CrashRecoveryProcessRunner: ProcessRunning {
    private var recordedCommands: [ProcessCommand] = []
    private var invocationCounts: [String: Int] = [:]

    func run(
        _ command: ProcessCommand,
        timeout: Duration?
    ) async throws -> ProcessRunResult {
        try await runStreaming(
            command,
            timeout: timeout,
            onStandardOutput: { _ in }
        )
    }

    func runStreaming(
        _ command: ProcessCommand,
        timeout: Duration?,
        onStandardOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> ProcessRunResult {
        recordedCommands.append(command)
        let executable = command.executableURL.lastPathComponent
        let invocation = invocationCounts[executable, default: 0]
        invocationCounts[executable] = invocation + 1
        let output: Data
        if executable == "codex" {
            let sessionID = invocation == 0 ? "crashed-codex" : "recovered-codex"
            var lines = [
                #"{"type":"thread.started","thread_id":"\#(sessionID)"}"#,
            ]
            if invocation > 0 {
                lines.append(
                    #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"Codex 복구"}}"#
                )
                lines.append(#"{"type":"turn.completed","usage":{}}"#)
            }
            output = Data((lines.joined(separator: "\n") + "\n").utf8)
        } else {
            let sessionIndex = command.arguments.firstIndex(of: "--session-id")
            let sessionID = sessionIndex.map { command.arguments[$0 + 1] } ?? ""
            var lines = [
                #"{"type":"system","subtype":"init","session_id":"\#(sessionID)"}"#,
            ]
            if invocation > 0 {
                lines.append(
                    #"{"type":"stream_event","session_id":"\#(sessionID)","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Claude 복구"}}}"#
                )
                lines.append(
                    #"{"type":"result","subtype":"success","is_error":false,"session_id":"\#(sessionID)","result":"Claude 복구"}"#
                )
            }
            output = Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        onStandardOutput(output)
        return ProcessRunResult(
            standardOutput: output,
            standardError: invocation == 0 ? Data("fixture crash".utf8) : Data(),
            termination: .exited(status: invocation == 0 ? 70 : 0)
        )
    }

    func commands(for executableName: String) -> [ProcessCommand] {
        recordedCommands.filter { $0.executableURL.lastPathComponent == executableName }
    }
}

private final class LockedConnectorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PromptResponseEvent] = []

    func append(_ event: PromptResponseEvent) {
        lock.withLock { events.append(event) }
    }

    func values() -> [PromptResponseEvent] {
        lock.withLock { events }
    }

    func waitForCount(_ count: Int) async {
        for _ in 0..<10_000 {
            if values().count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for connector events")
    }
}

private actor ControlledStreamingProcessRunner: ProcessRunning {
    private(set) var commands: [ProcessCommand] = []
    private var callbacks: [@Sendable (Data) -> Void] = []
    private var continuations: [
        CheckedContinuation<ProcessRunResult, any Error>?
    ] = []
    private var cancelled: Set<Int> = []
    private var cancellationCount = 0

    func run(
        _ command: ProcessCommand,
        timeout: Duration?
    ) async throws -> ProcessRunResult {
        try await runStreaming(
            command,
            timeout: timeout,
            onStandardOutput: { _ in }
        )
    }

    func runStreaming(
        _ command: ProcessCommand,
        timeout: Duration?,
        onStandardOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> ProcessRunResult {
        let index = commands.count
        commands.append(command)
        callbacks.append(onStandardOutput)
        continuations.append(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled.contains(index) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[index] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(at: index) }
        }
    }

    func emit(_ value: String, at index: Int) {
        callbacks[index](Data(value.utf8))
    }

    func succeed(output: String, at index: Int) {
        guard let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume(returning: ProcessRunResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            termination: .exited(status: 0)
        ))
    }

    func waitForInvocationCount(_ count: Int) async {
        for _ in 0..<10_000 {
            if commands.count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for process invocation")
    }

    func waitForCancellationCount(_ count: Int) async {
        for _ in 0..<10_000 {
            if cancellationCount >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for process cancellation")
    }

    private func cancel(at index: Int) {
        cancelled.insert(index)
        cancellationCount += 1
        guard let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume(throwing: CancellationError())
    }
}

private actor RecordingHermesTransport: HermesACPTransporting {
    struct Invocation: Sendable {
        let request: PromptRequest
        let executableURL: URL
    }

    private(set) var invocation: Invocation?
    private(set) var closeCount = 0

    func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse {
        invocation = Invocation(request: request, executableURL: executableURL)
        return PromptResponse(text: "완료")
    }

    func close() {
        closeCount += 1
    }
}
