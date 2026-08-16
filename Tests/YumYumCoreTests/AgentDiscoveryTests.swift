import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AgentDiscoveryTests {
    @Test
    func discoversAndVerifiesAllSupportedAgentsFromAKnownDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["hermes", "opencode", "codex", "claude", "gemini"] {
            let executable = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let runner = DiscoveryProcessRunner()
        let discovery = AgentDiscovery(
            knownExecutableDirectories: [directory],
            processRunner: runner,
            timeout: .seconds(2),
            outputByteLimit: 65_536
        )

        let installations = await discovery.scan()

        #expect(
            installations.compactMap(\.availableDefinitionID)
                == [.hermes, .openCode, .codex, .claudeCode, .gemini]
        )
        #expect(
            installations.compactMap(\.version)
                == [
                    "Hermes 1.0.0",
                    "OpenCode 1.18.5",
                    "codex-cli 0.144.6",
                    "2.1.211 (Claude Code)",
                    "0.5.3",
                ]
        )

        let invocations = await runner.invocations
        #expect(invocations.count == 11)
        #expect(invocations.filter {
            $0.command.executableURL.lastPathComponent == "gemini"
        }.map(\.command.arguments) == [["--version"], ["--help"]])
        for invocation in invocations {
            #expect(invocation.timeout == .seconds(2))
            #expect(invocation.command.outputByteLimit == 65_536)
            #expect(invocation.command.executableURL.deletingLastPathComponent() == directory)
            #expect(
                invocation.command.environment
                    == AgentProcessEnvironment.make(
                        executableDirectory: directory,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
            )
        }
        #expect(!invocations.contains { $0.command.executableURL.path == "/bin/sh" })
    }

    @Test
    func acceptsGeminiWithBareSemverWhenHelpContainsACP() async throws {
        let executable = try makeExecutable(named: "gemini")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let discovery = AgentDiscovery(
            knownExecutableDirectories: [],
            processRunner: DiscoveryProcessRunner(
                versionOutputOverrides: ["gemini": "0.5.3\n"]
            )
        )

        let installation = await discovery.verify(.gemini, at: executable)

        #expect(installation.availability == .available)
    }

    @Test
    func rejectsGeminiWhenHelpDoesNotContainACP() async throws {
        let executable = try makeExecutable(named: "gemini")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = DiscoveryProcessRunner(
            versionOutputOverrides: ["gemini": "0.5.3\n"],
            omittingHelpFragment: "ACP"
        )
        let discovery = AgentDiscovery(
            knownExecutableDirectories: [],
            processRunner: runner
        )

        let installation = await discovery.verify(.gemini, at: executable)

        #expect(installation.version == "0.5.3")
        #expect(installation.availability != .available)
        #expect(
            await runner.invocations.map(\.command.arguments)
                == [["--version"], ["--help"]]
        )
    }

    @Test
    func processEnvironmentIncludesUserIdentityAlongsideHomeAndPath() {
        let environment = AgentProcessEnvironment.make(
            executableDirectory: URL(fileURLWithPath: "/safe/bin"),
            homeDirectory: URL(fileURLWithPath: "/safe/home"),
            userName: "duncan"
        )

        #expect(environment["USER"] == "duncan")
        #expect(environment["LOGNAME"] == "duncan")
        #expect(environment["HOME"] == "/safe/home")
    }

    @Test
    func processEnvironmentPathCoversBothHomebrewPrefixesForShebangInterpreters() throws {
        let environment = AgentProcessEnvironment.make(
            executableDirectory: URL(fileURLWithPath: "/Users/duncan/.local/bin"),
            homeDirectory: URL(fileURLWithPath: "/safe/home")
        )

        let path = try #require(environment["PATH"])
        let components = path.split(separator: ":").map(String.init)
        #expect(components == [
            "/Users/duncan/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])
    }

    @Test
    func rejectsAgentsWhenARuntimeCriticalFlagIsMissingFromHelp() async throws {
        let cases: [(AgentDefinitionID, String)] = [
            (.openCode, "--pure"),
            (.openCode, "json"),
            (.codex, "--ask-for-approval"),
            (.codex, "--json"),
            (.codex, "resume"),
            (.codex, "--skip-git-repo-check"),
            (.claudeCode, "stream-json"),
            (.claudeCode, "--include-partial-messages"),
            (.claudeCode, "--session-id"),
            (.claudeCode, "--resume"),
            (.gemini, "ACP"),
        ]

        for (definitionID, missingFlag) in cases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let executable = directory.appendingPathComponent(definitionID.executableName)
            try Data(definitionID.rawValue.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            let discovery = AgentDiscovery(
                knownExecutableDirectories: [],
                processRunner: DiscoveryProcessRunner(omittingHelpFragment: missingFlag)
            )

            let installation = await discovery.verify(definitionID, at: executable)

            #expect(
                installation.availability != .available,
                "\(definitionID) must be unavailable without \(missingFlag)"
            )
        }
    }
}

private func makeExecutable(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let executable = directory.appendingPathComponent(name)
    try Data(name.utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
    )
    return executable
}

private actor DiscoveryProcessRunner: ProcessRunning {
    struct Invocation: Sendable {
        let command: ProcessCommand
        let timeout: Duration?
    }

    private let omittedHelpFragment: String?
    private let versionOutputOverrides: [String: String]
    private(set) var invocations: [Invocation] = []

    init(
        versionOutputOverrides: [String: String] = [:],
        omittingHelpFragment: String? = nil
    ) {
        self.versionOutputOverrides = versionOutputOverrides
        self.omittedHelpFragment = omittingHelpFragment
    }

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        invocations.append(Invocation(command: command, timeout: timeout))
        let name = command.executableURL.lastPathComponent
        let output: String

        if command.arguments == ["--version"] {
            output = versionOutputOverrides[name] ?? [
                "hermes": "Hermes 1.0.0\n",
                "opencode": "OpenCode 1.18.5\n",
                "codex": "codex-cli 0.144.6\n",
                "claude": "2.1.211 (Claude Code)\n",
                "gemini": "0.5.3\n",
            ][name] ?? ""
        } else if name == "codex", command.arguments == ["--help"] {
            output = helpOutput(
                "Codex CLI\nexec\n--ask-for-approval\n"
            )
        } else {
            output = helpOutput([
                "hermes": "Start Hermes Agent in ACP mode\n--check\n",
                "opencode": "opencode run [message..]\n--pure\n--file\n--format <format> default json\n",
                "codex": "Run Codex non-interactively\nresume\n--json\n--image\n--sandbox\n--skip-git-repo-check\n",
                "claude": "--print\n--verbose\n--output-format text json stream-json\n--include-partial-messages\n--permission-mode\n--session-id\n--resume\n",
                "gemini": "Gemini CLI\n--ACP\n",
            ][name] ?? "")
        }

        return ProcessRunResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }

    private func helpOutput(_ output: String) -> String {
        guard let omittedHelpFragment else {
            return output
        }
        return output.replacingOccurrences(of: omittedHelpFragment, with: "")
    }
}
