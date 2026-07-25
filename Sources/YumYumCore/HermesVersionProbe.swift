import Foundation

public struct HermesVersionProbeResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let termination: ProcessTermination

    public init(
        standardOutput: String,
        standardError: String,
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

public struct HermesVersionProbe: Sendable {
    private let processRunner: any ProcessRunning
    private let timeout: Duration

    public init(
        processRunner: any ProcessRunning,
        timeout: Duration = .seconds(2)
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
    }

    public func probe(executableURL: URL) async throws -> HermesVersionProbeResult {
        let result = try await processRunner.run(
            ProcessCommand(executableURL: executableURL, arguments: ["--version"]),
            timeout: timeout
        )

        return HermesVersionProbeResult(
            standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
            standardError: String(decoding: result.standardError, as: UTF8.self),
            termination: result.termination
        )
    }
}
