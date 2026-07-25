import Foundation
import Testing
@testable import YumYumCore

@Suite
struct FixtureProbeServiceTests {
    @Test
    func probesTheDeterministicFixture() async throws {
        let service = FixtureProbeService(
            fixtureURL: fixtureURL,
            processRunner: ProcessRunner()
        )

        let version = try await service.probe()

        #expect(version == "Hermes Fixture 0.0.0")
    }

    @Test
    func refusesAnyExecutableThatIsNotTheNamedFixture() async {
        let runner = CountingProcessRunner()
        let unsafeURL = URL(fileURLWithPath: "/tmp/hermes")
        let service = FixtureProbeService(
            fixtureURL: unsafeURL,
            processRunner: runner
        )

        do {
            _ = try await service.probe()
            Issue.record("Expected the service to reject a non-fixture executable")
        } catch {
            #expect(
                error as? FixtureProbeError
                    == .unsafeFixturePath(unsafeURL.standardizedFileURL.path)
            )
        }
        #expect(await runner.callCount == 0)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/yumyum-process-fixture")
    }
}

private actor CountingProcessRunner: ProcessRunning {
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
