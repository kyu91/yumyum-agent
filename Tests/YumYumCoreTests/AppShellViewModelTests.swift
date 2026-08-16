import Foundation
import Testing
@testable import YumYumCore
@testable import YumYumApp

@Suite(.serialized)
struct AppGlobalStateTests {}

extension AppGlobalStateTests {
@Suite
struct AppShellViewModelTests {
    @Test
    func hermesAgentRowTitleOnlyClaimsDefaultWithoutSpecificModel() {
        let selectedTitle = agentRowDisplayName(
            definitionID: .hermes,
            hermesModelsState: .loaded,
            selectedModelID: "openai:gpt-5"
        )
        let defaultTitle = agentRowDisplayName(
            definitionID: .hermes,
            hermesModelsState: .loaded,
            selectedModelID: nil
        )

        #expect(!selectedTitle.contains("Default model"))
        #expect(!selectedTitle.contains("기본 모델"))
        #expect(
            defaultTitle.contains("Default model") || defaultTitle.contains("기본 모델")
        )
    }

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
    func newSessionSavesLatestSoulBeforeResettingRuntime() async {
        let store = ControlledSoulStore(loadedProfile: .empty)
        let connector = LifecycleConnector(definitionID: .codex)
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectors: [connector],
            soulStore: store
        )
        let loadTask = Task { @MainActor in await viewModel.loadSoul() }
        await store.waitForLoad()
        await store.resumeLoad()
        await loadTask.value
        viewModel.updateSoulDraft(SoulProfile(name: "Latest"))

