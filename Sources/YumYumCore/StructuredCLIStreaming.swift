import Foundation

func runOpenCodeStreaming(
    _ request: PromptRequest,
    executableURL: URL,
    processRunner: any ProcessRunning,
    timeout: Duration,
    outputByteLimit: Int,
    onEvent: @escaping @Sendable (PromptResponseEvent) -> Void
) async throws -> PromptResponse {
    let parser = OpenCodeJSONStreamParser(onEvent: onEvent)
    var arguments = ["run", "--pure", "--format", "json"]
    for attachment in request.attachments {
        arguments.append(contentsOf: ["--file", attachment.url.path])
    }
    arguments.append(firstSessionPromptText(for: request))

    do {
        let result = try await runStreamingProcess(
            executableURL: executableURL.standardizedFileURL,
            arguments: arguments,
            processRunner: processRunner,
            timeout: timeout,
            outputByteLimit: outputByteLimit,
            onStandardOutput: { parser.consume($0) }
        )
        try Task.checkCancellation()
        try validateStructuredProcessResult(result)
        let parsed = try parser.finish()
        guard parsed.didFinish else {
            throw StructuredCLIParseError.missingCompletion
        }
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentConnectorError.emptyResponse
        }
        return PromptResponse(text: text)
    } catch is CancellationError {
        parser.deactivate()
        throw CancellationError()
    } catch let error as AgentConnectorError {
        parser.deactivate()
        throw error
    } catch let error as StructuredCLIParseError {
        parser.deactivate()
        throw AgentConnectorError.failed(
            exitStatus: nil,
            message: error.localizedDescription
        )
    } catch {
        parser.deactivate()
        throw AgentConnectorError.launchFailed(String(describing: error))
    }
}

actor CodexStreamingSession {
    private let processRunner: any ProcessRunning
    private let timeout: Duration
    private let outputByteLimit: Int
    private var executableURL: URL?
    private var sessionID: String?
    private var activeGeneration: UUID?

    init(
        processRunner: any ProcessRunning,
        timeout: Duration,
        outputByteLimit: Int
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }

    func send(
        _ request: PromptRequest,
        executableURL: URL,
        onEvent: @escaping @Sendable (PromptResponseEvent) -> Void,
        acceptCompletion: @Sendable (PromptResponse) -> Bool = { _ in true }
    ) async throws -> PromptResponse {
        try Task.checkCancellation()
        let executableURL = executableURL.standardizedFileURL
        if self.executableURL != executableURL {
            self.executableURL = executableURL
            sessionID = nil
        }
        let generation = UUID()
        if activeGeneration != nil {
            sessionID = nil
        }
        activeGeneration = generation
        let resumedSessionID = sessionID
        // Codex CLI forks a new thread_id when `--image` is combined with `resume`,
        // even though it correctly continues the resumed conversation; don't reject it.
        let hasImageAttachment = request.attachments.contains { $0.kind == .image }
        let parser = CodexJSONStreamParser(
            expectedSessionID: hasImageAttachment ? nil : resumedSessionID,
            onEvent: onEvent
        )

        var arguments = [
            "--ask-for-approval", "untrusted", "exec",
            "--json",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
        ]
        for image in request.attachments where image.kind == .image {
            arguments.append(contentsOf: ["--image", image.url.path])
        }
        if let resumedSessionID {
            arguments.append(contentsOf: ["resume", resumedSessionID])
        }
        let inputText = resumedSessionID == nil ? firstSessionPromptText(
                for: request,
                text: request.text,
                visibleAttachments: request.attachments.filter { $0.kind != .image }
            ) : promptText(
                for: request,
                text: request.currentTurnText ?? request.text,
                visibleAttachments: request.attachments.filter { $0.kind != .image }
            )
        let standardInput = Data(inputText.utf8)

        do {
            let result = try await runStreamingProcess(
                executableURL: executableURL,
                arguments: arguments,
                processRunner: processRunner,
                timeout: timeout,
                outputByteLimit: outputByteLimit,
                standardInput: standardInput,
                onStandardOutput: { parser.consume($0) }
            )
            try Task.checkCancellation()
            try validateStructuredProcessResult(result)
            let parsed = try parser.finish()
            guard parsed.didCompleteTurn else {
                throw StructuredCLIParseError.missingCompletion
            }
            guard let newSessionID = parsed.sessionID, !newSessionID.isEmpty else {
                throw StructuredCLIParseError.missingSessionID
            }
            let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AgentConnectorError.emptyResponse
            }
            guard activeGeneration == generation else {
                throw CancellationError()
            }
            let response = PromptResponse(text: text)
            guard !Task.isCancelled, acceptCompletion(response) else {
                throw CancellationError()
            }
            sessionID = newSessionID
            activeGeneration = nil
            return response
        } catch is CancellationError {
            parser.deactivate()
            discardSession(generation: generation)
            throw CancellationError()
        } catch let error as AgentConnectorError {
            parser.deactivate()
            discardSession(generation: generation)
            throw error
        } catch let error as StructuredCLIParseError {
            parser.deactivate()
            discardSession(generation: generation)
            throw AgentConnectorError.failed(
                exitStatus: nil,
                message: error.localizedDescription
            )
        } catch {
            parser.deactivate()
            discardSession(generation: generation)
            throw AgentConnectorError.launchFailed(String(describing: error))
        }
    }

    private func discardSession(generation: UUID) {
        guard activeGeneration == generation else {
            return
        }
        sessionID = nil
        activeGeneration = nil
    }

    func reset() {
        executableURL = nil
        sessionID = nil
        activeGeneration = nil
    }
}

