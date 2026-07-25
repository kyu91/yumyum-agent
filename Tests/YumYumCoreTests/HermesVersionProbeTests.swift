import Foundation
import Testing
@testable import YumYumCore

@Suite
struct HermesVersionProbeTests {
    @Test
    func invokesVersionArgumentAndStructuresSuccessfulOutput() async throws {
        let executable = URL(fileURLWithPath: "/allowed/hermes")
        let timeout = Duration.seconds(2)
        let runner = RecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data("Hermes 1.2.3\n".utf8),
                standardError: Data(),
                termination: .exited(status: 0)
            )
        )
        let probe = HermesVersionProbe(processRunner: runner, timeout: timeout)

        let result = try await probe.probe(executableURL: executable)
        let invocation = try #require(await runner.lastInvocation())

        #expect(invocation.command.executableURL == executable)
        #expect(invocation.command.arguments == ["--version"])
        #expect(invocation.timeout == timeout)
        #expect(result.standardOutput == "Hermes 1.2.3\n")
        #expect(result.standardError.isEmpty)
        #expect(result.exitStatus == 0)
        #expect(!result.timedOut)
    }

    @Test
    func preservesNonzeroExitStatusAndStandardError() async throws {
        let runner = RecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data(),
                standardError: Data("not authenticated\n".utf8),
                termination: .exited(status: 23)
            )
        )
        let probe = HermesVersionProbe(processRunner: runner)

        let result = try await probe.probe(
            executableURL: URL(fileURLWithPath: "/allowed/hermes")
        )

        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == "not authenticated\n")
        #expect(result.exitStatus == 23)
        #expect(!result.timedOut)
    }

    @Test
    func representsTimeoutSeparatelyFromExitStatus() async throws {
        let runner = RecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data("partial".utf8),
                standardError: Data("still running".utf8),
                termination: .timedOut
            )
        )
        let probe = HermesVersionProbe(processRunner: runner)

        let result = try await probe.probe(
            executableURL: URL(fileURLWithPath: "/allowed/hermes")
        )

        #expect(result.standardOutput == "partial")
        #expect(result.standardError == "still running")
        #expect(result.exitStatus == nil)
        #expect(result.timedOut)
    }
}

private actor RecordingProcessRunner: ProcessRunning {
    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration?
    }

    private let result: ProcessRunResult
    private var invocations: [Invocation] = []

    init(result: ProcessRunResult) {
        self.result = result
    }

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        invocations.append(Invocation(command: command, timeout: timeout))
        return result
    }

    func lastInvocation() -> Invocation? {
        invocations.last
    }
}
