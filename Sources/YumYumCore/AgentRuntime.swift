import Foundation

public enum PromptAttachmentKind: String, Equatable, Sendable {
    case image
    case pdf
    case plainText
    case source
}

public struct PromptAttachment: Equatable, Sendable {
    public let url: URL
    public let kind: PromptAttachmentKind
    public let byteCount: Int64
    public let isTemporary: Bool

    public init(
        url: URL,
        kind: PromptAttachmentKind,
        byteCount: Int64,
        isTemporary: Bool = false
    ) {
        self.url = url.standardizedFileURL
        self.kind = kind
        self.byteCount = byteCount
        self.isTemporary = isTemporary
    }
}

public struct PromptRequest: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let attachments: [PromptAttachment]

    public init(
        id: UUID = UUID(),
        text: String,
        attachments: [PromptAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}

public struct PromptResponse: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum AgentConnectorError: Error, Equatable, LocalizedError, Sendable {
    case timedOut
    case failed(exitStatus: Int32?, message: String)
    case emptyResponse
    case launchFailed(String)
    case hermesACPUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            "에이전트 응답 시간이 초과되었습니다."
        case let .failed(exitStatus, message):
            "에이전트 실행이 실패했습니다(\(exitStatus.map(String.init) ?? "알 수 없음")): \(message)"
        case .emptyResponse:
            "에이전트가 응답 텍스트를 반환하지 않았습니다."
        case let .launchFailed(message):
            "에이전트 프로세스를 시작하지 못했습니다: \(message)"
        case let .hermesACPUnavailable(reason):
            "Hermes ACP를 사용할 수 없습니다: \(reason)"
        }
    }
}

public protocol AgentConnecting: Sendable {
    var definitionID: AgentDefinitionID { get }

    func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse
}

public protocol HermesACPTransporting: Sendable {
    func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse
}

public enum AgentRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case connectorUnavailable(AgentDefinitionID)
    case invalidSelectedPath(String?)

    public var errorDescription: String? {
        switch self {
        case let .connectorUnavailable(definitionID):
            "\(definitionID.displayName) 전용 Connector를 사용할 수 없습니다."
        case let .invalidSelectedPath(path):
            "선택한 에이전트의 정확한 절대 경로가 유효하지 않습니다: \(path ?? "없음")"
        }
    }
}

public struct AgentRuntime: Sendable {
    private let selection: any AgentSelectionValidating
    private let connectors: [AgentDefinitionID: any AgentConnecting]

    public init(
        selection: any AgentSelectionValidating,
        connectors: [any AgentConnecting]
    ) {
        self.selection = selection
        var connectorMap: [AgentDefinitionID: any AgentConnecting] = [:]
        for connector in connectors {
            connectorMap[connector.definitionID] = connector
        }
        self.connectors = connectorMap
    }

    public func send(_ request: PromptRequest) async throws -> PromptResponse {
        let installation = try await selection.validatedSelection()
        guard let connector = connectors[installation.definitionID] else {
            throw AgentRuntimeError.connectorUnavailable(installation.definitionID)
        }
        guard let path = installation.path,
              NSString(string: path).isAbsolutePath else {
            throw AgentRuntimeError.invalidSelectedPath(installation.path)
        }
        return try await connector.send(
            request,
            executableURL: URL(fileURLWithPath: path).standardizedFileURL
        )
    }
}

public struct HermesACPConnector: AgentConnecting, Sendable {
    public let definitionID = AgentDefinitionID.hermes

    private let transport: any HermesACPTransporting
    private let timeout: Duration
    private let outputByteLimit: Int

    public init(
        transport: any HermesACPTransporting,
        timeout: Duration = .seconds(120),
        outputByteLimit: Int = 2_097_152
    ) {
        self.transport = transport
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        try await transport.send(
            request,
            executableURL: executableURL,
            environment: AgentProcessEnvironment.make(
                executableDirectory: executableURL.deletingLastPathComponent()
            ),
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }
}

public struct OpenCodeConnector: AgentConnecting, Sendable {
    public let definitionID = AgentDefinitionID.openCode

    private let processRunner: any ProcessRunning
    private let timeout: Duration
    private let outputByteLimit: Int

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(120),
        outputByteLimit: Int = 2_097_152
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        var arguments = ["run", "--pure", "--format", "default"]
        for attachment in request.attachments {
            arguments.append(contentsOf: ["--file", attachment.url.path])
        }
        arguments.append(promptText(for: request))
        return try await runCLI(
            executableURL: executableURL,
            arguments: arguments,
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }
}

public struct CodexConnector: AgentConnecting, Sendable {
    public let definitionID = AgentDefinitionID.codex

    private let processRunner: any ProcessRunning
    private let timeout: Duration
    private let outputByteLimit: Int

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(120),
        outputByteLimit: Int = 2_097_152
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        var arguments = [
            "--ask-for-approval", "untrusted",
            "exec",
            "--ephemeral",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
        ]
        let images = request.attachments.filter { $0.kind == .image }
        for image in images {
            arguments.append(contentsOf: ["--image", image.url.path])
        }
        arguments.append(
            promptText(
                for: request,
                visibleAttachments: request.attachments.filter { $0.kind != .image }
            )
        )
        return try await runCLI(
            executableURL: executableURL,
            arguments: arguments,
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }
}

public struct ClaudeCodeConnector: AgentConnecting, Sendable {
    public let definitionID = AgentDefinitionID.claudeCode

    private let processRunner: any ProcessRunning
    private let timeout: Duration
    private let outputByteLimit: Int

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(120),
        outputByteLimit: Int = 2_097_152
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        let arguments = [
            "--safe-mode",
            "--print",
            "--output-format", "text",
            "--permission-mode", "plan",
            "--no-session-persistence",
            promptText(for: request, visibleAttachments: request.attachments),
        ]
        return try await runCLI(
            executableURL: executableURL,
            arguments: arguments,
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }
}

private func promptText(
    for request: PromptRequest,
    visibleAttachments: [PromptAttachment] = []
) -> String {
    let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    var prompt = trimmed.isEmpty ? "선택한 첨부 파일을 분석해 주세요." : trimmed
    guard !visibleAttachments.isEmpty else {
        return prompt
    }

    prompt += "\n\n사용자가 명시적으로 선택한 로컬 첨부 파일 경로입니다. 이 경로만 입력 자료로 사용하세요:"
    for attachment in visibleAttachments {
        prompt += "\n- \(attachment.url.path)"
    }
    return prompt
}

private func runCLI(
    executableURL: URL,
    arguments: [String],
    processRunner: any ProcessRunning,
    timeout: Duration,
    outputByteLimit: Int
) async throws -> PromptResponse {
    let result: ProcessRunResult
    do {
        result = try await processRunner.run(
            ProcessCommand(
                executableURL: executableURL,
                arguments: arguments,
                environment: AgentProcessEnvironment.make(
                    executableDirectory: executableURL.deletingLastPathComponent()
                ),
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                outputByteLimit: outputByteLimit
            ),
            timeout: timeout
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw AgentConnectorError.launchFailed(String(describing: error))
    }

    if result.timedOut {
        throw AgentConnectorError.timedOut
    }
    let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let standardError = String(decoding: result.standardError, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.exitStatus == 0 else {
        throw AgentConnectorError.failed(
            exitStatus: result.exitStatus,
            message: standardError.isEmpty ? standardOutput : standardError
        )
    }
    guard !standardOutput.isEmpty else {
        throw AgentConnectorError.emptyResponse
    }
    return PromptResponse(text: standardOutput)
}