        #expect(await viewModel.saveSoulAndResetSession())
        #expect(await store.savedProfiles.map(\.name) == ["Latest"])
        #expect(await connector.resetCount == 1)
    }

    @Test
    @MainActor
    func newSessionWaitsForDraftEditedDuringSaveBeforeResettingRuntime() async {
        let store = ControlledSoulStore(loadedProfile: .empty, suspendsFirstSave: true)
        let connector = LifecycleConnector(definitionID: .codex)
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectors: [connector],
            soulStore: store
        )
        await viewModel.loadSoul()
        viewModel.updateSoulDraft(SoulProfile(name: "Earlier"))
        let resetTask = Task { @MainActor in await viewModel.saveSoulAndResetSession() }
        await store.waitForSave()
        viewModel.updateSoulDraft(SoulProfile(name: "Latest"))
        await store.resumeSave()

        #expect(await resetTask.value)
        #expect(await store.savedProfiles.map(\.name) == ["Earlier", "Latest"])
        #expect(await connector.resetCount == 1)
        #expect(viewModel.soulSaveState == .saved)
    }

    @Test
    @MainActor
    func newSessionPreservesRuntimeWhenSoulSaveFails() async {
        let store = ControlledSoulStore(loadedProfile: .empty, failsSave: true)
        let connector = LifecycleConnector(definitionID: .codex)
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectors: [connector],
            soulStore: store
        )
        let loadTask = Task { @MainActor in await viewModel.loadSoul() }
        await store.waitForLoad()
        await store.resumeLoad()
        await loadTask.value
        viewModel.updateSoulDraft(SoulProfile(name: "Unsaved"))

        #expect(!(await viewModel.saveSoulAndResetSession()))
        #expect(await connector.resetCount == 0)
        #expect(viewModel.soulSaveState == .failed)
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
            agentRegistry: registry,
            codexLoginService: signedInCodexService(for: codex)
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
    func findingAndRemovingAnAgentUpdatesTheDefaultSelection() async {
        let hermes = AgentInstallation(
            definitionID: .hermes,
            path: "/safe/hermes",
            version: "Hermes 1.0",
            runtimeContract: .hermesACP,
            availability: .available
        )
        let connector = LifecycleConnector(definitionID: .hermes)
        let registry = AgentRegistry(
            discovery: StaticAgentDiscovery(installations: [hermes]),
            persistence: EmptyAgentSelectionPersistence(),
            visibilityPersistence: EmptyAgentVisibilityPersistence()
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: registry,
            connectors: [connector]
        )

        await viewModel.findAndRegisterAgent(.hermes)

        #expect(viewModel.agentSnapshot.selectedInstallation == hermes)
        #expect(viewModel.agentSnapshot.isExplicitPath(hermes))

        await viewModel.removeAgentInstallation(hermes)

        #expect(viewModel.agentSnapshot.selection == .unselected)
        #expect(viewModel.agentSnapshot.installations.isEmpty)
        #expect(await connector.resetCount == 2)
    }

    @Test
    @MainActor
    func refreshHermesModelsTracksLoadingAndKeepsPreviousModelsOnEmptyRefetch() async {
        let hermes = appShellHermesInstallation()
        let transport = HermesModelCatalogTransport(
            responses: [.success([])],
            waitsForFirstRequest: true
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: AgentRegistry(
                discovery: StaticAgentDiscovery(installations: [hermes]),
                persistence: EmptyAgentSelectionPersistence()
            ),
            connectors: [ACPConnector(definitionID: .hermes, transport: transport)]
        )
        await viewModel.refreshAgents(trigger: .appStart)

        let refreshTask = Task { @MainActor in
            await viewModel.refreshHermesModels()
        }
        await transport.waitForModelRequest()
        #expect(viewModel.hermesModelsState == .loading)
        let models = [HermesModel(id: "anthropic:claude", name: "Claude")]
        await transport.completeFirstRequest(.success(models))
        await refreshTask.value

        #expect(viewModel.hermesModelsState == .loaded)
        #expect(viewModel.hermesModels == models)

        await viewModel.refreshHermesModels()
        #expect(viewModel.hermesModelsState == .loaded)
        #expect(viewModel.hermesModels == models)

        await transport.setNextResult(.failure(.unavailable))
        await viewModel.refreshHermesModels()
        guard case .failed = viewModel.hermesModelsState else {
            Issue.record("Expected Hermes model refresh to fail")
            return
        }
    }

    @Test
    @MainActor
    func refreshHermesModelsDoesNothingWithoutAvailableHermes() async {
        let codex = AgentInstallation(
            definitionID: .codex,
            path: "/safe/codex",
            version: "1.0.0",
            runtimeContract: .codexExec,
            availability: .available
        )
        let transport = HermesModelCatalogTransport(responses: [])
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: AgentRegistry(
                discovery: StaticAgentDiscovery(installations: [codex]),
                persistence: EmptyAgentSelectionPersistence()
            ),
            connectors: [ACPConnector(definitionID: .hermes, transport: transport)]
        )
        await viewModel.refreshAgents(trigger: .appStart)
        await viewModel.refreshHermesModels()

        #expect(await transport.modelRequestCount == 0)
        #expect(viewModel.hermesModelsState == .idle)
    }

    @Test
    @MainActor
    func refreshHermesModelsTargetsHermesWhenAnotherACPConnectorComesFirst() async {
        let hermes = appShellHermesInstallation()
        let geminiTransport = HermesModelCatalogTransport(responses: [])
        let hermesTransport = HermesModelCatalogTransport(responses: [])
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: AgentRegistry(
                discovery: StaticAgentDiscovery(installations: [hermes]),
                persistence: EmptyAgentSelectionPersistence()
            ),
            connectors: [
                ACPConnector(definitionID: .gemini, transport: geminiTransport),
                ACPConnector(definitionID: .hermes, transport: hermesTransport),
            ]
        )
        await viewModel.refreshAgents(trigger: .appStart)
        await viewModel.refreshHermesModels()

        #expect(await geminiTransport.modelRequestCount == 0)
        #expect(await hermesTransport.modelRequestCount == 1)
    }

    @Test
    @MainActor
    func refreshHermesModelsUsesTheSelectedHermesExecutablePath() async throws {
        let first = appShellHermesInstallation(path: "/safe/hermes-first")
        let second = appShellHermesInstallation(path: "/safe/hermes-second")
        let firstModels = [HermesModel(id: "first:model", name: "First")]
        let secondModels = [HermesModel(id: "second:model", name: "Second")]
        let transport = HermesModelCatalogTransport(
            responses: [.success(firstModels), .success(secondModels)]
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: AgentRegistry(
                discovery: StaticAgentDiscovery(installations: [first, second]),
                persistence: EmptyAgentSelectionPersistence()
            ),
            connectors: [ACPConnector(definitionID: .hermes, transport: transport)]
        )

        await viewModel.refreshAgents(trigger: .appStart)
        await viewModel.refreshHermesModels()
        #expect(viewModel.hermesModels == firstModels)
        #expect(viewModel.effectiveHermesInstallation?.path == first.path)

        try await viewModel.selectAgent(.hermes, path: second.path!)

        #expect(viewModel.hermesModels == secondModels)
        #expect(viewModel.effectiveHermesInstallation?.path == second.path)
        try await viewModel.selectAgent(
            .hermes,
            path: second.path!,
            modelID: secondModels[0].id
        )
        #expect(viewModel.agentSnapshot.selectedInstallation?.path == second.path)
        #expect(await transport.modelRequestPaths == [first.path!, second.path!])
    }

    @Test
    @MainActor
    func refreshHermesModelsRetriesAfterAnInFlightRequestSkip() async {
        let hermes = appShellHermesInstallation()
        let models = [HermesModel(id: "anthropic:claude", name: "Claude")]
        let transport = BusyThenModelsTransport(models: models)
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: AgentRegistry(
                discovery: StaticAgentDiscovery(installations: [hermes]),
                persistence: EmptyAgentSelectionPersistence()
            ),
            connectors: [ACPConnector(definitionID: .hermes, transport: transport)]
        )

        await viewModel.refreshAgents(trigger: .appStart)
        await viewModel.refreshHermesModels()

        #expect(viewModel.hermesModelsState == .idle)
        #expect(viewModel.hermesModels.isEmpty)

        await viewModel.refreshHermesModels()

        #expect(viewModel.hermesModelsState == .loaded)
        #expect(viewModel.hermesModels == models)
    }

    @Test
    @MainActor
    func selectingAnotherHermesModelResetsTheExistingSession() async throws {
        let hermes = appShellHermesInstallation()
        let transport = HermesModelCatalogTransport(responses: [])
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: AgentRegistry(
                discovery: StaticAgentDiscovery(installations: [hermes]),
                persistence: EmptyAgentSelectionPersistence()
            ),
            connectors: [ACPConnector(definitionID: .hermes, transport: transport)]
        )
        await viewModel.refreshAgents(trigger: .appStart)

        try await viewModel.selectAgent(.hermes, path: hermes.path!)
        try await viewModel.selectAgent(
            .hermes,
            path: hermes.path!,
            modelID: "openai:gpt-5"
        )

        #expect(await transport.closeCount == 2)
    }

    @Test
    @MainActor
    func registeringOneRemovedAgentKeepsOtherRemovedAgentsRestorable() async {
        let hermes = AgentInstallation(
            definitionID: .hermes,
            path: "/safe/hermes",
            version: "Hermes 1.0",
            runtimeContract: .hermesACP,
            availability: .available
        )
        let codex = AgentInstallation(
            definitionID: .codex,
            path: "/safe/codex",
            version: "codex-cli 0.144.6",
            runtimeContract: .codexExec,
            availability: .available
        )
        let registry = AgentRegistry(
            discovery: StaticAgentDiscovery(installations: [hermes, codex]),
            persistence: EmptyAgentSelectionPersistence(),
            visibilityPersistence: EmptyAgentVisibilityPersistence()
        )
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            agentRegistry: registry,
            connectors: [LifecycleConnector(definitionID: .hermes)]
        )

        await viewModel.removeAgentInstallation(hermes)
        await viewModel.removeAgentInstallation(codex)
        await viewModel.findAndRegisterAgent(.hermes)

        #expect(viewModel.agentSnapshot.selectedInstallation == hermes)
        #expect(viewModel.agentSnapshot.hiddenDefinitionIDs == [.codex])
    }

    @Test
    @MainActor
    func selectionChangesResetConnectorsAndShutdownClosesThem() async throws {
        let previousLanguage = AppText.language
        defer { AppText.setLanguage(previousLanguage) }
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
            connectors: [codexConnector, claudeConnector],
            codexLoginService: signedInCodexService(for: codex)
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
        HermesConnectionError.pathMustBeAbsolute("bin/hermes"),
        HermesConnectionError.executableUnavailable("/missing/hermes"),
        HermesConnectionError.executionFailed(
            exitStatus: 23,
            standardError: "permission denied\n"
        ),
        HermesConnectionError.emptyVersionOutput,
    ])
    @MainActor
    func mapsPathAndExecutionErrorsToDistinctStates(error: HermesConnectionError) async {
        let previousLanguage = AppText.language
        AppText.setLanguage(.korean)
        defer { AppText.setLanguage(previousLanguage) }
        let expectedState: HermesConnectionState
        switch error {
        case .pathMustBeAbsolute, .executableUnavailable:
            expectedState = .pathError(message: error.errorDescription!)
        case .executionFailed, .emptyVersionOutput:
            expectedState = .executionError(message: error.errorDescription!)
        case .timedOut, .launchFailed:
            Issue.record("Unexpected test argument: \(error)")
            return
        }
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
        let previousLanguage = AppText.language
        AppText.setLanguage(.korean)
        defer { AppText.setLanguage(previousLanguage) }
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
}