actor ClaudeStreamingSession {
    private let processRunner: any ProcessRunning
    private let timeout: Duration
    private let outputByteLimit: Int
    private var executableURL: URL?
    private var sessionID: String?
    private var activeGeneration: UUID?

    init(
        processRunner: any ProcessRunning,
        timeout: Duration,
        outputByteLimit: Int
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }

    func send(
        _ request: PromptRequest,
        executableURL: URL,
        onEvent: @escaping @Sendable (PromptResponseEvent) -> Void,
        acceptCompletion: @Sendable (PromptResponse) -> Bool = { _ in true }
    ) async throws -> PromptResponse {
        try Task.checkCancellation()
        let executableURL = executableURL.standardizedFileURL
        if self.executableURL != executableURL {
            self.executableURL = executableURL
            sessionID = nil
        }
        let generation = UUID()
        if activeGeneration != nil {
            sessionID = nil
        }
        activeGeneration = generation
        let resumedSessionID = sessionID
        let activeSessionID = resumedSessionID ?? UUID().uuidString.lowercased()
        let parser = ClaudeJSONStreamParser(
            expectedSessionID: activeSessionID,
            onEvent: onEvent
        )

        var arguments = [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--permission-mode", "plan",
        ]
        if resumedSessionID == nil {
            arguments.append(contentsOf: ["--session-id", activeSessionID])
        } else {
            arguments.append(contentsOf: ["--resume", activeSessionID])
        }
        let inputText = resumedSessionID == nil ? firstSessionPromptText(
                for: request,
                text: request.text,
                visibleAttachments: request.attachments
            ) : promptText(
                for: request,
                text: request.currentTurnText ?? request.text,
                visibleAttachments: request.attachments
            )
        let standardInput = Data(inputText.utf8)

        do {
            let result = try await runStreamingProcess(
                executableURL: executableURL,
                arguments: arguments,
                processRunner: processRunner,
                timeout: timeout,
                outputByteLimit: outputByteLimit,
                standardInput: standardInput,
                onStandardOutput: { parser.consume($0) }
            )
            try Task.checkCancellation()
            try validateStructuredProcessResult(result)
            let parsed = try parser.finish()
            guard parsed.didReceiveResult else {
                throw StructuredCLIParseError.missingCompletion
            }
            let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AgentConnectorError.emptyResponse
            }
            guard activeGeneration == generation else {
                throw CancellationError()
            }
            let response = PromptResponse(text: text)
            guard !Task.isCancelled, acceptCompletion(response) else {
                throw CancellationError()
            }
            sessionID = activeSessionID
            activeGeneration = nil
            return response
        } catch is CancellationError {
            parser.deactivate()
            discardSession(generation: generation)
            throw CancellationError()
        } catch let error as AgentConnectorError {
            parser.deactivate()
            discardSession(generation: generation)
            throw error
        } catch let error as StructuredCLIParseError {
            parser.deactivate()
            discardSession(generation: generation)
            throw AgentConnectorError.failed(
                exitStatus: nil,
                message: error.localizedDescription
            )
        } catch {
            parser.deactivate()
            discardSession(generation: generation)
            throw AgentConnectorError.launchFailed(String(describing: error))
        }
    }

    private func discardSession(generation: UUID) {
        guard activeGeneration == generation else {
            return
        }
        sessionID = nil
        activeGeneration = nil
    }

    func reset() {
        executableURL = nil
        sessionID = nil
        activeGeneration = nil
    }
}

private struct OpenCodeParsedOutput {
    let text: String
    let didFinish: Bool
}

