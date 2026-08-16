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

private let hermesAllowedModelProviders: Set<String> = [
    "anthropic",
    "openai",
    "google",
    "gemini",
    "vertex",
    "xai",
    "bedrock",
]

public struct HermesModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum ACPProtocolError: Error, Equatable, LocalizedError, Sendable {
    case connectionClosed
    case invalidMessage
    case incompatibleProtocolVersion(Int)
    case requestFailed(String)
    case requestInFlight
    case missingSessionID
    case outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            AppText.localized("ACP 연결이 응답 전에 종료되었습니다.")
        case .invalidMessage:
            AppText.localized("ACP가 유효한 JSON-RPC 메시지를 반환하지 않았습니다.")
        case let .incompatibleProtocolVersion(version):
            AppText.localized(english: "ACP protocol version \(version) is unsupported.", korean: "ACP 프로토콜 버전 \(version)은 지원되지 않습니다.")
        case let .requestFailed(message):
            AppText.localized(english: "ACP request failed: \(message)", korean: "ACP 요청이 실패했습니다: \(message)")
        case .requestInFlight:
            AppText.localized(english: "An ACP request is already in flight.", korean: "ACP 요청이 이미 진행 중입니다.")
        case .missingSessionID:
            AppText.localized("ACP가 세션 ID를 반환하지 않았습니다.")
        case .outputLimitExceeded:
            AppText.localized("ACP 출력이 안전 제한을 초과했습니다.")
        }
    }
}

public actor ACPProtocolClient {
    private struct ActivePrompt {
        let requestID: Int
        let sessionID: String
    }

    private let transport: any ACPLineTransporting
    private let workingDirectory: URL
    private var sessionID: String?
    private var nextRequestID = 0
    private var activePrompt: ActivePrompt?
    public private(set) var availableModels: [HermesModel] = []
    public private(set) var currentModelID: String?
    private var modelSelectionFailed = false

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
        let sessionID = try await prepareSessionIfNeeded(modelID: request.modelID)
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
                        ? promptText(for: request, text: request.currentTurnText ?? request.text)
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

    func modelCatalog(modelID: String?, force: Bool = false) async throws -> [HermesModel] {
        if force, sessionID != nil {
            sessionID = nil
            await transport.close()
        }
        modelSelectionFailed = false
        do {
            _ = try await prepareSessionIfNeeded(modelID: modelID)
            return availableModels
        } catch {
            guard modelSelectionFailed, !(error is CancellationError) else { throw error }
            modelSelectionFailed = false
            sessionID = nil
            await transport.close()
            return availableModels
        }
    }

    func hasSession() -> Bool {
        sessionID != nil
    }

    private func prepareSessionIfNeeded(modelID: String?) async throws -> String {
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
                    "title": "YumYum Agent",
                    "version": "0.1.0",
                ],
            ]
        )
        let initialize = try await response(for: initializeRequestID)
        let initializeResult = try resultDictionary(in: initialize)
        let protocolVersion = initializeResult["protocolVersion"] as? Int ?? -1
        // TODO(verify-before-ship): Gemini가 실제로 협상하는 ACP protocol version은 문서만으로 확인되지 않았습니다. 버전 1을 거부하면 안전하게 실패하도록 둡니다.
        guard protocolVersion == 1 else {
            throw ACPProtocolError.incompatibleProtocolVersion(protocolVersion)
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
            throw ACPProtocolError.missingSessionID
        }
        _ = parseModels(from: sessionResult)
        if let modelID, modelID != currentModelID {
            let setModelRequestID = nextRequestID
            nextRequestID += 1
            do {
                try await sendMessage(
                    id: setModelRequestID,
                    method: "session/set_model",
                    params: [
                        "sessionId": newSessionID,
                        "modelId": modelID,
                    ]
                )
                _ = try await response(for: setModelRequestID)
            } catch {
                modelSelectionFailed = true
                throw error
            }
            currentModelID = modelID
        }
        sessionID = newSessionID
        return newSessionID
    }

    private func parseModels(from sessionResult: [String: Any]) -> [HermesModel] {
        guard let models = sessionResult["models"] as? [String: Any],
              let availableModels = models["availableModels"] as? [[String: Any]] else {
            self.availableModels = []
            currentModelID = nil
            return []
        }
        let allModels = availableModels.compactMap { model -> HermesModel? in
            guard let id = model["modelId"] as? String,
                  let name = model["name"] as? String else {
                return nil
            }
            return HermesModel(id: id, name: name)
        }
        let filteredModels = allModels.filter { model in
            let providerSegment = model.id
                .split(separator: ":", maxSplits: 1)
                .first
                .map(String.init)?
                .lowercased() ?? ""
            return hermesAllowedModelProviders.contains(providerSegment)
                || hermesAllowedModelProviders.contains { providerSegment.hasPrefix($0 + "-") }
        }
        self.availableModels = filteredModels.isEmpty && !allModels.isEmpty
            ? allModels
            : filteredModels
        currentModelID = models["currentModelId"] as? String
        return self.availableModels
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
            throw ACPProtocolError.invalidMessage
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await transport.sendLine(data)
    }

    private func receiveMessage() async throws -> [String: Any] {
        // TODO(verify-before-ship): This assumes Gemini credential-cache noise is confined to whole lines; embedded noise would require a different parser.
        while true {
            let data = try await transport.receiveLine()
            try Task.checkCancellation()
            guard let data else {
                throw ACPProtocolError.connectionClosed
            }
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["jsonrpc"] as? String == "2.0" else {
                continue
            }
            return message
        }
    }

    private func resultDictionary(in message: [String: Any]) throws -> [String: Any] {
        try throwIfError(in: message)
        guard let result = message["result"] as? [String: Any] else {
            throw ACPProtocolError.invalidMessage
        }
        return result
    }

    private func throwIfError(in message: [String: Any]) throws {
        guard let error = message["error"] as? [String: Any] else {
            return
        }
        throw ACPProtocolError.requestFailed(
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
                "message": "YumYum Agent does not expose client file-system or terminal methods.",
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
        outputByteLimit: Int,
        arguments: [String]
    ) async throws -> any ACPLineTransporting
}

