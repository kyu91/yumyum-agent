import Foundation
import Testing
@testable import YumYumCore

@Suite
struct HermesConnectionServiceTests {
    @Test
    func returnsOriginalVersionOutputAndPassesOnlyVersionAsDirectArgument() async throws {
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let timeout = Duration.seconds(3)
        let runner = ConnectionRecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data("Hermes 1.2.3\nbuild abc\n".utf8),
                standardError: Data(),
                termination: .exited(status: 0)
            )
        )
        let service = HermesConnectionService(
            locator: HermesExecutableLocator(allowedPATHDirectories: []),
            processRunner: runner,
            timeout: timeout
        )

        let version = try await service.check(executablePath: executable.path)
        let invocation = try #require(await runner.lastInvocation())

        #expect(version == "Hermes 1.2.3\nbuild abc\n")
        #expect(invocation.command.executableURL == executable.standardizedFileURL)
        #expect(invocation.command.arguments == ["--version"])
        #expect(
            invocation.command.environment
                == AgentProcessEnvironment.make(
                    executableDirectory: executable.deletingLastPathComponent()
                )
        )
        #expect(invocation.command.currentDirectoryURL == nil)
        #expect(invocation.command.outputByteLimit == 65_536)
        #expect(invocation.timeout == timeout)
    }

    @Test
    func rejectsRelativePathBeforeStartingAProcess() async {
        let runner = ConnectionCountingProcessRunner()
        let service = HermesConnectionService(processRunner: runner)

        do {
            _ = try await service.check(executablePath: "bin/hermes")
            Issue.record("Expected a relative path error")
        } catch {
            #expect(
                error as? HermesConnectionError
                    == .pathMustBeAbsolute("bin/hermes")
            )
        }
        #expect(await runner.callCount == 0)
    }

    @Test
    func unavailableExplicitPathDoesNotStartPATHFallbackCandidate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeExecutable(in: directory, name: "hermes")
        let missingPath = directory.appendingPathComponent("selected-hermes").path
        let runner = ConnectionCountingProcessRunner()
        let service = HermesConnectionService(
            locator: HermesExecutableLocator(allowedPATHDirectories: [directory]),
            processRunner: runner
        )

        do {
            _ = try await service.check(executablePath: missingPath)
            Issue.record("Expected the unavailable explicit path to be rejected")
        } catch {
            #expect(
                error as? HermesConnectionError
                    == .executableUnavailable(missingPath)
            )
        }
        #expect(await runner.callCount == 0)
    }

    @Test
    func reportsNonzeroExitAsExecutionFailure() async throws {
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ConnectionRecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data("partial\n".utf8),
                standardError: Data("permission denied\n".utf8),
                termination: .exited(status: 23)
            )
        )
        let service = HermesConnectionService(processRunner: runner)

        do {
            _ = try await service.check(executablePath: executable.path)
            Issue.record("Expected a nonzero exit status to fail")
        } catch {
            #expect(
                error as? HermesConnectionError
                    == .executionFailed(
                        exitStatus: 23,
                        standardError: "permission denied\n"
                    )
            )
        }
    }

    @Test
    func reportsTimeoutSeparately() async throws {
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ConnectionRecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data("partial".utf8),
                standardError: Data(),
                termination: .timedOut
            )
        )
        let service = HermesConnectionService(processRunner: runner)

        do {
            _ = try await service.check(executablePath: executable.path)
            Issue.record("Expected timeout")
        } catch {
            #expect(error as? HermesConnectionError == .timedOut)
        }
    }

    @Test
    func rejectsEmptyVersionOutput() async throws {
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ConnectionRecordingProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data(" \n".utf8),
                standardError: Data(),
                termination: .exited(status: 0)
            )
        )
        let service = HermesConnectionService(processRunner: runner)

        do {
            _ = try await service.check(executablePath: executable.path)
            Issue.record("Expected empty version output to fail")
        } catch {
            #expect(error as? HermesConnectionError == .emptyVersionOutput)
        }
    }

    @Test
    func preservesCancellation() async throws {
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = CancellableConnectionProcessRunner()
        let service = HermesConnectionService(processRunner: runner)
        let task = Task {
            try await service.check(executablePath: executable.path)
        }
        while !(await runner.hasStarted) {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            #expect(await runner.wasCancelled)
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    private func makeExecutable() throws -> URL {
        let directory = try makeTemporaryDirectory()
        return try makeExecutable(in: directory, name: "hermes")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeExecutable(in directory: URL, name: String) throws -> URL {
        let executable = directory.appendingPathComponent(name, isDirectory: false)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}

private actor ConnectionRecordingProcessRunner: ProcessRunning {
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

private actor ConnectionCountingProcessRunner: ProcessRunning {
    private(set) var callCount = 0

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        callCount += 1
        return ProcessRunResult(
            standardOutput: Data(),
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }
}

private actor CancellableConnectionProcessRunner: ProcessRunning {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        hasStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return ProcessRunResult(
            standardOutput: Data(),
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }
}
