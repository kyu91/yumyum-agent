import Foundation
import Testing
@testable import YumYumCore

@Suite
struct CodexLoginServiceTests {
    @Test
    func statusAndLoginUseExactCommandsAndConfirmAuthentication() async throws {
        let runner = RecordingCodexProcessRunner(results: [
            result(status: 1),
            result(status: 0),
            result(status: 0),
        ])
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: runner,
            homeDirectory: URL(fileURLWithPath: "/safe/home")
        )

        #expect(!(try await service.status(for: codex)))
        try await service.login(using: codex)

        let calls = await runner.calls
        #expect(calls.map(\.command.executableURL.path) == Array(repeating: "/safe/codex", count: 3))
        #expect(calls.map(\.command.arguments) == [["login", "status"], ["login"], ["login", "status"]])
        #expect(calls.map(\.timeout) == [.seconds(5), .seconds(600), .seconds(5)])
        #expect(calls.allSatisfy { $0.command.outputByteLimit == 65_536 })
        #expect(calls.allSatisfy {
            $0.command.environment == [
                "HOME": "/safe/home",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "PATH": "/safe:/usr/bin:/bin",
                "TERM": "dumb",
            ]
        })
    }

    @Test
    func unavailableOrStaleInstallationNeverLaunches() async {
        let runner = RecordingCodexProcessRunner(results: [])
        let stale = AgentInstallation(
            definitionID: .codex,
            path: "/safe/codex",
            version: nil,
            runtimeContract: .codexExec,
            availability: .unavailable(reason: "stale")
        )
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: stale),
            processRunner: runner
        )

        await #expect(throws: CodexLoginError.unavailable) {
            try await service.login(using: codex)
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test
    func duplicateAttemptIsRejectedAndCancellationReachesRunner() async throws {
        let runner = BlockingCodexProcessRunner()
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: runner
        )
        let first = Task { try await service.login(using: codex) }
        await runner.waitUntilStarted()

        await #expect(throws: CodexLoginError.duplicateAttempt) {
            try await service.login(using: codex)
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await runner.wasCancelled)
    }

    @Test
    func loginRequiresSuccessfulPostLoginStatus() async {
        let runner = RecordingCodexProcessRunner(results: [result(status: 0), result(status: 1)])
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: runner
        )

        await #expect(throws: CodexLoginError.failed) {
            try await service.login(using: codex)
        }
    }

    @Test
    func logoutAndChangeAccountUseExactOrderedCommands() async throws {
        let runner = RecordingCodexProcessRunner(results: [
            result(status: 0), result(status: 1),
            result(status: 0), result(status: 0), result(status: 0),
        ])
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: runner
        )

        try await service.logout(using: codex)
        try await service.changeAccount(using: codex)

        #expect(await runner.calls.map(\.command.arguments) == [
            ["logout"], ["login", "status"],
            ["logout"], ["login"], ["login", "status"],
        ])
        #expect(await runner.calls.map(\.timeout) == [
            .seconds(30), .seconds(5), .seconds(30), .seconds(600), .seconds(5),
        ])
    }

    @Test
    func changeAccountFailureAfterLogoutNeverReportsSignedIn() async {
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: RecordingCodexProcessRunner(results: [
                result(status: 0), result(status: 1),
            ])
        )

        await #expect(throws: CodexLoginError.changeFailedNeedsLogin) {
            try await service.changeAccount(using: codex)
        }
    }

    @Test
    func reportsStatusAndLoginTimeoutsWithoutUsingOutput() async {
        let statusService = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: RecordingCodexProcessRunner(results: [timedOutResult])
        )
        await #expect(throws: CodexLoginError.timedOut) {
            try await statusService.status(for: codex)
        }

        let loginService = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: RecordingCodexProcessRunner(results: [timedOutResult])
        )
        await #expect(throws: CodexLoginError.timedOut) {
            try await loginService.login(using: codex)
        }
    }

    @Test
    func localizedStatesContainNoProcessOrCredentialDetails() {
        for state in [
            CodexLoginState.unavailable,
            .checking,
            .loginRequired,
            .awaitingBrowserSignIn,
            .signedIn,
            .loggingOut,
            .changingAccount,
            .loggedOut,
            .changeFailedNeedsLogin,
            .cancelled,
            .timedOut,
            .failed,
        ] {
            let text = state.localizedDescription.lowercased()
            #expect(!text.contains("stderr"))
            #expect(!text.contains("/users/"))
            #expect(!text.contains("token"))
        }
    }

    @Test
    @MainActor
    func approvalCancelLaunchesNothingAndEveryAttemptUsesANewRequest() async throws {
        let runner = RecordingCodexProcessRunner(results: [
            result(status: 1),
            result(status: 0),
            result(status: 0),
        ])
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: runner
        )
        let registry = AgentRegistry(
            discovery: SingleCodexDiscovery(installation: codex),
            persistence: NoAgentSelectionPersistence()
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe(),
            agentRegistry: registry,
            codexLoginService: service
        )
        await viewModel.refreshAgents(trigger: .appStart)
        let cancelled = try #require(viewModel.requestCodexLoginApproval(for: codex))
        viewModel.cancelCodexLoginApproval(cancelled)
        await viewModel.confirmCodexLogin(cancelled)
        #expect(await runner.calls.count == 1)

        let approved = try #require(viewModel.requestCodexLoginApproval(for: codex))
        #expect(approved != cancelled)
        await viewModel.confirmCodexLogin(approved)

        #expect(await runner.calls.map(\.command.arguments) == [
            ["login", "status"],
            ["login"],
            ["login", "status"],
        ])
        #expect(viewModel.codexLoginState == .signedIn)
        #expect(viewModel.agentSnapshot.selection == .unselected)
    }

    @Test
    @MainActor
    func everyAvailableCodexRowCanApproveAndSecondRowUsesItsExactPath() async throws {
        let secondCodex = codex(at: "/safe/other/codex")
        let runner = RecordingCodexProcessRunner(results: [
            result(status: 1),
            result(status: 0),
            result(status: 0),
        ])
        let service = CodexLoginService(
            verifier: MatchingInstallationVerifier(),
            processRunner: runner
        )
        let registry = AgentRegistry(
            discovery: MutableCodexDiscovery(installations: [codex, secondCodex]),
            persistence: NoAgentSelectionPersistence()
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe(),
            agentRegistry: registry,
            codexLoginService: service
        )

        await viewModel.refreshAgents(trigger: .appStart)
        #expect(viewModel.agentSnapshot.installations.allSatisfy {
            viewModel.requestCodexLoginApproval(for: $0) != nil
        })
        let approval = try #require(viewModel.requestCodexLoginApproval(for: secondCodex))
        await viewModel.confirmCodexLogin(approval)

        #expect(await runner.calls.map(\.command.executableURL.path) == [
            "/safe/codex",
            "/safe/other/codex",
            "/safe/other/codex",
        ])
    }

    @Test
    @MainActor
    func approvalForRemovedSecondCodexRowLaunchesNothing() async throws {
        let secondCodex = codex(at: "/safe/other/codex")
        let runner = RecordingCodexProcessRunner(results: [result(status: 1), result(status: 1)])
        let discovery = MutableCodexDiscovery(installations: [codex, secondCodex])
        let service = CodexLoginService(
            verifier: MatchingInstallationVerifier(),
            processRunner: runner
        )
        let registry = AgentRegistry(
            discovery: discovery,
            persistence: NoAgentSelectionPersistence()
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe(),
            agentRegistry: registry,
            codexLoginService: service
        )

        await viewModel.refreshAgents(trigger: .appStart)
        let approval = try #require(viewModel.requestCodexLoginApproval(for: secondCodex))
        await discovery.setInstallations([codex])
        await viewModel.refreshAgents(trigger: .manualRescan)
        await viewModel.confirmCodexLogin(approval)

        #expect(await runner.calls.map(\.command.arguments) == [
            ["login", "status"],
            ["login", "status"],
        ])
    }

    @Test
    @MainActor
    func unauthenticatedCodexCannotBeSelected() async throws {
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: RecordingCodexProcessRunner(results: [result(status: 1), result(status: 1)])
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe(),
            agentRegistry: AgentRegistry(
                discovery: SingleCodexDiscovery(installation: codex),
                persistence: NoAgentSelectionPersistence()
            ),
            codexLoginService: service
        )
        await viewModel.refreshAgents(trigger: .appStart)

        await #expect(throws: AgentRuntimeError.codexAuthenticationRequired) {
            try await viewModel.selectAgent(.codex, path: "/safe/codex")
        }
        #expect(viewModel.agentSnapshot.selection == .unselected)
    }

    @Test
    @MainActor
    func selectedCodexReadinessTracksAuthenticationWithoutChangingSelectionOrSending() async throws {
        let runner = ControlledCodexProcessRunner()
        let connector = RuntimeCodexConnector()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe(),
            agentRegistry: AgentRegistry(
                discovery: SingleCodexDiscovery(installation: codex),
                persistence: NoAgentSelectionPersistence()
            ),
            connectors: [connector],
            codexLoginService: CodexLoginService(
                verifier: StaticInstallationVerifier(installation: codex),
                processRunner: runner
            )
        )

        let refresh = Task { @MainActor in await viewModel.refreshAgents(trigger: .appStart) }
        await runner.waitForCall(count: 1)
        await runner.complete(status: 0)
        await refresh.value
        let selection = Task { @MainActor in
            try await viewModel.selectAgent(.codex, path: "/safe/codex")
        }
        await runner.waitForCall(count: 2)
        await runner.complete(status: 0)
        try await selection.value
        #expect(viewModel.canSendPrompt)

        let expiredRefresh = Task { @MainActor in
            await viewModel.refreshCodexLoginStatus()
        }
        await runner.waitForCall(count: 3)
        #expect(viewModel.codexLoginState == .checking)
        #expect(!viewModel.canSendPrompt)
        await runner.complete(status: 1)
        await expiredRefresh.value
        #expect(!viewModel.canSendPrompt)
        #expect(viewModel.agentSnapshot.selectedInstallation == codex)

        let login = try #require(viewModel.requestCodexLoginApproval(for: codex))
        let loginTask = Task { @MainActor in await viewModel.confirmCodexLogin(login) }
        await runner.waitForCall(count: 4)
        #expect(!viewModel.canSendPrompt)
        await runner.complete(status: 0)
        await runner.waitForCall(count: 5)
        await runner.complete(status: 0)
        await loginTask.value
        #expect(viewModel.canSendPrompt)
        #expect(await connector.requestCount == 0)

        let logout = try #require(viewModel.requestCodexLoginApproval(for: codex, operation: .logout))
        let logoutTask = Task { @MainActor in await viewModel.confirmCodexLogin(logout) }
        await runner.waitForCall(count: 6)
        #expect(viewModel.codexLoginState == .loggingOut)
        #expect(!viewModel.canSendPrompt)
        await runner.complete(status: 0)
        await runner.waitForCall(count: 7)
        await runner.complete(status: 1)
        await logoutTask.value
        #expect(viewModel.codexLoginState == .loggedOut)
        #expect(!viewModel.canSendPrompt)

        let change = try #require(viewModel.requestCodexLoginApproval(for: codex, operation: .changeAccount))
        let changeTask = Task { @MainActor in await viewModel.confirmCodexLogin(change) }
        await runner.waitForCall(count: 8)
        #expect(viewModel.codexLoginState == .changingAccount)
        #expect(!viewModel.canSendPrompt)
        await runner.complete(status: 0)
        await runner.waitForCall(count: 9)
        await runner.complete(status: 0)
        await runner.waitForCall(count: 10)
        await runner.complete(status: 0)
        await changeTask.value
        #expect(viewModel.canSendPrompt)
        #expect(viewModel.agentSnapshot.selectedInstallation == codex)
    }

    @Test
    @MainActor
    func selectedNonCodexReadinessIgnoresCodexLoginState() async throws {
        let claude = AgentInstallation(
            definitionID: .claudeCode,
            path: "/safe/claude",
            version: "claude-code",
            runtimeContract: .claudePrint,
            availability: .available
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: UnusedFixtureProbe(),
            agentRegistry: AgentRegistry(
                discovery: StaticLoginAgentDiscovery(installations: [claude]),
                persistence: NoAgentSelectionPersistence()
            )
        )

        await viewModel.refreshAgents(trigger: .appStart)
        try await viewModel.selectAgent(.claudeCode, path: "/safe/claude")

        #expect(viewModel.codexLoginState == .unavailable)
        #expect(viewModel.canSendPrompt)
    }

    @Test
    func runtimeBlocksUnauthenticatedCodexBeforeConnectorSend() async throws {
        let connector = RuntimeCodexConnector()
        let service = CodexLoginService(
            verifier: StaticInstallationVerifier(installation: codex),
            processRunner: RecordingCodexProcessRunner(results: [result(status: 1)])
        )
        let runtime = AgentRuntime(
            selection: RuntimeCodexSelection(installation: codex),
            connectors: [connector],
            codexLoginService: service
        )

        await #expect(throws: AgentRuntimeError.codexAuthenticationRequired) {
            try await runtime.send(PromptRequest(text: "keep me"))
        }
        #expect(await connector.requestCount == 0)
    }

    private var codex: AgentInstallation {
        codex(at: "/safe/codex")
    }

    private func codex(at path: String) -> AgentInstallation {
        AgentInstallation(
            definitionID: .codex,
            path: path,
            version: "codex-cli",
            runtimeContract: .codexExec,
            availability: .available
        )
    }

    private static func result(status: Int32) -> ProcessRunResult {
        ProcessRunResult(standardOutput: Data(), standardError: Data(), termination: .exited(status: status))
    }

    private func result(status: Int32) -> ProcessRunResult { Self.result(status: status) }

    private var timedOutResult: ProcessRunResult {
        ProcessRunResult(
            standardOutput: Data("sensitive process output".utf8),
            standardError: Data("private process error".utf8),
            termination: .timedOut
        )
    }
}

