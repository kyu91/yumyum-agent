import Foundation
import Testing
@testable import YumYumCore
@testable import YumYumApp

@Suite
struct AppShellViewModelTests {
    @Test
    @MainActor
    func soulDraftSurvivesLateLoadAndFlushesNormalizedLatestRevision() async throws {
        let store = ControlledSoulStore(loadedProfile: SoulProfile(name: "stored"))
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            soulStore: store
        )
        let loadTask = Task { @MainActor in await viewModel.loadSoul() }
        await store.waitForLoad()
        let rawDraft = SoulProfile(name: "  latest   draft  ")
        viewModel.updateSoulDraft(rawDraft)
        await store.resumeLoad()
        await loadTask.value

        #expect(viewModel.isSoulLoaded)
        #expect(viewModel.soulProfile == rawDraft)
        await viewModel.flushSoul()
        #expect(await store.savedProfiles == [rawDraft.normalized])
        #expect(viewModel.soulProfile == rawDraft)
        #expect(viewModel.soulSaveState == .savedWithNormalization)
    }

    @Test
    @MainActor
    func olderSoulSaveCannotPublishOrPersistAfterNewerRevision() async {
        let store = ControlledSoulStore(loadedProfile: .empty, suspendsFirstSave: true)
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            soulStore: store
        )
        await viewModel.loadSoul()
        viewModel.updateSoulDraft(SoulProfile(name: "old"))
        let oldSave = Task { @MainActor in await viewModel.saveSoul() }
        await store.waitForSave()
        viewModel.updateSoulDraft(SoulProfile(name: "new"))
        let newSave = Task { @MainActor in await viewModel.saveSoul() }
        await Task.yield()
        await store.resumeSave()
        await oldSave.value
        await newSave.value

        #expect(await store.savedProfiles.map(\.name) == ["old", "new"])
        #expect(viewModel.soulProfile.name == "new")
        #expect(viewModel.soulSaveState == .saved)
    }

    @Test
    @MainActor
    func refreshesDiscoveredAgentsAndSharesTheExplicitDefaultSelection() async throws {
        let codex = AgentInstallation(
            definitionID: .codex,
            path: "/safe/codex",
            version: "codex-cli 0.144.6",
            runtimeContract: .codexExec,
            availability: .available
        )
        let registry = AgentRegistry(
            discovery: StaticAgentDiscovery(installations: [codex]),
            persistence: EmptyAgentSelectionPersistence()
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: registry
        )

        await viewModel.refreshAgents(trigger: .appStart)
        #expect(viewModel.agentSnapshot.installations == [codex])
        #expect(!viewModel.canSendPrompt)

        try await viewModel.selectAgent(.codex, path: "/safe/codex")
        #expect(viewModel.canSendPrompt)
        #expect(viewModel.agentSnapshot.selectedInstallation == codex)

        await viewModel.refreshAgents(trigger: .quickMenuOpened)
        #expect(viewModel.agentSnapshot.selectedInstallation == codex)
    }

    @Test
    @MainActor
    func selectionChangesResetConnectorsAndShutdownClosesThem() async throws {
        let codex = AgentInstallation(
            definitionID: .codex,
            path: "/safe/codex",
            version: "codex-cli 0.144.6",
            runtimeContract: .codexExec,
            availability: .available
        )
        let claude = AgentInstallation(
            definitionID: .claudeCode,
            path: "/safe/claude",
            version: "2.1.12",
            runtimeContract: .claudePrint,
            availability: .available
        )
        let registry = AgentRegistry(
            discovery: StaticAgentDiscovery(installations: [codex, claude]),
            persistence: EmptyAgentSelectionPersistence()
        )
        let codexConnector = LifecycleConnector(definitionID: .codex)
        let claudeConnector = LifecycleConnector(definitionID: .claudeCode)
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: registry,
            connectors: [codexConnector, claudeConnector]
        )
        await viewModel.refreshAgents(trigger: .appStart)

        try await viewModel.selectAgent(.codex, path: "/safe/codex")
        try await viewModel.selectAgent(.claudeCode, path: "/safe/claude")
        let appDelegate = YumYumAppDelegate()
        appDelegate.configure(viewModel: viewModel)
        await appDelegate.shutdown()

        #expect(await codexConnector.resetCount == 2)
        #expect(await claudeConnector.resetCount == 2)
        #expect(await codexConnector.closeCount == 1)
        #expect(await claudeConnector.closeCount == 1)
    }

    @Test
    @MainActor
    func startsWithAnEmptyUnsavedPathAndEnablesOnlyAnAbsolutePath() {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("Hermes Fixture 0.0.0"))
        )

        #expect(viewModel.probeState == .idle)
        #expect(viewModel.connectionState == .idle)
        #expect(viewModel.hermesPath.isEmpty)
        #expect(viewModel.hermesPathStatus == .empty)
        #expect(!viewModel.canCheckHermesConnection)

        viewModel.hermesPath = "bin/hermes"
        #expect(viewModel.hermesPathStatus == .invalidAbsolutePath)
        #expect(!viewModel.canCheckHermesConnection)

        viewModel.hermesPath = "/opt/homebrew/bin/hermes"
        #expect(viewModel.hermesPathStatus == .absolutePathReady)
        #expect(viewModel.canCheckHermesConnection)
    }

    @Test
    @MainActor
    func reportsLoadingThenOriginalVersionOutputFromTheSelectedPath() async throws {
        let checker = ControlledHermesConnectionChecker()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: checker
        )
        viewModel.hermesPath = "  /custom/hermes  "

        let checkTask = Task { @MainActor in
            await viewModel.checkHermesConnection()
        }
        while !(await checker.hasStarted()) {
            await Task.yield()
        }

        #expect(viewModel.connectionState == .loading)
        #expect(!viewModel.canCheckHermesConnection)
        #expect(await checker.requestedPaths == ["/custom/hermes"])
        await checker.complete(returning: "Hermes 1.2.3\nbuild abc\n")
        await checkTask.value

        #expect(
            viewModel.connectionState
                == .success(version: "Hermes 1.2.3\nbuild abc\n")
        )
        #expect(viewModel.probeState == .idle)
    }

    @Test
    @MainActor
    func doesNotCheckAnInvalidPath() async {
        let checker = CountingHermesConnectionChecker()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: checker
        )
        viewModel.hermesPath = "bin/hermes"

        await viewModel.checkHermesConnection()

        #expect(viewModel.connectionState == .idle)
        #expect(await checker.callCount == 0)
    }

    @Test
    @MainActor
    func editingThePathClearsThePreviousConnectionResult() async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: ImmediateHermesConnectionChecker(
                result: .success("Hermes 1.2.3\n")
            )
        )
        viewModel.hermesPath = "/first/hermes"
        await viewModel.checkHermesConnection()
        #expect(viewModel.connectionState == .success(version: "Hermes 1.2.3\n"))

        viewModel.hermesPath = "/second/hermes"

        #expect(viewModel.connectionState == .idle)
    }

    @Test(arguments: [
        (
            HermesConnectionError.pathMustBeAbsolute("bin/hermes"),
            HermesConnectionState.pathError(
                message: HermesConnectionError.pathMustBeAbsolute("bin/hermes")
                    .errorDescription!
            )
        ),
        (
            HermesConnectionError.executableUnavailable("/missing/hermes"),
            HermesConnectionState.pathError(
                message: HermesConnectionError.executableUnavailable("/missing/hermes")
                    .errorDescription!
            )
        ),
        (
            HermesConnectionError.executionFailed(
                exitStatus: 23,
                standardError: "permission denied\n"
            ),
            HermesConnectionState.executionError(
                message: HermesConnectionError.executionFailed(
                    exitStatus: 23,
                    standardError: "permission denied\n"
                ).errorDescription!
            )
        ),
        (
            HermesConnectionError.emptyVersionOutput,
            HermesConnectionState.executionError(
                message: HermesConnectionError.emptyVersionOutput.errorDescription!
            )
        ),
    ])
    @MainActor
    func mapsPathAndExecutionErrorsToDistinctStates(
        error: HermesConnectionError,
        expectedState: HermesConnectionState
    ) async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: ImmediateHermesConnectionChecker(result: .failure(error))
        )
        viewModel.hermesPath = "/selected/hermes"

        await viewModel.checkHermesConnection()

        #expect(viewModel.connectionState == expectedState)
    }

    @Test
    @MainActor
    func reportsTimeoutSeparately() async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: ImmediateHermesConnectionChecker(result: .failure(.timedOut))
        )
        viewModel.hermesPath = "/selected/hermes"

        await viewModel.checkHermesConnection()

        #expect(viewModel.connectionState == .timedOut)
    }

    @Test
    @MainActor
    func cancellationReturnsToIdle() async {
        let checker = CancellableHermesConnectionChecker()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: checker
        )
        viewModel.hermesPath = "/selected/hermes"
        let task = Task { @MainActor in
            await viewModel.checkHermesConnection()
        }
        while !(await checker.hasStarted) {
            await Task.yield()
        }

        task.cancel()
        await task.value

        #expect(viewModel.connectionState == .idle)
        #expect(await checker.wasCancelled)
    }

    @Test
    @MainActor
    func reportsLoadingThenFixtureSuccessWithoutUsingTheHermesPath() async {
        let probe = ControlledFixtureProbe()
        let viewModel = YumYumAppViewModel(fixtureProbe: probe)
        viewModel.hermesPath = "/do/not/run/hermes"

        let probeTask = Task { @MainActor in
            await viewModel.runFixtureProbe()
        }
        while !(await probe.hasStarted()) {
            await Task.yield()
        }

        #expect(viewModel.probeState == .loading)
        await probe.complete(returning: "Hermes Fixture 0.0.0")
        await probeTask.value

        #expect(viewModel.probeState == .success(version: "Hermes Fixture 0.0.0"))
        #expect(viewModel.hermesPath == "/do/not/run/hermes")
        #expect(await probe.callCount == 1)
    }

    @Test
    @MainActor
    func presentsAStableFixtureError() async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .failure(.timedOut))
        )

        await viewModel.runFixtureProbe()

        #expect(
            viewModel.probeState
                == .failure(message: "안전한 fixture가 제한 시간 안에 응답하지 않았습니다.")
        )
    }
}

