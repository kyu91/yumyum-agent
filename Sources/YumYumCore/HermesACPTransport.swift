import Darwin
import Foundation

public protocol ACPLineTransporting: Sendable {
    func sendLine(_ data: Data) async throws
    func receiveLine() async throws -> Data?
    func resetOutputBudget() async
    func close() async
}

public extension ACPLineTransporting {
    func resetOutputBudget() async {}
}

public enum HermesACPProtocolError: Error, Equatable, LocalizedError, Sendable {
    case connectionClosed
    case invalidMessage
    case incompatibleProtocolVersion(Int)
    case requestFailed(String)
    case missingSessionID
    case outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            AppText.localized("Hermes ACP 연결이 응답 전에 종료되었습니다.")
        case .invalidMessage:
            AppText.localized("Hermes ACP가 유효한 JSON-RPC 메시지를 반환하지 않았습니다.")
        case let .incompatibleProtocolVersion(version):
            AppText.localized(english: "Hermes ACP protocol version \(version) is unsupported.", korean: "Hermes ACP 프로토콜 버전 \(version)은 지원되지 않습니다.")
        case let .requestFailed(message):
            AppText.localized(english: "Hermes ACP request failed: \(message)", korean: "Hermes ACP 요청이 실패했습니다: \(message)")
        case .missingSessionID:
            AppText.localized("Hermes ACP가 세션 ID를 반환하지 않았습니다.")
        case .outputLimitExceeded:
            AppText.localized("Hermes ACP 출력이 안전 제한을 초과했습니다.")
        }
    }
}