private final class OpenCodeJSONStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private let onEvent: @Sendable (PromptResponseEvent) -> Void
    private var lines = JSONLineBuffer()
    private var active = true
    private var failure: StructuredCLIParseError?
    private var sessionID: String?
    private var partOrder: [String] = []
    private var partText: [String: String] = [:]
    private var lastSnapshot = ""
    private var didFinish = false

    init(onEvent: @escaping @Sendable (PromptResponseEvent) -> Void) {
        self.onEvent = onEvent
    }

    func consume(_ data: Data) {
        let events = lock.withLock { () -> [PromptResponseEvent] in
            guard active, failure == nil else {
                return []
            }
            return parse(lines.append(data))
        }
        events.forEach(onEvent)
    }

    func finish() throws -> OpenCodeParsedOutput {
        let result = lock.withLock { () -> Result<(OpenCodeParsedOutput, [PromptResponseEvent]), StructuredCLIParseError> in
            guard active else {
                return .failure(.inactiveParser)
            }
            let events = parse(lines.finish())
            active = false
            if let failure {
                return .failure(failure)
            }
            return .success((
                OpenCodeParsedOutput(text: aggregateText, didFinish: didFinish),
                events
            ))
        }
        let (output, events) = try result.get()
        events.forEach(onEvent)
        return output
    }

    func deactivate() {
        lock.withLock { active = false }
    }

    private func parse(_ completeLines: [Data]) -> [PromptResponseEvent] {
        var events: [PromptResponseEvent] = []
        for line in completeLines where failure == nil {
            guard !didFinish else {
                break
            }
            do {
                let message = try decodeJSONLine(line)
                guard let type = message["type"] as? String else {
                    throw StructuredCLIParseError.invalidEvent
                }
                let eventSessionID = message["sessionID"] as? String
                if type == "step_start" {
                    guard let eventSessionID, !eventSessionID.isEmpty else {
                        throw StructuredCLIParseError.missingSessionID
                    }
                    if sessionID == nil {
                        sessionID = eventSessionID
                    }
                    continue
                }
                if let sessionID, let eventSessionID, sessionID != eventSessionID {
                    continue
                }
                switch type {
                case "text":
                    guard let part = message["part"] as? [String: Any],
                          part["type"] as? String == "text",
                          let text = part["text"] as? String else {
                        throw StructuredCLIParseError.invalidEvent
                    }
                    let identifier = part["id"] as? String ?? "text"
                    if partText[identifier] == nil {
                        partOrder.append(identifier)
                    }
                    partText[identifier] = text
                    let snapshot = aggregateText
                    if !snapshot.isEmpty, snapshot != lastSnapshot {
                        lastSnapshot = snapshot
                        events.append(.textSnapshot(snapshot))
                    }
                case "step_finish":
                    guard let part = message["part"] as? [String: Any],
                          part["type"] as? String == "step-finish",
                          let reason = part["reason"] as? String else {
                        throw StructuredCLIParseError.invalidEvent
                    }
                    switch reason {
                    case "tool-calls":
                        continue
                    case "stop", "length", "content-filter", "error", "other", "unknown":
                        didFinish = true
                        return events
                    default:
                        throw StructuredCLIParseError.invalidEvent
                    }
                case "error":
                    throw StructuredCLIParseError.agentError(
                        eventErrorMessage(message)
                    )
                default:
                    continue
                }
            } catch let error as StructuredCLIParseError {
                failure = error
            } catch {
                failure = .invalidJSON
            }
        }
        return events
    }

    private var aggregateText: String {
        partOrder.compactMap { partText[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private struct CodexParsedOutput {
    let sessionID: String?
    let text: String
    let didCompleteTurn: Bool
}

private final class CodexJSONStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSessionID: String?
    private let onEvent: @Sendable (PromptResponseEvent) -> Void
    private var lines = JSONLineBuffer()
    private var active = true
    private var failure: StructuredCLIParseError?
    private var sessionID: String?
    private var itemOrder: [String] = []
    private var itemText: [String: String] = [:]
    private var lastSnapshot = ""
    private var didCompleteTurn = false

    init(
        expectedSessionID: String?,
        onEvent: @escaping @Sendable (PromptResponseEvent) -> Void
    ) {
        self.expectedSessionID = expectedSessionID
        self.onEvent = onEvent
    }

    func consume(_ data: Data) {
        let events = lock.withLock { () -> [PromptResponseEvent] in
            guard active, failure == nil else {
                return []
            }
            return parse(lines.append(data))
        }
        events.forEach(onEvent)
    }

    func finish() throws -> CodexParsedOutput {
        let result = lock.withLock { () -> Result<(CodexParsedOutput, [PromptResponseEvent]), StructuredCLIParseError> in
            guard active else {
                return .failure(.inactiveParser)
            }
            let events = parse(lines.finish())
            active = false
            if let failure {
                return .failure(failure)
            }
            return .success((
                CodexParsedOutput(
                    sessionID: sessionID ?? expectedSessionID,
                    text: aggregateText,
                    didCompleteTurn: didCompleteTurn
                ),
                events
            ))
        }
        let (output, events) = try result.get()
        events.forEach(onEvent)
        return output
    }

    func deactivate() {
        lock.withLock { active = false }
    }

    private func parse(_ completeLines: [Data]) -> [PromptResponseEvent] {
        var events: [PromptResponseEvent] = []
        for line in completeLines where failure == nil {
            guard !didCompleteTurn else {
                break
            }
            do {
                let message = try decodeJSONLine(line)
                guard let type = message["type"] as? String else {
                    throw StructuredCLIParseError.invalidEvent
                }
                switch type {
                case "thread.started":
                    guard let value = message["thread_id"] as? String,
                          !value.isEmpty else {
                        throw StructuredCLIParseError.missingSessionID
                    }
                    if let expectedSessionID, value != expectedSessionID {
                        throw StructuredCLIParseError.sessionMismatch
                    }
                    sessionID = value
                case "item.started", "item.updated", "item.completed":
                    guard let item = message["item"] as? [String: Any],
                          item["type"] as? String == "agent_message" else {
                        continue
                    }
                    guard let identifier = item["id"] as? String,
                          let text = item["text"] as? String else {
                        throw StructuredCLIParseError.invalidEvent
                    }
                    if itemText[identifier] == nil {
                        itemOrder.append(identifier)
                    }
                    itemText[identifier] = text
                    let snapshot = aggregateText
                    if !snapshot.isEmpty, snapshot != lastSnapshot {
                        lastSnapshot = snapshot
                        events.append(.textSnapshot(snapshot))
                    }
                case "turn.completed":
                    didCompleteTurn = true
                    return events
                case "turn.failed", "error":
                    throw StructuredCLIParseError.agentError(
                        eventErrorMessage(message)
                    )
                default:
                    continue
                }
            } catch let error as StructuredCLIParseError {
                failure = error
            } catch {
                failure = .invalidJSON
            }
        }
        return events
    }

    private var aggregateText: String {
        itemOrder.compactMap { itemText[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private struct ClaudeParsedOutput {
    let text: String
    let didReceiveResult: Bool
}

private final class ClaudeJSONStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSessionID: String
    private let onEvent: @Sendable (PromptResponseEvent) -> Void
    private var lines = JSONLineBuffer()
    private var active = true
    private var failure: StructuredCLIParseError?
    private var displayedText = ""
    private var finalText = ""
    private var didReceiveResult = false

    init(
        expectedSessionID: String,
        onEvent: @escaping @Sendable (PromptResponseEvent) -> Void
    ) {
        self.expectedSessionID = expectedSessionID
        self.onEvent = onEvent
    }

    func consume(_ data: Data) {
        let events = lock.withLock { () -> [PromptResponseEvent] in
            guard active, failure == nil else {
                return []
            }
            return parse(lines.append(data))
        }
        events.forEach(onEvent)
    }

    func finish() throws -> ClaudeParsedOutput {
        let result = lock.withLock { () -> Result<(ClaudeParsedOutput, [PromptResponseEvent]), StructuredCLIParseError> in
            guard active else {
                return .failure(.inactiveParser)
            }
            let events = parse(lines.finish())
            active = false
            if let failure {
                return .failure(failure)
            }
            return .success((
                ClaudeParsedOutput(
                    text: finalText.isEmpty ? displayedText : finalText,
                    didReceiveResult: didReceiveResult
                ),
                events
            ))
        }
        let (output, events) = try result.get()
        events.forEach(onEvent)
        return output
    }

    func deactivate() {
        lock.withLock { active = false }
    }

    private func parse(_ completeLines: [Data]) -> [PromptResponseEvent] {
        var events: [PromptResponseEvent] = []
        for line in completeLines where failure == nil {
            guard !didReceiveResult else {
                break
            }
            do {
                let message = try decodeJSONLine(line)
                guard let type = message["type"] as? String else {
                    throw StructuredCLIParseError.invalidEvent
                }
                guard type == "system"
                        || message["session_id"] as? String == expectedSessionID else {
                    continue
                }
                switch type {
                case "system":
                    if let sessionID = message["session_id"] as? String,
                       sessionID != expectedSessionID {
                        continue
                    }
                case "stream_event":
                    guard let event = message["event"] as? [String: Any],
                          event["type"] as? String == "content_block_delta",
                          let delta = event["delta"] as? [String: Any],
                          delta["type"] as? String == "text_delta",
                          let text = delta["text"] as? String else {
                        continue
                    }
                    if !text.isEmpty {
                        displayedText += text
                        events.append(.textDelta(text))
                    }
                case "assistant":
                    let text = assistantText(message)
                    if !text.isEmpty {
                        finalText = text
                        if text != displayedText {
                            displayedText = text
                            events.append(.textSnapshot(text))
                        }
                    }
                case "result":
                    guard message["is_error"] as? Bool != true,
                          message["subtype"] as? String == "success" else {
                        throw StructuredCLIParseError.agentError(
                            message["result"] as? String ?? "Claude Code failed."
                        )
                    }
                    let text = message["result"] as? String ?? finalText
                    if !text.isEmpty {
                        finalText = text
                        if text != displayedText {
                            displayedText = text
                            events.append(.textSnapshot(text))
                        }
                    }
                    didReceiveResult = true
                    return events
                default:
                    continue
                }
            } catch let error as StructuredCLIParseError {
                failure = error
            } catch {
                failure = .invalidJSON
            }
        }
        return events
    }

    private func assistantText(_ message: [String: Any]) -> String {
        guard let assistant = message["message"] as? [String: Any],
              let content = assistant["content"] as? [[String: Any]] else {
            return ""
        }
        return content.compactMap { block in
            guard block["type"] as? String == "text" else {
                return nil
            }
            return block["text"] as? String
        }.joined()
    }
}

private struct JSONLineBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        return drainCompleteLines()
    }

    mutating func finish() -> [Data] {
        var result = drainCompleteLines()
        if !buffer.isEmpty {
            result.append(buffer)
            buffer.removeAll(keepingCapacity: false)
        }
        return result
    }

    private mutating func drainCompleteLines() -> [Data] {
        var result: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                result.append(line)
            }
        }
        return result
    }
}

private enum StructuredCLIParseError: Error, LocalizedError {
    case invalidJSON
    case invalidEvent
    case missingSessionID
    case missingCompletion
    case sessionMismatch
    case inactiveParser
    case agentError(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            AppText.localized("에이전트가 유효하지 않은 JSON 스트림을 반환했습니다.")
        case .invalidEvent:
            AppText.localized("에이전트가 지원되지 않는 JSON 이벤트를 반환했습니다.")
        case .missingSessionID:
            AppText.localized("에이전트가 세션 ID를 반환하지 않았습니다.")
        case .missingCompletion:
            AppText.localized("에이전트 스트림이 완료 이벤트 없이 종료되었습니다.")
        case .sessionMismatch:
            AppText.localized("에이전트가 요청한 세션과 다른 세션을 반환했습니다.")
        case .inactiveParser:
            AppText.localized("종료된 에이전트 스트림을 다시 처리할 수 없습니다.")
        case let .agentError(message):
            message
        }
    }
}