private func signedInCodexService(for installation: AgentInstallation) -> CodexLoginService {
    CodexLoginService(
        verifier: AppShellCodexVerifier(installation: installation),
        processRunner: AppShellSignedInCodexRunner()
    )
}

private actor AppShellCodexVerifier: AgentInstallationVerifying {
    let installation: AgentInstallation

    init(installation: AgentInstallation) { self.installation = installation }

    func verify(_ definitionID: AgentDefinitionID, at executableURL: URL) -> AgentInstallation {
        installation
    }
}

private actor AppShellSignedInCodexRunner: ProcessRunning {
    func run(_ command: ProcessCommand, timeout: Duration?) -> ProcessRunResult {
        ProcessRunResult(
            standardOutput: Data(),
            standardError: Data(),
            termination: .exited(status: 0)
        )
    }
}

private actor ControlledSoulStore: SoulProfileStoring {
    let loadedProfile: SoulProfile
    let suspendsFirstSave: Bool
    let failsSave: Bool
    private(set) var savedProfiles: [SoulProfile] = []
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var loadStarted = false
    private var saveStarted = false

    init(
        loadedProfile: SoulProfile,
        suspendsFirstSave: Bool = false,
        failsSave: Bool = false
    ) {
        self.loadedProfile = loadedProfile
        self.suspendsFirstSave = suspendsFirstSave
        self.failsSave = failsSave
    }

    func load() async -> SoulProfile {
        guard !suspendsFirstSave else { return loadedProfile }
        loadStarted = true
        await withCheckedContinuation { loadContinuation = $0 }
        return loadedProfile
    }

    func save(_ profile: SoulProfile) async throws {
        if failsSave { throw ControlledSoulStoreError.saveFailed }
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

private enum ControlledSoulStoreError: Error {
    case saveFailed
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

private actor EmptyAgentVisibilityPersistence: AgentVisibilityPersisting {
    func loadHiddenInstallationIDs() -> Set<String> { [] }
    func saveHiddenInstallationIDs(_ identifiers: Set<String>) {}
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

private func appShellHermesInstallation(path: String = "/safe/hermes") -> AgentInstallation {
    AgentInstallation(
        definitionID: .hermes,
        path: path,
        version: "Hermes 1.0",
        runtimeContract: .hermesACP,
        availability: .available
    )
}

private enum HermesModelCatalogError: Error {
    case unavailable
}

private actor HermesModelCatalogTransport: ACPTransporting {
    private var responses: [Result<[HermesModel], HermesModelCatalogError>]
    private var waitsForFirstRequest: Bool
    private var firstRequestContinuation: CheckedContinuation<[HermesModel], any Error>?
    private(set) var modelRequestCount = 0
    private(set) var modelRequestPaths: [String] = []
    private(set) var closeCount = 0

    init(
        responses: [Result<[HermesModel], HermesModelCatalogError>],
        waitsForFirstRequest: Bool = false
    ) {
        self.responses = responses
        self.waitsForFirstRequest = waitsForFirstRequest
    }

    func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse {
        PromptResponse(text: "unused")
    }

    func models(
        executableURL: URL,
        environment: [String: String],
        outputByteLimit: Int,
        modelID: String?,
        force: Bool
    ) async throws -> [HermesModel] {
        modelRequestCount += 1
        modelRequestPaths.append(executableURL.standardizedFileURL.path)
        if waitsForFirstRequest {
            waitsForFirstRequest = false
            return try await withCheckedThrowingContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        guard !responses.isEmpty else { return [] }
        return try responses.removeFirst().get()
    }

    func waitForModelRequest() async {
        while modelRequestCount == 0 {
            await Task.yield()
        }
    }

    func completeFirstRequest(_ result: Result<[HermesModel], HermesModelCatalogError>) {
        guard let continuation = firstRequestContinuation else { return }
        firstRequestContinuation = nil
        switch result {
        case let .success(models):
            continuation.resume(returning: models)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    func setNextResult(_ result: Result<[HermesModel], HermesModelCatalogError>) {
        responses.append(result)
    }

    func close() {
        closeCount += 1
    }
}

private actor BusyThenModelsTransport: ACPTransporting {
    private let models: [HermesModel]
    private var didSkip = false

    init(models: [HermesModel]) {
        self.models = models
    }

    func send(
        _ request: PromptRequest,
        executableURL: URL,
        environment: [String: String],
        timeout: Duration,
        outputByteLimit: Int
    ) async throws -> PromptResponse {
        PromptResponse(text: "unused")
    }

    func models(
        executableURL: URL,
        environment: [String: String],
        outputByteLimit: Int,
        modelID: String?,
        force: Bool
    ) async throws -> [HermesModel] {
        if !didSkip {
            didSkip = true
            throw ACPProtocolError.requestInFlight
        }
        return models
    }

    func close() {}
}