public actor HermesACPProtocolClient {
    private struct ActivePrompt {
        let requestID: Int
        let sessionID: String
    }

    private let transport: any ACPLineTransporting
    private let workingDirectory: URL
    private var sessionID: String?
    private var nextRequestID = 0
    private var activePrompt: ActivePrompt?

    public init(
        transport: any ACPLineTransporting,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.transport = transport
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    public func send(
        _ request: PromptRequest,
        onEvent: @escaping @Sendable (PromptResponseEvent) -> Void = { _ in }
    ) async throws -> PromptResponse {
        let isResumingSession = sessionID != nil
        let sessionID = try await prepareSessionIfNeeded()
        await transport.resetOutputBudget()
        let promptRequestID = nextRequestID
        nextRequestID += 1
        activePrompt = ActivePrompt(
            requestID: promptRequestID,
            sessionID: sessionID
        )
        defer {
            if activePrompt?.requestID == promptRequestID {
                activePrompt = nil
            }
        }

        try await sendMessage(
            id: promptRequestID,
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": promptBlocks(
                    for: request,
                    text: isResumingSession
                        ? request.currentTurnText ?? request.text
                        : firstSessionPromptText(for: request)
                ),
            ]
        )

        var responseText = ""
        while true {
            let message = try await receiveMessage()
            if message["method"] as? String == "session/update" {
                if let text = textChunk(from: message, sessionID: sessionID),
                   !text.isEmpty {
                    responseText += text
                    onEvent(.textDelta(text))
                }
                continue
            }
            if message["method"] as? String == "session/request_permission" {
                try await cancelPermissionRequest(message)
                continue
            }
            if message["method"] != nil, message["id"] != nil {
                try await rejectUnsupportedClientRequest(message)
                continue
            }
            guard messageID(message) == promptRequestID else {
                continue
            }
            try throwIfError(in: message)
            return PromptResponse(
                text: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    func cancelActivePrompt() async {
        guard let prompt = activePrompt else {
            return
        }
        activePrompt = nil
        try? await sendNotification(
            method: "session/cancel",
            params: ["sessionId": prompt.sessionID]
        )
    }

    private func prepareSessionIfNeeded() async throws -> String {
        if let sessionID {
            return sessionID
        }

        let initializeRequestID = nextRequestID
        nextRequestID += 1
        try await sendMessage(
            id: initializeRequestID,
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [String: Any](),
                "clientInfo": [
                    "name": "yumyum",
                    "title": "YumYum",
                    "version": "0.1.0",
                ],
            ]
        )
        let initialize = try await response(for: initializeRequestID)
        let initializeResult = try resultDictionary(in: initialize)
        let protocolVersion = initializeResult["protocolVersion"] as? Int ?? -1
        guard protocolVersion == 1 else {
            throw HermesACPProtocolError.incompatibleProtocolVersion(protocolVersion)
        }

        let sessionRequestID = nextRequestID
        nextRequestID += 1
        try await sendMessage(
            id: sessionRequestID,
            method: "session/new",
            params: [
                "cwd": workingDirectory.path,
                "mcpServers": [Any](),
            ]
        )
        let session = try await response(for: sessionRequestID)
        let sessionResult = try resultDictionary(in: session)
        guard let newSessionID = sessionResult["sessionId"] as? String,
              !newSessionID.isEmpty else {
            throw HermesACPProtocolError.missingSessionID
        }
        sessionID = newSessionID
        return newSessionID
    }

    private func response(for expectedID: Int) async throws -> [String: Any] {
        while true {
            let message = try await receiveMessage()
            if message["method"] as? String == "session/request_permission" {
                try await cancelPermissionRequest(message)
                continue
            }
            if message["method"] != nil, message["id"] != nil {
                try await rejectUnsupportedClientRequest(message)
                continue
            }
            guard messageID(message) == expectedID else {
                continue
            }
            try throwIfError(in: message)
            return message
        }
    }

    private func sendMessage(
        id: Int,
        method: String,
        params: [String: Any]
    ) async throws {
        try await sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
    }

    private func sendNotification(
        method: String,
        params: [String: Any]
    ) async throws {
        try await sendJSON([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HermesACPProtocolError.invalidMessage
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await transport.sendLine(data)
    }

    private func receiveMessage() async throws -> [String: Any] {
        let data = try await transport.receiveLine()
        try Task.checkCancellation()
        guard let data else {
            throw HermesACPProtocolError.connectionClosed
        }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["jsonrpc"] as? String == "2.0" else {
            throw HermesACPProtocolError.invalidMessage
        }
        return message
    }

    private func resultDictionary(in message: [String: Any]) throws -> [String: Any] {
        try throwIfError(in: message)
        guard let result = message["result"] as? [String: Any] else {
            throw HermesACPProtocolError.invalidMessage
        }
        return result
    }

    private func throwIfError(in message: [String: Any]) throws {
        guard let error = message["error"] as? [String: Any] else {
            return
        }
        throw HermesACPProtocolError.requestFailed(
            error["message"] as? String ?? AppText.localized("알 수 없는 오류")
        )
    }

    private func messageID(_ message: [String: Any]) -> Int? {
        if let id = message["id"] as? Int {
            return id
        }
        return (message["id"] as? NSNumber)?.intValue
    }

    private func cancelPermissionRequest(_ message: [String: Any]) async throws {
        guard let id = message["id"] else {
            return
        }
        try await sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "outcome": ["outcome": "cancelled"],
            ],
        ])
    }

    private func rejectUnsupportedClientRequest(_ message: [String: Any]) async throws {
        guard let id = message["id"] else {
            return
        }
        try await sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32_601,
                "message": "YumYum does not expose client file-system or terminal methods.",
            ],
        ])
    }

    private func textChunk(
        from message: [String: Any],
        sessionID: String
    ) -> String? {
        guard let params = message["params"] as? [String: Any],
              params["sessionId"] as? String == sessionID,
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String else {
            return nil
        }
        return text
    }

    private func promptBlocks(
        for request: PromptRequest,
        text: String
    ) -> [[String: Any]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks: [[String: Any]] = [[
            "type": "text",
            "text": trimmed.isEmpty ? "Analyze the selected attachments." : trimmed,
        ]]
        blocks.append(
            contentsOf: request.attachments.map { attachment in
                [
                    "type": "resource_link",
                    "uri": attachment.url.absoluteString,
                    "name": attachment.url.lastPathComponent,
                    "mimeType": mimeType(for: attachment),
                    "size": attachment.byteCount,
                ]
            }
        )
        return blocks
    }

    private func mimeType(for attachment: PromptAttachment) -> String {
        switch attachment.kind {
        case .image:
            switch attachment.url.pathExtension.lowercased() {
            case "jpg", "jpeg": "image/jpeg"
            case "gif": "image/gif"
            case "heic": "image/heic"
            case "webp": "image/webp"
            case "tif", "tiff": "image/tiff"
            default: "image/png"
            }
        case .pdf:
            "application/pdf"
        case .plainText:
            "text/plain"
        case .source:
            "text/plain"
        }
    }
}