private struct ACPProcessLineTransportFactory: ACPLineTransportFactory {
    func makeLineTransport(
        executableURL: URL,
        environment: [String: String],
        workingDirectory: URL,
        outputByteLimit: Int,
        arguments: [String]
    ) async throws -> any ACPLineTransporting {
        try ACPProcessLineTransport(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            outputByteLimit: outputByteLimit
        )
    }
}

public actor ACPProcessTransport: ACPTransporting {
    private struct Connection {
        let generation: UUID
        let executableURL: URL
        let lineTransport: any ACPLineTransporting
        let client: ACPProtocolClient
    }

    private let lineTransportFactory: any ACPLineTransportFactory
    private let workingDirectory: URL
    private let arguments: [String]
    private var connection: Connection?
    private var activeRequestGeneration: UUID?

    public init(arguments: [String]) {
        lineTransportFactory = ACPProcessLineTransportFactory()
        workingDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        self.arguments = arguments
    }

    init(
        lineTransportFactory: any ACPLineTransportFactory,
        arguments: [String],
        workingDirectory: URL
    ) {
        self.arguments = arguments
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

    public func models(
        executableURL: URL,
        environment: [String: String],
        outputByteLimit: Int,
        modelID: String?,
        force: Bool = false
    ) async throws -> [HermesModel] {
        guard activeRequestGeneration == nil else {
            throw ACPProtocolError.requestInFlight
        }
        if force {
            await resetConnection()
        }
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
                try await withThrowingTaskGroup(of: [HermesModel].self) { group in
                    group.addTask {
                        let models = try await connection.client.modelCatalog(
                            modelID: modelID,
                            force: force
                        )
                        if !(await connection.client.hasSession()) {
                            await self.resetConnection(generation: generation)
                        }
                        return models
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(20))
                        timeoutState.markTriggered()
                        await self.resetConnection(generation: generation)
                        throw AgentConnectorError.timedOut
                    }
                    let models = try await group.next()!
                    group.cancelAll()
                    return models
                }
            } onCancel: {
                Task {
                    await self.resetConnection(generation: generation)
                }
            }
        } catch {
            await resetConnection(generation: generation)
            if timeoutState.wasTriggered {
                throw AgentConnectorError.timedOut
            }
            throw error
        }
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
                outputByteLimit: outputByteLimit,
                arguments: arguments
            )
        } catch {
            throw AgentConnectorError.launchFailed(String(describing: error))
        }
        let newConnection = Connection(
            generation: UUID(),
            executableURL: standardizedExecutable,
            lineTransport: lineTransport,
            client: ACPProtocolClient(
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
            throw ACPProtocolError.connectionClosed
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
        arguments: [String],
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
        process.arguments = arguments
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
                    throw ACPProtocolError.outputLimitExceeded
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
