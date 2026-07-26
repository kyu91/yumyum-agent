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

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/yumyum-process-fixture")
    }
}