private actor StaticInstallationVerifier: AgentInstallationVerifying {
    let installation: AgentInstallation

    init(installation: AgentInstallation) {
        self.installation = installation
    }

    func verify(_ definitionID: AgentDefinitionID, at executableURL: URL) -> AgentInstallation {
        installation
    }
}

private actor MatchingInstallationVerifier: AgentInstallationVerifying {
    func verify(_ definitionID: AgentDefinitionID, at executableURL: URL) -> AgentInstallation {
        AgentInstallation(
            definitionID: definitionID,
            path: executableURL.path,
            version: "codex-cli",
            runtimeContract: .codexExec,
            availability: .available
        )
    }
}

private actor RecordingCodexProcessRunner: ProcessRunning {
    struct Call: Sendable {
        let command: ProcessCommand
        let timeout: Duration?
    }

    private(set) var calls: [Call] = []
    private var results: [ProcessRunResult]

    init(results: [ProcessRunResult]) { self.results = results }

    func run(_ command: ProcessCommand, timeout: Duration?) throws -> ProcessRunResult {
        calls.append(Call(command: command, timeout: timeout))
        return results.removeFirst()
    }
}

private actor BlockingCodexProcessRunner: ProcessRunning {
    private(set) var wasCancelled = false
    private var started = false

    func run(_ command: ProcessCommand, timeout: Duration?) async throws -> ProcessRunResult {
        started = true
        do {
            while true { try await Task.sleep(for: .seconds(1)) }
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private actor ControlledCodexProcessRunner: ProcessRunning {
    private var callCount = 0
    private var continuations: [CheckedContinuation<ProcessRunResult, Never>] = []

    func run(_ command: ProcessCommand, timeout: Duration?) async -> ProcessRunResult {
        callCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func waitForCall(count: Int) async {
        while callCount < count { await Task.yield() }
    }

    func complete(status: Int32) {
        continuations.removeFirst().resume(
            returning: ProcessRunResult(
                standardOutput: Data(),
                standardError: Data(),
                termination: .exited(status: status)
            )
        )
    }
}

private actor SingleCodexDiscovery: AgentDiscovering {
    let installation: AgentInstallation

    init(installation: AgentInstallation) {
        self.installation = installation
    }

    func scan(explicitPaths: [AgentDefinitionID: String]) -> [AgentInstallation] {
        [installation]
    }
}

private actor StaticLoginAgentDiscovery: AgentDiscovering {
    let installations: [AgentInstallation]

    init(installations: [AgentInstallation]) {
        self.installations = installations
    }

    func scan(explicitPaths: [AgentDefinitionID: String]) -> [AgentInstallation] {
        installations
    }
}

private actor MutableCodexDiscovery: AgentDiscovering {
    private var installations: [AgentInstallation]

    init(installations: [AgentInstallation]) {
        self.installations = installations
    }

    func scan(explicitPaths: [AgentDefinitionID: String]) -> [AgentInstallation] {
        installations
    }

    func setInstallations(_ installations: [AgentInstallation]) {
        self.installations = installations
    }
}

private actor NoAgentSelectionPersistence: AgentSelectionPersisting {
    func load() -> SelectedAgentReference? { nil }
    func save(_ reference: SelectedAgentReference?) {}
}

private struct UnusedFixtureProbe: FixtureProbing {
    let fixturePath = "/unused"

    func probe() async throws -> String { "unused" }
}

private actor RuntimeCodexSelection: AgentSelectionValidating {
    let installation: AgentInstallation

    init(installation: AgentInstallation) {
        self.installation = installation
    }

    func validatedSelection() -> AgentInstallation { installation }
}

private actor RuntimeCodexConnector: AgentConnecting {
    let definitionID = AgentDefinitionID.codex
    private(set) var requestCount = 0

    func send(_ request: PromptRequest, executableURL: URL) -> PromptResponse {
        requestCount += 1
        return PromptResponse(text: "unexpected")
    }
}