protocol ACPLineTransportFactory: Sendable {
    func makeLineTransport(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int
    ) async throws -> any ACPLineTransporting
}

private struct ACPProcessLineTransportFactory: ACPLineTransportFactory {
    func makeLineTransport(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int
    ) async throws -> any ACPLineTransporting {
        try ACPProcessLineTransport(
            executableURL: executableURL,
            environment: environment,
            workingDirectory: workingDirectory,
            outputByteLimit: outputByteLimit
        )
    }
}

public actor ACPProcessTransport: HermesACPTransporting {
    private struct Connection {
        let generation: UUID
        let executableURL: URL
        let lineTransport: any ACPLineTransporting
        let client: HermesACPProtocolClient
    }

    private let lineTransportFactory: any ACPLineTransportFactory
    private let workingDirectory: URL
    private var connection: Connection?
    private var activeRequestGeneration: UUID?

    public init() {
        lineTransportFactory = ACPProcessLineTransportFactory()
        workingDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
    }

    init(
        lineTransportFactory: any ACPLineTransportFactory,
        workingDirectory: URL
    ) {
        self.lineTransportFactory = lineTransportFactory
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    public func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse {
        try await performSend(
            request,
            executableURL: executableURL,
            environment: environment,
            timeout: timeout,
            outputByteLimit: outputByteLimit,
            onEvent: { _ in }
        )
    }

    public nonisolated func sendEvents(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.performSend(
                        request,
                        executableURL: executableURL,
                        environment: environment,
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

    public func close() async {
        await resetConnection()
    }

    private func performSend(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int,
        onEvent: @escaping @Sendable (PromptResponseEvent) -> Void
    ) async throws -> PromptResponse {
        let connection = try await connectionForSend(
            executableURL: executableURL,
            environment: environment,
            outputByteLimit: outputByteLimit
        )
        let generation = connection.generation
        let timeoutState = ACPRequestTimeoutState()
        defer {
            if activeRequestGeneration == generation {
                activeRequestGeneration = nil
            }
        }

        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: PromptResponse.self) { group in
                    group.addTask {
                        try await connection.client.send(request, onEvent: onEvent)
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        timeoutState.markTriggered()
                        let cancellationTask = Task {
                            await connection.client.cancelActivePrompt()
                        }
                        await Task.yield()
                        await self.resetConnection(generation: generation)
                        cancellationTask.cancel()
                        throw AgentConnectorError.timedOut
                    }
                    let response = try await group.next()!
                    group.cancelAll()
                    return response
                }
            } onCancel: {
                Task {
                    await connection.client.cancelActivePrompt()
                    await self.resetConnection(generation: generation)
                }
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(50))
                    await self.resetConnection(generation: generation)
                }
            }
        } catch is CancellationError {
            await connection.client.cancelActivePrompt()
            await resetConnection(generation: generation)
            throw CancellationError()
        } catch {
            await resetConnection(generation: generation)
            if timeoutState.wasTriggered {
                throw AgentConnectorError.timedOut
            }
            throw error
        }
    }

    private func connectionForSend(
        executableURL: URL,
        environment: [String: String],
        outputByteLimit: Int
    ) async throws -> Connection {
        if let activeRequestGeneration,
           let current = connection,
           current.generation == activeRequestGeneration {
            let cancellationTask = Task {
                await current.client.cancelActivePrompt()
            }
            await Task.yield()
            await resetConnection(generation: activeRequestGeneration)
            cancellationTask.cancel()
        }

        let standardizedExecutable = executableURL.standardizedFileURL
        if let connection,
           connection.executableURL == standardizedExecutable {
            activeRequestGeneration = connection.generation
            return connection
        }
        await resetConnection()

        let lineTransport: any ACPLineTransporting
        do {
            lineTransport = try await lineTransportFactory.makeLineTransport(
                executableURL: standardizedExecutable,
                environment: environment,
                workingDirectory: workingDirectory,
                outputByteLimit: outputByteLimit
            )
        } catch {
            throw AgentConnectorError.launchFailed(String(describing: error))
        }
        let newConnection = Connection(
            generation: UUID(),
            executableURL: standardizedExecutable,
            lineTransport: lineTransport,
            client: HermesACPProtocolClient(
                transport: lineTransport,
                workingDirectory: workingDirectory
            )
        )
        connection = newConnection
        activeRequestGeneration = newConnection.generation
        return newConnection
    }

    private func resetConnection(generation: UUID? = nil) async {
        guard let current = connection,
              generation == nil || current.generation == generation else {
            return
        }
        connection = nil
        await current.lineTransport.close()
    }
}

