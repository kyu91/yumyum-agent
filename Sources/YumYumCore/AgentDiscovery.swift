import Foundation

public enum AgentDefinitionID: String, CaseIterable, Codable, Sendable {
    case hermes
    case openCode = "opencode"
    case codex
    case claudeCode = "claude-code"

    public var displayName: String {
        switch self {
        case .hermes: "Hermes"
        case .openCode: "OpenCode"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    public var executableName: String {
        switch self {
        case .hermes: "hermes"
        case .openCode: "opencode"
        case .codex: "codex"
        case .claudeCode: "claude"
        }
    }
}

public enum AgentRuntimeContract: String, Equatable, Sendable {
    case hermesACP
    case openCodeRun
    case codexExec
    case claudePrint
}

public enum AgentAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

public struct AgentInstallation: Identifiable, Equatable, Sendable {
    public let definitionID: AgentDefinitionID
    public let path: String?
    public let version: String?
    public let runtimeContract: AgentRuntimeContract
    public let availability: AgentAvailability

    public var id: String {
        "\(definitionID.rawValue):\(path ?? "unavailable")"
    }

    public var availableDefinitionID: AgentDefinitionID? {
        availability == .available ? definitionID : nil
    }

    public init(
        definitionID: AgentDefinitionID,
        path: String?,
        version: String?,
        runtimeContract: AgentRuntimeContract,
        availability: AgentAvailability
    ) {
        self.definitionID = definitionID
        self.path = path
        self.version = version
        self.runtimeContract = runtimeContract
        self.availability = availability
    }
}

public enum AgentProcessEnvironment {
    public static func make(
        executableDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        [
            "HOME": homeDirectory.standardizedFileURL.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": [
                executableDirectory.standardizedFileURL.path,
                "/usr/bin",
                "/bin",
            ].joined(separator: ":"),
            "TERM": "dumb",
        ]
    }
}

public protocol AgentDiscovering: Sendable {
    func scan(
        explicitPaths: [AgentDefinitionID: String]
    ) async -> [AgentInstallation]
}

public struct AgentDiscovery: AgentDiscovering, Sendable {
    public static var defaultKnownExecutableDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent(".opencode/bin", isDirectory: true),
            home.appendingPathComponent(".claude/local", isDirectory: true),
            home.appendingPathComponent(".bun/bin", isDirectory: true),
        ]
    }

    private let knownExecutableDirectories: [URL]
    private let processRunner: any ProcessRunning
    private let timeout: Duration
    private let outputByteLimit: Int
    private let homeDirectory: URL

    public init(
        knownExecutableDirectories: [URL] = Self.defaultKnownExecutableDirectories,
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(2),
        outputByteLimit: Int = 65_536,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.knownExecutableDirectories = knownExecutableDirectories.map(\.standardizedFileURL)
        self.processRunner = processRunner
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func scan(
        explicitPaths: [AgentDefinitionID: String] = [:]
    ) async -> [AgentInstallation] {
        var results: [AgentInstallation] = []

        for definitionID in AgentDefinitionID.allCases {
            var candidates: [URL] = []
            if let explicitPath = explicitPaths[definitionID] {
                candidates.append(URL(fileURLWithPath: explicitPath).standardizedFileURL)
            }
            candidates.append(
                contentsOf: knownExecutableDirectories.map {
                    $0.appendingPathComponent(definitionID.executableName, isDirectory: false)
                }
            )

            var seen: Set<String> = []
            var foundCandidate = false
            for candidate in candidates where seen.insert(candidate.path).inserted {
                let isExplicit = explicitPaths[definitionID].map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path == candidate.path
                } ?? false
                guard isExplicit || FileManager.default.fileExists(atPath: candidate.path) else {
                    continue
                }
                foundCandidate = true
                results.append(await verify(definitionID, at: candidate))
            }

            if !foundCandidate {
                results.append(
                    AgentInstallation(
                        definitionID: definitionID,
                        path: nil,
                        version: nil,
                        runtimeContract: definitionID.runtimeContract,
                        availability: .unavailable(reason: "안전한 설치 경로에서 실행 파일을 찾지 못했습니다.")
                    )
                )
            }
        }

        return results
    }

    public func verify(
        _ definitionID: AgentDefinitionID,
        at executableURL: URL
    ) async -> AgentInstallation {
        let executableURL = executableURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard executableURL.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return unavailable(
                definitionID,
                path: executableURL.path,
                reason: "선택한 절대 경로가 실행 가능한 파일이 아닙니다."
            )
        }

        let environment = AgentProcessEnvironment.make(
            executableDirectory: executableURL.deletingLastPathComponent(),
            homeDirectory: homeDirectory
        )
        let versionResult: ProcessRunResult
        do {
            versionResult = try await processRunner.run(
                ProcessCommand(
                    executableURL: executableURL,
                    arguments: ["--version"],
                    environment: environment,
                    outputByteLimit: outputByteLimit
                ),
                timeout: timeout
            )
        } catch {
            return unavailable(
                definitionID,
                path: executableURL.path,
                reason: "버전 확인 프로세스를 시작하지 못했습니다."
            )
        }

        guard versionResult.termination == .exited(status: 0),
              let version = firstNonemptyLine(in: versionResult) else {
            return unavailable(
                definitionID,
                path: executableURL.path,
                reason: versionResult.timedOut
                    ? "버전 확인 시간이 초과되었습니다."
                    : "버전 정보를 확인하지 못했습니다."
            )
        }

        for contract in definitionID.helpContracts {
            let helpResult: ProcessRunResult
            do {
                helpResult = try await processRunner.run(
                    ProcessCommand(
                        executableURL: executableURL,
                        arguments: contract.arguments,
                        environment: environment,
                        outputByteLimit: outputByteLimit
                    ),
                    timeout: timeout
                )
            } catch {
                return unavailable(
                    definitionID,
                    path: executableURL.path,
                    version: version,
                    reason: "로컬 CLI 도움말 계약을 확인하지 못했습니다."
                )
            }

            let help = decodedOutput(helpResult)
            guard helpResult.termination == .exited(status: 0),
                  contract.requiredFragments.allSatisfy(help.contains) else {
                return unavailable(
                    definitionID,
                    path: executableURL.path,
                    version: version,
                    reason: "설치된 CLI의 공식 로컬 실행 계약이 지원 범위와 다릅니다."
                )
            }
        }

        return AgentInstallation(
            definitionID: definitionID,
            path: executableURL.path,
            version: version,
            runtimeContract: definitionID.runtimeContract,
            availability: .available
        )
    }

    private func unavailable(
        _ definitionID: AgentDefinitionID,
        path: String,
        version: String? = nil,
        reason: String
    ) -> AgentInstallation {
        AgentInstallation(
            definitionID: definitionID,
            path: path,
            version: version,
            runtimeContract: definitionID.runtimeContract,
            availability: .unavailable(reason: reason)
        )
    }

    private func firstNonemptyLine(in result: ProcessRunResult) -> String? {
        decodedOutput(result)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func decodedOutput(_ result: ProcessRunResult) -> String {
        String(decoding: result.standardOutput, as: UTF8.self)
            + "\n"
            + String(decoding: result.standardError, as: UTF8.self)
    }
}

