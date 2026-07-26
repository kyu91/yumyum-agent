import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AgentConnectorTests {
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
        #expect(await openCode.requests == [request])
        #expect(await openCode.executablePaths == ["/selected/opencode"])
        #expect(await codex.requests.isEmpty)
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
                    "run", "--pure", "--format", "default",
                    "--file", "/selected/screen.png",
                    "--file", "/selected/code.swift",
                    "이 자료를 설명해줘",
                ]
        )

        let codex = invocations[1].command
        #expect(codex.executableURL.path == "/safe/bin/codex")
        #expect(codex.arguments.prefix(7) == [
            "--ask-for-approval", "untrusted", "exec", "--ephemeral", "--sandbox", "read-only",
            "--skip-git-repo-check",
        ])
        #expect(codex.arguments.contains("--image"))
        #expect(codex.arguments.contains("/selected/screen.png"))
        #expect(codex.arguments.last?.contains("/selected/code.swift") == true)

        let claude = invocations[2].command
        #expect(claude.executableURL.path == "/safe/bin/claude")
        #expect(claude.arguments.prefix(7) == [
            "--safe-mode", "--print", "--output-format", "text",
            "--permission-mode", "plan", "--no-session-persistence",
        ])
        #expect(claude.arguments.last?.contains("/selected/screen.png") == true)
        #expect(claude.arguments.last?.contains("/selected/code.swift") == true)

        for invocation in invocations {
            #expect(invocation.timeout == .seconds(120))
            #expect(invocation.command.outputByteLimit == 2_097_152)
            #expect(invocation.command.environment?.keys.sorted() == [
                "HOME", "LANG", "LC_ALL", "PATH", "TERM",
            ])
            #expect(invocation.command.executableURL.path != "/bin/sh")
        }
    }
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

private actor ConnectorProcessRunner: ProcessRunning {
    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration?
    }

    private(set) var invocations: [Invocation] = []

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        invocations.append(Invocation(command: command, timeout: timeout))
        return ProcessRunResult(
            standardOutput: Data("완료".utf8),
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }
}

private actor RecordingHermesTransport: HermesACPTransporting {
    struct Invocation: Sendable {
        let request: PromptRequest
        let executableURL: URL
    }

    private(set) var invocation: Invocation?

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
}