private actor ControlledSoulStore: SoulProfileStoring {
    let loadedProfile: SoulProfile
    let suspendsFirstSave: Bool
    private(set) var savedProfiles: [SoulProfile] = []
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var loadStarted = false
    private var saveStarted = false

    init(loadedProfile: SoulProfile, suspendsFirstSave: Bool = false) {
        self.loadedProfile = loadedProfile
        self.suspendsFirstSave = suspendsFirstSave
    }

    func load() async -> SoulProfile {
        guard !suspendsFirstSave else { return loadedProfile }
        loadStarted = true
        await withCheckedContinuation { loadContinuation = $0 }
        return loadedProfile
    }

    func save(_ profile: SoulProfile) async throws {
        if suspendsFirstSave && savedProfiles.isEmpty {
            saveStarted = true
            await withCheckedContinuation { saveContinuation = $0 }
        }
        savedProfiles.append(profile)
    }

    func waitForLoad() async {
        while !loadStarted { await Task.yield() }
    }

    func resumeLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func waitForSave() async {
        while !saveStarted { await Task.yield() }
    }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

private actor StaticAgentDiscovery: AgentDiscovering {
    let installations: [AgentInstallation]

    init(installations: [AgentInstallation]) {
        self.installations = installations
    }

    func scan(explicitPaths: [AgentDefinitionID: String]) async -> [AgentInstallation] {
        installations
    }
}

private actor EmptyAgentSelectionPersistence: AgentSelectionPersisting {
    func load() -> SelectedAgentReference? { nil }
    func save(_ reference: SelectedAgentReference?) {}
}

private struct ImmediateFixtureProbe: FixtureProbing {
    let fixturePath = "/test/yumyum-process-fixture"
    let result: Result<String, FixtureProbeError>

    func probe() async throws -> String {
        try result.get()
    }
}

private actor ControlledFixtureProbe: FixtureProbing {
    nonisolated let fixturePath = "/test/yumyum-process-fixture"
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<String, any Error>?

    func probe() async throws -> String {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        continuation != nil
    }

    func complete(returning version: String) {
        continuation?.resume(returning: version)
        continuation = nil
    }
}

private struct ImmediateHermesConnectionChecker: HermesConnectionChecking {
    let result: Result<String, HermesConnectionError>

    func check(executablePath: String) async throws -> String {
        try result.get()
    }
}

private actor CountingHermesConnectionChecker: HermesConnectionChecking {
    private(set) var callCount = 0

    func check(executablePath: String) async throws -> String {
        callCount += 1
        return "unused"
    }
}

private actor ControlledHermesConnectionChecker: HermesConnectionChecking {
    private(set) var requestedPaths: [String] = []
    private var continuation: CheckedContinuation<String, any Error>?

    func check(executablePath: String) async throws -> String {
        requestedPaths.append(executablePath)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        continuation != nil
    }

    func complete(returning version: String) {
        continuation?.resume(returning: version)
        continuation = nil
    }
}

private actor CancellableHermesConnectionChecker: HermesConnectionChecking {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func check(executablePath: String) async throws -> String {
        hasStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return "unused"
    }
}

private actor LifecycleConnector: AgentConnecting {
    nonisolated let definitionID: AgentDefinitionID
    private(set) var resetCount = 0
    private(set) var closeCount = 0

    init(definitionID: AgentDefinitionID) {
        self.definitionID = definitionID
    }

    func send(
        _ request: PromptRequest,
        executableURL: URL
    ) async throws -> PromptResponse {
        PromptResponse(text: "unused")
    }

    func reset() {
        resetCount += 1
    }

    func close() {
        closeCount += 1
    }
}
