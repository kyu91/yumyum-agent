import Foundation
import Testing
@testable import YumYumCore

@Suite(.serialized)
struct ProbeCLITests {
    @Test
    func probesOnlyTheExplicitFixturePathAndPrintsStructuredResult() async throws {
        let result = try await ProcessRunner().run(
            ProcessCommand(
                executableURL: probeURL,
                arguments: ["--hermes", fixtureURL.path]
            ),
            timeout: .seconds(3)
        )
        let output = try JSONDecoder().decode(
            ProbeOutput.self,
            from: result.standardOutput
        )

        #expect(result.termination == .exited(status: 0))
        #expect(result.standardError.isEmpty)
        #expect(output.standardOutput == "Hermes Fixture 0.0.0\n")
        #expect(output.standardError.isEmpty)
        #expect(output.exitStatus == 0)
        #expect(!output.timedOut)
    }

    @Test
    func refusesToSearchOrProbeWithoutAnExplicitPath() async throws {
        let result = try await ProcessRunner().run(
            ProcessCommand(executableURL: probeURL),
            timeout: .seconds(2)
        )

        #expect(result.termination == .exited(status: 64))
        #expect(result.standardOutput.isEmpty)
        #expect(
            String(decoding: result.standardError, as: UTF8.self)
                == "Usage: yumyum-probe --hermes <absolute-path>\n"
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var probeURL: URL {
        packageRoot.appendingPathComponent(".build/debug/yumyum-probe")
    }

    private var fixtureURL: URL {
        packageRoot.appendingPathComponent(".build/debug/yumyum-process-fixture")
    }
}

private struct ProbeOutput: Decodable {
    let standardOutput: String
    let standardError: String
    let exitStatus: Int32?
    let timedOut: Bool
}