private func decodeJSONLine(_ line: Data) throws -> [String: Any] {
    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw StructuredCLIParseError.invalidJSON
    }
    return message
}

private func eventErrorMessage(_ message: [String: Any]) -> String {
    if let error = message["error"] as? [String: Any],
       let value = error["message"] as? String {
        return value
    }
    return message["message"] as? String ?? "Codex failed."
}

private func runStreamingProcess(
    executableURL: URL,
    arguments: [String],
    processRunner: any ProcessRunning,
    timeout: Duration,
    outputByteLimit: Int,
    standardInput: Data? = nil,
    onStandardOutput: @escaping @Sendable (Data) -> Void
) async throws -> ProcessRunResult {
    do {
        return try await processRunner.runStreaming(
            ProcessCommand(
                executableURL: executableURL,
                arguments: arguments,
                environment: AgentProcessEnvironment.make(
                    executableDirectory: executableURL.deletingLastPathComponent()
                ),
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                outputByteLimit: outputByteLimit,
                standardInput: standardInput
            ),
            timeout: timeout,
            onStandardOutput: onStandardOutput
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw AgentConnectorError.launchFailed(String(describing: error))
    }
}

private func validateStructuredProcessResult(_ result: ProcessRunResult) throws {
    if result.timedOut {
        throw AgentConnectorError.timedOut
    }
    guard result.exitStatus == 0 else {
        let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standardError = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw AgentConnectorError.failed(
            exitStatus: result.exitStatus,
            message: standardError.isEmpty ? standardOutput : standardError
        )
    }
}
