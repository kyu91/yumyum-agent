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
    public let currentTurnText: String?
    public let attachments: [PromptAttachment]
    public let soulMarkdown: String?

    public init(
        id: UUID = UUID(),
        text: String,
        currentTurnText: String? = nil,
        attachments: [PromptAttachment] = [],
        soulMarkdown: String? = nil
    ) {
        self.id = id
        self.text = text
        self.currentTurnText = currentTurnText
        self.attachments = attachments
        self.soulMarkdown = soulMarkdown
    }
}

public struct PromptResponse: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum PromptResponseEvent: Equatable, Sendable {
    case textDelta(String)
    case textSnapshot(String)
    case completed(PromptResponse)
}

public typealias PromptResponseEventStream = AsyncThrowingStream<
    PromptResponseEvent,
    Error
>

func completedPromptResponseEvents(
    _ operation: @escaping @Sendable () async throws -> PromptResponse
) -> PromptResponseEventStream {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                continuation.yield(.completed(try await operation()))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
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
            AppText.localized("에이전트 응답 시간이 초과되었습니다.")
        case let .failed(exitStatus, message):
            AppText.localized(english: "Agent execution failed (\(exitStatus.map(String.init) ?? "unknown")): \(message)", korean: "에이전트 실행이 실패했습니다(\(exitStatus.map(String.init) ?? "알 수 없음")): \(message)")
        case .emptyResponse:
            AppText.localized("에이전트가 응답 텍스트를 반환하지 않았습니다.")
        case let .launchFailed(message):
            AppText.localized(english: "Could not start the agent process: \(message)", korean: "에이전트 프로세스를 시작하지 못했습니다: \(message)")
        case let .hermesACPUnavailable(reason):
            AppText.localized(english: "Hermes ACP is unavailable: \(reason)", korean: "Hermes ACP를 사용할 수 없습니다: \(reason)")
        }
    }
}

public protocol AgentConnecting: Sendable {
    var definitionID: AgentDefinitionID { get }

    func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse

    func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> PromptResponseEventStream

    func reset() async
    func close() async
}

public extension AgentConnecting {
    func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> PromptResponseEventStream {
        completedPromptResponseEvents {
            try await send(request, executableURL: executableURL)
        }
    }

    func reset() async {}

    func close() async {
        await reset()
    }
}

public protocol HermesACPTransporting: Sendable {
    func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse

    func sendEvents(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) -> PromptResponseEventStream

    func close() async
}

public extension HermesACPTransporting {
    func sendEvents(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) -> PromptResponseEventStream {
        completedPromptResponseEvents {
            try await send(
                request,
                executableURL: executableURL,
                environment: environment,
                timeout: timeout,
                outputByteLimit: outputByteLimit
            )
        }
    }

    func close() async {}
}

public enum AgentRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case connectorUnavailable(AgentDefinitionID)
    case invalidSelectedPath(String?)

    public var errorDescription: String? {
        switch self {
        case let .connectorUnavailable(definitionID):
            AppText.localized(english: "No connector is available for \(definitionID.displayName).", korean: "\(definitionID.displayName) 전용 Connector를 사용할 수 없습니다.")
        case let .invalidSelectedPath(path):
            AppText.localized(english: "The selected agent's exact absolute path is invalid: \(path ?? "none")", korean: "선택한 에이전트의 정확한 절대 경로가 유효하지 않습니다: \(path ?? "없음")")
        }
    }
}

public struct AgentRuntime: Sendable {
    private let selection: any AgentSelectionValidating
    private let connectors: [AgentDefinitionID: any AgentConnecting]
    private let soulStore: (any SoulProfileStoring)?

