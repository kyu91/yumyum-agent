import Foundation

public enum CodexLoginState: Equatable, Sendable {
    case unavailable
    case checking
    case loginRequired
    case awaitingBrowserSignIn
    case signedIn
    case loggingOut
    case changingAccount
    case loggedOut
    case changeFailedNeedsLogin
    case cancelled
    case timedOut
    case failed

    public var localizedDescription: String {
        switch self {
        case .unavailable:
            AppText.localized(english: "Codex unavailable", korean: "Codex를 사용할 수 없음")
        case .checking:
            AppText.localized(english: "Checking ChatGPT sign-in…", korean: "ChatGPT 로그인 확인 중…")
        case .loginRequired:
            AppText.localized(english: "ChatGPT sign-in required", korean: "ChatGPT 로그인 필요")
        case .awaitingBrowserSignIn:
            AppText.localized(english: "Waiting for browser sign-in…", korean: "브라우저 로그인 대기 중…")
        case .signedIn:
            AppText.localized(english: "Signed in with ChatGPT", korean: "ChatGPT로 로그인됨")
        case .loggingOut:
            AppText.localized(english: "Signing out…", korean: "로그아웃 중…")
        case .changingAccount:
            AppText.localized(english: "Changing ChatGPT account…", korean: "ChatGPT 계정 변경 중…")
        case .loggedOut:
            AppText.localized(english: "Signed out of ChatGPT", korean: "ChatGPT에서 로그아웃됨")
        case .changeFailedNeedsLogin:
            AppText.localized(english: "Account change failed. Sign in required.", korean: "계정 변경에 실패했습니다. 로그인이 필요합니다.")
        case .cancelled:
            AppText.localized(english: "Sign-in cancelled", korean: "로그인 취소됨")
        case .timedOut:
            AppText.localized(english: "Sign-in timed out", korean: "로그인 시간 초과")
        case .failed:
            AppText.localized(english: "Could not verify ChatGPT sign-in", korean: "ChatGPT 로그인을 확인하지 못함")
        }
    }
}

public enum CodexLoginError: Error, Equatable, Sendable {
    case unavailable
    case duplicateAttempt
    case timedOut
    case failed
    case changeFailedNeedsLogin
}

public protocol AgentInstallationVerifying: Sendable {
    func verify(_ definitionID: AgentDefinitionID, at executableURL: URL) async -> AgentInstallation
}

extension AgentDiscovery: AgentInstallationVerifying {}

public actor CodexLoginService {
    public static let statusTimeout: Duration = .seconds(5)
    public static let loginTimeout: Duration = .seconds(600)
    public static let logoutTimeout: Duration = .seconds(30)
    public static let outputByteLimit = 65_536

    private let verifier: any AgentInstallationVerifying
    private let processRunner: any ProcessRunning
    private let homeDirectory: URL
    private var operationInProgress = false

    public init(
        verifier: any AgentInstallationVerifying = AgentDiscovery(),
        processRunner: any ProcessRunning = ProcessRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.verifier = verifier
        self.processRunner = processRunner
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func status(for installation: AgentInstallation) async throws -> Bool {
        try await withOperation {
            try await runStatus(executableURL: revalidatedExecutableURL(installation))
        }
    }

    public func login(using installation: AgentInstallation) async throws {
        try await withOperation {
            let executableURL = try await revalidatedExecutableURL(installation)
            try await runSuccessful(
                executableURL: executableURL,
                arguments: ["login"],
                timeout: Self.loginTimeout
            )
            guard try await runStatus(executableURL: executableURL) else {
                throw CodexLoginError.failed
            }
        }
    }

    public func logout(using installation: AgentInstallation) async throws {
        try await withOperation {
            let executableURL = try await revalidatedExecutableURL(installation)
            try await runSuccessful(
                executableURL: executableURL,
                arguments: ["logout"],
                timeout: Self.logoutTimeout
            )
            guard !(try await runStatus(executableURL: executableURL)) else {
                throw CodexLoginError.failed
            }
        }
    }

    public func changeAccount(using installation: AgentInstallation) async throws {
        try await withOperation {
            let executableURL = try await revalidatedExecutableURL(installation)
            try await runSuccessful(
                executableURL: executableURL,
                arguments: ["logout"],
                timeout: Self.logoutTimeout
            )
            do {
                try await runSuccessful(
                    executableURL: executableURL,
                    arguments: ["login"],
                    timeout: Self.loginTimeout
                )
                guard try await runStatus(executableURL: executableURL) else {
                    throw CodexLoginError.failed
                }
            } catch {
                throw CodexLoginError.changeFailedNeedsLogin
            }
        }
    }

    private func withOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard !operationInProgress else { throw CodexLoginError.duplicateAttempt }
        operationInProgress = true
        defer { operationInProgress = false }
        return try await operation()
    }

    private func revalidatedExecutableURL(
        _ installation: AgentInstallation
    ) async throws -> URL {
        guard installation.definitionID == .codex,
              installation.availability == .available,
              let path = installation.path else {
            throw CodexLoginError.unavailable
        }
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        guard executableURL.path == path else { throw CodexLoginError.unavailable }
        let verified = await verifier.verify(.codex, at: executableURL)
        guard verified.definitionID == .codex,
              verified.path == path,
              verified.availability == .available else {
            throw CodexLoginError.unavailable
        }
        return executableURL
    }

    private func runStatus(executableURL: URL) async throws -> Bool {
        let result = try await run(
            executableURL: executableURL,
            arguments: ["login", "status"],
            timeout: Self.statusTimeout
        )
        guard !result.timedOut else { throw CodexLoginError.timedOut }
        return result.termination == .exited(status: 0)
    }

    private func runSuccessful(
        executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async throws {
        let result = try await run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout
        )
        guard !result.timedOut else { throw CodexLoginError.timedOut }
        guard result.termination == .exited(status: 0) else {
            throw CodexLoginError.failed
        }
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> ProcessRunResult {
        do {
            return try await processRunner.run(
                ProcessCommand(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: AgentProcessEnvironment.make(
                        executableDirectory: executableURL.deletingLastPathComponent(),
                        homeDirectory: homeDirectory
                    ),
                    outputByteLimit: Self.outputByteLimit
                ),
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexLoginError.failed
        }
    }
}
