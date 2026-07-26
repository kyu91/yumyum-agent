import Darwin
import Foundation

public protocol ACPLineTransporting: Sendable {
    func sendLine(_ data: Data) async throws
    func receiveLine() async throws -> Data?
    func close() async
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
            "Hermes ACP 연결이 응답 전에 종료되었습니다."
        case .invalidMessage:
            "Hermes ACP가 유효한 JSON-RPC 메시지를 반환하지 않았습니다."
        case let .incompatibleProtocolVersion(version):
            "Hermes ACP 프로토콜 버전 \(version)은 지원되지 않습니다."
        case let .requestFailed(message):
            "Hermes ACP 요청이 실패했습니다: \(message)"
        case .missingSessionID:
            "Hermes ACP가 세션 ID를 반환하지 않았습니다."
        case .outputLimitExceeded:
            "Hermes ACP 출력이 안전 제한을 초과했습니다."
        }
    }
}

public struct HermesACPProtocolClient: Sendable {
    private let transport: any ACPLineTransporting
    private let workingDirectory: URL

    public init(
        transport: any ACPLineTransporting,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.transport = transport
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    public func send(_ request: PromptRequest) async throws -> PromptResponse {
        try await sendMessage(
            id: 0,
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
        let initialize = try await response(for: 0)
        let initializeResult = try resultDictionary(in: initialize)
        let protocolVersion = initializeResult["protocolVersion"] as? Int ?? -1
        guard protocolVersion == 1 else {
            throw HermesACPProtocolError.incompatibleProtocolVersion(protocolVersion)
        }

        try await sendMessage(
            id: 1,
            method: "session/new",
            params: [
                "cwd": workingDirectory.path,
                "mcpServers": [Any](),
            ]
        )
        let session = try await response(for: 1)
        let sessionResult = try resultDictionary(in: session)
        guard let sessionID = sessionResult["sessionId"] as? String,
              !sessionID.isEmpty else {
            throw HermesACPProtocolError.missingSessionID
        }

        try await sendMessage(
            id: 2,
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": promptBlocks(for: request),
            ]
        )

        var responseText = ""
        while true {
            let message = try await receiveMessage()
            if message["method"] as? String == "session/update" {
                appendText(from: message, to: &responseText)
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
            guard messageID(message) == 2 else {
                continue
            }
            try throwIfError(in: message)
            return PromptResponse(text: responseText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

    private func sendJSON(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HermesACPProtocolError.invalidMessage
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await transport.sendLine(data)
    }

    private func receiveMessage() async throws -> [String: Any] {
        guard let data = try await transport.receiveLine() else {
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
            error["message"] as? String ?? "알 수 없는 오류"
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

    private func appendText(
        from message: [String: Any],
        to responseText: inout String
    ) {
        guard let params = message["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String else {
            return
        }
        responseText += text
    }

    private func promptBlocks(for request: PromptRequest) -> [[String: Any]] {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks: [[String: Any]] = [[
            "type": "text",
            "text": trimmed.isEmpty ? "선택한 첨부 파일을 분석해 주세요." : trimmed,
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

public struct ACPProcessTransport: HermesACPTransporting, Sendable {
    public init() {}

    public func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse {
        let transport: ACPProcessLineTransport
        do {
            transport = try ACPProcessLineTransport(
                executableURL: executableURL,
                environment: environment,
                workingDirectory: FileManager.default.temporaryDirectory,
                outputByteLimit: outputByteLimit
            )
        } catch {
            throw AgentConnectorError.launchFailed(String(describing: error))
        }
        let client = HermesACPProtocolClient(
            transport: transport,
            workingDirectory: FileManager.default.temporaryDirectory
        )

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: PromptResponse.self) { group in
                group.addTask {
                    try await client.send(request)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentConnectorError.timedOut
                }

                do {
                    let response = try await group.next()!
                    group.cancelAll()
                    transport.stop()
                    return response
                } catch {
                    group.cancelAll()
                    transport.stop()
                    throw error
                }
            }
        } onCancel: {
            transport.stop()
        }
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
}

private final class ACPProcessLineTransport: ACPLineTransporting, @unchecked Sendable {
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
        while true {
            try Task.checkCancellation()
            guard let byte = try outputPipe.fileHandleForReading.read(upToCount: 1),
                  !byte.isEmpty else {
                return line.isEmpty ? nil : line
            }
            bytesReceived += byte.count
            guard bytesReceived <= outputByteLimit else {
                stop()
                throw HermesACPProtocolError.outputLimitExceeded
            }
            if byte[byte.startIndex] == 0x0A {
                return line
            }
            line.append(byte)
        }
    }

    func close() async {
        stop()
    }

    func stop() {
        lifecycle.stop()
    }
}