    public init(
        selection: any AgentSelectionValidating,
        connectors: [any AgentConnecting],
        soulStore: (any SoulProfileStoring)? = nil
    ) {
        self.selection = selection
        self.soulStore = soulStore
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
            await requestWithSoul(request),
            executableURL: URL(fileURLWithPath: path).standardizedFileURL
        )
    }

    public func sendEvents(_ request: PromptRequest) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let installation = try await selection.validatedSelection()
                    guard let connector = connectors[installation.definitionID] else {
                        throw AgentRuntimeError.connectorUnavailable(
                            installation.definitionID
                        )
                    }
                    guard let path = installation.path,
                          NSString(string: path).isAbsolutePath else {
                        throw AgentRuntimeError.invalidSelectedPath(installation.path)
                    }
                    let events = connector.sendEvents(
                        await requestWithSoul(request),
                        executableURL: URL(fileURLWithPath: path).standardizedFileURL
                    )
                    for try await event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reset() async {
        for connector in connectors.values {
            await connector.reset()
        }
    }

    public func close() async {
        for connector in connectors.values {
            await connector.close()
        }
    }

    private func requestWithSoul(_ request: PromptRequest) async -> PromptRequest {
        guard let profile = await soulStore?.load(), !profile.isEmpty else { return request }
        return PromptRequest(
            id: request.id,
            text: request.text,
            currentTurnText: request.currentTurnText,
            attachments: request.attachments,
            soulMarkdown: profile.markdown
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

    public func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> PromptResponseEventStream {
        transport.sendEvents(
            request,
            executableURL: executableURL,
            environment: AgentProcessEnvironment.make(
                executableDirectory: executableURL.deletingLastPathComponent()
            ),
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }

    public func reset() async {
        await transport.close()
    }

    public func close() async {
        await transport.close()
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
        try await runOpenCodeStreaming(
            request,
            executableURL: executableURL,
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit,
            onEvent: { _ in }
        )
    }

    public func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await runOpenCodeStreaming(
                        request,
                        executableURL: executableURL,
                        processRunner: processRunner,
                        timeout: timeout,
                        outputByteLimit: outputByteLimit,
                        onEvent: { continuation.yield($0) }
                    )
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}

public struct CodexConnector: AgentConnecting, Sendable {
    public let definitionID = AgentDefinitionID.codex

    private let session: CodexStreamingSession

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(120),
        outputByteLimit: Int = 2_097_152
    ) {
        session = CodexStreamingSession(
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        try await session.send(
            request,
            executableURL: executableURL,
            onEvent: { _ in }
        )
    }

    public func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await session.send(
                        request,
                        executableURL: executableURL,
                        onEvent: { continuation.yield($0) },
                        acceptCompletion: { response in
                            guard !Task.isCancelled else {
                                return false
                            }
                            switch continuation.yield(.completed(response)) {
                            case .enqueued:
                                return true
                            case .dropped, .terminated:
                                return false
                            @unknown default:
                                return false
                            }
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reset() async {
        await session.reset()
    }
}

public struct ClaudeCodeConnector: AgentConnecting, Sendable {
    public let definitionID = AgentDefinitionID.claudeCode

    private let session: ClaudeStreamingSession

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(120),
        outputByteLimit: Int = 2_097_152
    ) {
        session = ClaudeStreamingSession(
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit
        )
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        try await session.send(
            request,
            executableURL: executableURL,
            onEvent: { _ in }
        )
    }

    public func sendEvents(
        _ request: PromptRequest,
        executableURL: URL
    ) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await session.send(
                        request,
                        executableURL: executableURL,
                        onEvent: { continuation.yield($0) },
                        acceptCompletion: { response in
                            guard !Task.isCancelled else {
                                return false
                            }
                            switch continuation.yield(.completed(response)) {
                            case .enqueued:
                                return true
                            case .dropped, .terminated:
                                return false
                            @unknown default:
                                return false
                            }
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func reset() async {
        await session.reset()
    }
}

func promptText(
    for request: PromptRequest,
    text: String? = nil,
    visibleAttachments: [PromptAttachment] = []
) -> String {
    let trimmed = (text ?? request.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var prompt = trimmed.isEmpty ? "Analyze the selected attachments." : trimmed
    guard !visibleAttachments.isEmpty else {
        return prompt
    }

    prompt += "\n\nThese are paths to local attachments explicitly selected by the user. Use only these paths as input:"
    for attachment in visibleAttachments {
        prompt += "\n- \(attachment.url.path)"
    }
    return prompt
}

func firstSessionPromptText(
    for request: PromptRequest,
    text: String? = nil,
    visibleAttachments: [PromptAttachment] = []
) -> String {
    let prompt = promptText(
        for: request,
        text: text,
        visibleAttachments: visibleAttachments
    )
    guard let soul = request.soulMarkdown, !soul.isEmpty else { return prompt }
    return "\(soul)\n---\n\n# User Request\n\n\(prompt)"
}