private struct AgentHelpContract: Sendable {
    let arguments: [String]
    let requiredFragments: [String]
}

private extension AgentDefinitionID {
    var runtimeContract: AgentRuntimeContract {
        switch self {
        case .hermes: .hermesACP
        case .openCode: .openCodeRun
        case .codex: .codexExec
        case .claudeCode: .claudePrint
        }
    }

    var helpContracts: [AgentHelpContract] {
        switch self {
        case .hermes:
            [AgentHelpContract(
                arguments: ["acp", "--help"],
                requiredFragments: ["Start Hermes Agent in ACP mode", "--check"]
            )]
        case .openCode:
            [AgentHelpContract(
                arguments: ["run", "--help"],
                requiredFragments: [
                    "opencode run [message..]", "--pure", "--file", "--format",
                ]
            )]
        case .codex:
            [
                AgentHelpContract(
                    arguments: ["--help"],
                    requiredFragments: ["exec", "--ask-for-approval"]
                ),
                AgentHelpContract(
                    arguments: ["exec", "--help"],
                    requiredFragments: [
                        "Run Codex non-interactively", "--ephemeral", "--image",
                        "--sandbox", "--skip-git-repo-check",
                    ]
                ),
            ]
        case .claudeCode:
            [AgentHelpContract(
                arguments: ["--help"],
                requiredFragments: [
                    "--safe-mode", "--print", "--output-format", "--permission-mode",
                    "--no-session-persistence",
                ]
            )]
        }
    }
}