private final class ACPRequestTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false

    var wasTriggered: Bool {
        lock.withLock { triggered }
    }

    func markTriggered() {
        lock.withLock { triggered = true }
    }
}

final class ACPProcessLifecycle: @unchecked Sendable {
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let writeAction: (Data) throws -> Void
    private let stopAction: () -> Void
    private var stopped = false

    init(
        writeAction: @escaping (Data) throws -> Void,
        stopAction: @escaping () -> Void
    ) {
        self.writeAction = writeAction
        self.stopAction = stopAction
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        stateLock.lock()
        let canWrite = !stopped
        stateLock.unlock()
        guard canWrite else {
            throw HermesACPProtocolError.connectionClosed
        }
        try writeAction(data)
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()
        stopAction()
    }

    var isStopped: Bool {
        stateLock.withLock { stopped }
    }
}

final class ACPProcessLineTransport: ACPLineTransporting, @unchecked Sendable {
    private let lifecycle: ACPProcessLifecycle
    private let outputPipe: Pipe
    private let outputByteLimit: Int
    private var bytesReceived = 0

    init(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int
    ) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let outputFileDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let outputFlags = fcntl(outputFileDescriptor, F_GETFL)
        guard outputFlags != -1,
              fcntl(
                  outputFileDescriptor,
                  F_SETFL,
                  outputFlags | O_NONBLOCK
              ) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        self.outputByteLimit = max(0, outputByteLimit)
        self.outputPipe = outputPipe
        self.lifecycle = ACPProcessLifecycle(
            writeAction: { data in
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            },
            stopAction: {
                let shouldTerminate = process.isRunning
                try? inputPipe.fileHandleForWriting.close()
                try? outputPipe.fileHandleForReading.close()
                if shouldTerminate {
                    process.terminate()
                }
                let processIdentifier = process.processIdentifier

                guard shouldTerminate else {
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning {
                        Darwin.kill(processIdentifier, SIGKILL)
                    }
                }
            }
        )
        process.executableURL = executableURL
        process.arguments = ["acp"]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    func sendLine(_ data: Data) async throws {
        try Task.checkCancellation()
        var line = data
        line.append(0x0A)
        try writeLine(line)
    }

    private func writeLine(_ line: Data) throws {
        try lifecycle.write(line)
    }

    func receiveLine() async throws -> Data? {
        var line = Data()
        let fileDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        while true {
            try Task.checkCancellation()
            if lifecycle.isStopped {
                return line.isEmpty ? nil : line
            }

            var byte: UInt8 = 0
            let byteCount = Darwin.read(fileDescriptor, &byte, 1)
            if byteCount == 1 {
                bytesReceived += 1
                guard bytesReceived <= outputByteLimit else {
                    stop()
                    throw HermesACPProtocolError.outputLimitExceeded
                }
                if byte == 0x0A {
                    return line
                }
                line.append(byte)
                continue
            }
            if byteCount == 0 {
                return line.isEmpty ? nil : line
            }
            if errno == EINTR {
                continue
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                if lifecycle.isStopped {
                    return line.isEmpty ? nil : line
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 20)
            if pollResult == -1, errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    func close() async {
        stop()
    }

    func resetOutputBudget() async {
        bytesReceived = 0
    }

    func stop() {
        lifecycle.stop()
    }
}
