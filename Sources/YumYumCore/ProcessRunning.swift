import Foundation

public struct ProcessCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let currentDirectoryURL: URL?
    public let outputByteLimit: Int?
    public let standardInput: Data?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        outputByteLimit: Int? = nil,
        standardInput: Data? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.outputByteLimit = outputByteLimit
        self.standardInput = standardInput
    }
}

public enum ProcessTermination: Equatable, Sendable {
    case exited(status: Int32)
    case uncaughtSignal(signal: Int32)
    case timedOut
}

public struct ProcessRunResult: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let termination: ProcessTermination

    public init(
        standardOutput: Data,
        standardError: Data,
        termination: ProcessTermination
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
    }

    public var exitStatus: Int32? {
        guard case let .exited(status) = termination else {
            return nil
        }
        return status
    }

    public var timedOut: Bool {
        termination == .timedOut
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult

    func runStreaming(
        _ command: ProcessCommand,
        timeout: Duration?,
        onStandardOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> ProcessRunResult
}

public extension ProcessRunning {
    func runStreaming(
        _ command: ProcessCommand,
        timeout: Duration?,
        onStandardOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> ProcessRunResult {
        let result = try await run(command, timeout: timeout)
        if !result.standardOutput.isEmpty {
            onStandardOutput(result.standardOutput)
        }
        return result
    }
}
