import Foundation
import Testing
@testable import YumYumCore

@Suite(.serialized)
struct ProcessRunnerTests {
    @Test
    func capsCombinedProcessOutputWhileContinuingToDrainBothStreams() async throws {
        let result = try await ProcessRunner().run(
            ProcessCommand(
                executableURL: fixtureURL,
                arguments: ["flood"],
                outputByteLimit: 8_192
            ),
            timeout: .seconds(5)
        )

        #expect(result.standardOutput.count + result.standardError.count <= 8_192)
        #expect(result.termination == .exited(status: 0))
    }

    @Test
    func capturesBothStreamsAndNonzeroExitStatus() async throws {
        let result = try await ProcessRunner().run(
            ProcessCommand(executableURL: fixtureURL, arguments: ["emit"]),
            timeout: .seconds(2)
        )

        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "stdout-value")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "stderr-value")
        #expect(result.termination == .exited(status: 7))
    }

    @Test
    func drainsLargeStandardOutputAndErrorWithoutDeadlock() async throws {
        let result = try await ProcessRunner().run(
            ProcessCommand(executableURL: fixtureURL, arguments: ["flood"]),
            timeout: .seconds(5)
        )

        #expect(result.standardOutput.count == 1_048_576)
        #expect(result.standardError.count == 1_048_576)
        #expect(result.standardOutput.first == 0x4F)
        #expect(result.standardError.first == 0x45)
        #expect(result.termination == .exited(status: 0))
    }

    @Test
    func passesArgumentsDirectlyWithoutShellInterpretation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let marker = temporaryDirectory.appendingPathComponent("shell-was-used")
        let suppliedArguments = [
            "; touch \(marker.path)",
            "value with spaces",
            "$HOME",
            "*",
        ]

        let result = try await ProcessRunner().run(
            ProcessCommand(
                executableURL: fixtureURL,
                arguments: ["arguments"] + suppliedArguments
            ),
            timeout: .seconds(2)
        )
        let decoded = try #require(
            JSONSerialization.jsonObject(with: result.standardOutput) as? [String]
        )

        #expect(decoded == suppliedArguments)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(result.termination == .exited(status: 0))
    }

    @Test
    func writesStandardInputAndReportsOutputChunks() async throws {
        let input = Data("payload".utf8)
        let chunks = LockedChunks()

        let result = try await ProcessRunner().runStreaming(
            ProcessCommand(
                executableURL: fixtureURL,
                arguments: ["stdin-chunks"],
                standardInput: input
            ),
            timeout: .seconds(2),
            onStandardOutput: { chunks.append($0) }
        )

        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "first:payload")
        #expect(chunks.data() == result.standardOutput)
        #expect(chunks.count() >= 1)
        #expect(result.termination == .exited(status: 0))
    }

    @Test
    func drainsOutputBeforeAChildStartsReadingBackpressuredInput() async throws {
        let firstChunk = AsyncTestSignal()
        let runTask = Task {
            try await ProcessRunner().runStreaming(
                ProcessCommand(
                    executableURL: fixtureURL,
                    arguments: ["stdin-backpressure"],
                    standardInput: Data(repeating: 0x49, count: 1_048_576)
                ),
                timeout: .seconds(2),
                onStandardOutput: { _ in firstChunk.signal() }
            )
        }

        let streamedBeforeInputRead = await firstChunk.wait(
            timeout: .milliseconds(150)
        )
        let result = try await runTask.value

        #expect(streamedBeforeInputRead)
        #expect(
            String(decoding: result.standardOutput, as: UTF8.self)
                == "ready\nread:1048576\n"
        )
        #expect(result.termination == .exited(status: 0))
    }

    @Test
    func timeoutTerminatesThenForceKillsUncooperativeChild() async throws {
        let runner = ProcessRunner(terminationGracePeriod: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await runner.run(
            ProcessCommand(executableURL: fixtureURL, arguments: ["ignore-term"]),
            timeout: .milliseconds(250)
        )

        #expect(result.termination == .timedOut)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "ready\n")
        #expect(clock.now - start < .seconds(2))
    }

    @Test
    func cancellationCleansUpChildAndThrowsCancellationError() async throws {
        let runner = ProcessRunner(terminationGracePeriod: .milliseconds(100))
        let task = Task {
            try await runner.run(
                ProcessCommand(executableURL: fixtureURL, arguments: ["ignore-term"]),
                timeout: nil
            )
        }
        try await Task.sleep(for: .milliseconds(250))
        let clock = ContinuousClock()
        let cancellationStart = clock.now

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to throw CancellationError")
        } catch is CancellationError {
            #expect(clock.now - cancellationStart < .seconds(2))
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test
    func directChildExitDoesNotWaitForDescendantHoldingInheritedPipes() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await ProcessRunner().run(
            ProcessCommand(
                executableURL: fixtureURL,
                arguments: ["exit-with-descendant-holding-pipes"]
            ),
            timeout: .seconds(5)
        )

        #expect(clock.now - start < .seconds(2))
        #expect(result.termination == .exited(status: 0))
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "parent-exited\n")
        #expect(result.standardError.isEmpty)
    }

    @Test
    func directChildExitStopsLargeInputWhileDescendantHoldsInheritedPipes() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await ProcessRunner().run(
            ProcessCommand(
                executableURL: fixtureURL,
                arguments: ["exit-with-descendant-holding-pipes"],
                standardInput: Data(repeating: 0x49, count: 8_388_608)
            ),
            timeout: .seconds(5)
        )

        #expect(clock.now - start < .seconds(2))
        #expect(result.termination == .exited(status: 0))
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "parent-exited\n")
        #expect(result.standardError.isEmpty)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/yumyum-process-fixture")
    }
}

private final class LockedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.withLock { chunks.append(data) }
    }

    func data() -> Data {
        lock.withLock { chunks.reduce(into: Data()) { $0.append($1) } }
    }

    func count() -> Int {
        lock.withLock { chunks.count }
    }
}

private final class AsyncTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false

    func signal() {
        lock.withLock { signalled = true }
    }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !value, clock.now < deadline {
            await Task.yield()
        }
        return value
    }

    private var value: Bool {
        lock.withLock { signalled }
    }
}
