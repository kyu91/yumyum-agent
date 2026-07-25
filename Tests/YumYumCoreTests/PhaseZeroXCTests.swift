#if canImport(XCTest)
import Foundation
import XCTest
@testable import YumYumCore

final class PhaseZeroXCTests: XCTestCase {
    func testExplicitLocatorRequiresAnExecutableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("hermes")
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let located = try HermesExecutableLocator(allowedPATHDirectories: []).locate(
            explicitPath: executable.path,
            pathEnvironment: nil
        )

        XCTAssertEqual(located, executable.standardizedFileURL)
    }

    func testVersionProbeUsesInjectedRunnerAndVersionArgument() async throws {
        let runner = XCTestProcessRunner(
            result: ProcessRunResult(
                standardOutput: Data("fixture-version\n".utf8),
                standardError: Data(),
                termination: .exited(status: 0)
            )
        )

        let result = try await HermesVersionProbe(processRunner: runner).probe(
            executableURL: URL(fileURLWithPath: "/allowed/hermes")
        )
        let command = await runner.lastCommand()

        XCTAssertEqual(command?.arguments, ["--version"])
        XCTAssertEqual(result.standardOutput, "fixture-version\n")
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testProcessRunnerCapturesDeterministicFixtureStreams() async throws {
        let result = try await ProcessRunner().run(
            ProcessCommand(executableURL: fixtureURL, arguments: ["emit"]),
            timeout: .seconds(2)
        )

        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "stdout-value")
        XCTAssertEqual(String(decoding: result.standardError, as: UTF8.self), "stderr-value")
        XCTAssertEqual(result.termination, .exited(status: 7))
    }

    func testProcessRunnerTimesOutUncooperativeFixture() async throws {
        let result = try await ProcessRunner(
            terminationGracePeriod: .milliseconds(100)
        ).run(
            ProcessCommand(executableURL: fixtureURL, arguments: ["ignore-term"]),
            timeout: .milliseconds(250)
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "ready\n")
    }

    func testACPCommandIsCapabilityGated() throws {
        let unavailableBuilder = HermesACPCommandBuilder(
            capabilityGate: HermesCapabilityGate(advertisedCapabilities: [])
        )
        XCTAssertThrowsError(
            try unavailableBuilder.makeCommand(
                executableURL: URL(fileURLWithPath: "/allowed/hermes")
            )
        ) { error in
            XCTAssertEqual(
                error as? HermesCapabilityError,
                .capabilityUnavailable(.acp)
            )
        }

        let availableBuilder = HermesACPCommandBuilder(
            capabilityGate: HermesCapabilityGate(advertisedCapabilities: [.acp])
        )
        let command = try availableBuilder.makeCommand(
            executableURL: URL(fileURLWithPath: "/allowed/hermes")
        )
        XCTAssertEqual(command.arguments, ["acp"])
    }

    func testExternalChangeToolsetsAreDeniedByDefault() {
        let policy = ExternalChangeToolsetPolicy()

        XCTAssertEqual(
            policy.decision(
                for: ToolsetDescriptor(identifier: "calendar", effect: .externalChange)
            ),
            .denied(.externalChangeRequiresApproval(toolsetID: "calendar"))
        )
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/yumyum-process-fixture")
    }
}

private actor XCTestProcessRunner: ProcessRunning {
    private let result: ProcessRunResult
    private var commands: [ProcessCommand] = []

    init(result: ProcessRunResult) {
        self.result = result
    }

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        commands.append(command)
        return result
    }

    func lastCommand() -> ProcessCommand? {
        commands.last
    }
}
#endif
