import Combine
import Foundation

public enum HermesPathStatus: Equatable, Sendable {
    case empty
    case invalidAbsolutePath
    case absolutePathReady
}

public enum HermesConnectionState: Equatable, Sendable {
    case idle
    case loading
    case success(version: String)
    case pathError(message: String)
    case executionError(message: String)
    case timedOut
}

public enum FixtureProbeState: Equatable, Sendable {
    case idle
    case loading
    case success(version: String)
    case failure(message: String)
}

public enum SoulSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case savedWithNormalization
    case failed
}

public enum HermesModelsState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(message: String)
}

public struct CodexLoginApprovalRequest: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case login
        case logout
        case changeAccount
    }

    fileprivate let id: UUID
    fileprivate let installationID: String
    public let operation: Operation
}

@MainActor
public final class YumYumAppViewModel: ObservableObject {
    @Published public private(set) var connectionState: HermesConnectionState = .idle
    @Published public var hermesPath = "" {
        didSet {
            if hermesPath != oldValue, connectionState != .loading {
                connectionState = .idle
            }
        }
    }
    @Published public private(set) var probeState: FixtureProbeState = .idle
    @Published public private(set) var agentSnapshot = AgentRegistrySnapshot(
        installations: [],
        selection: .unselected
    )
    @Published public private(set) var isDiscoveringAgents = false
    @Published public private(set) var codexLoginState = CodexLoginState.unavailable
    @Published public var soulProfile = SoulProfile.empty
    @Published public private(set) var soulSaveState = SoulSaveState.idle
    @Published public private(set) var isSoulLoaded = false
    @Published public private(set) var hermesModels: [HermesModel] = []
    @Published public private(set) var hermesModelsState: HermesModelsState = .idle

    public let fixturePath: String
    public let agentRegistry: AgentRegistry
    public let agentRuntime: AgentRuntime
    public let soulStore: any SoulProfileStoring

    private let fixtureProbe: any FixtureProbing
    private let connectionChecker: any HermesConnectionChecking
    private let codexLoginService: CodexLoginService
    private let hermesConnector: ACPConnector?
    private var hermesModelsSourcePath: String?
    private var codexLoginTask: Task<Void, Never>?
    private var codexStatusTask: Task<Bool, Error>?
    private var pendingCodexLoginApproval: CodexLoginApprovalRequest?
    private var soulRevision = 0
    private var savedSoulRevision = 0
    private var soulPersistenceTask: Task<Void, Never>?

    public init(
        fixtureProbe: any FixtureProbing,
        connectionChecker: any HermesConnectionChecking = HermesConnectionService(),
        agentRegistry: AgentRegistry = AgentRegistry(),
        connectors: [any AgentConnecting]? = nil,
        soulStore: any SoulProfileStoring = SoulProfileStore(),
        codexLoginService: CodexLoginService = CodexLoginService()
    ) {
        self.fixtureProbe = fixtureProbe
        self.connectionChecker = connectionChecker
        self.agentRegistry = agentRegistry
        self.soulStore = soulStore
        self.codexLoginService = codexLoginService
        let runtimeConnectors = connectors ?? [
            ACPConnector(
                definitionID: .hermes,
                transport: ACPProcessTransport(arguments: ["acp"])
            ),
            // TODO(verify-before-ship): Re-verify ["--acp"] against the installed Gemini CLI version; it is doc-verified but not hands-on confirmed.
            ACPConnector(
                definitionID: .gemini,
                transport: ACPProcessTransport(arguments: ["--acp"])
            ),
            OpenCodeConnector(),
            CodexConnector(),
            ClaudeCodeConnector(),
        ]
        hermesConnector = runtimeConnectors.first(where: {
            $0.definitionID == .hermes
        }) as? ACPConnector
        agentRuntime = AgentRuntime(
            selection: agentRegistry,
            connectors: runtimeConnectors,
            soulStore: soulStore,
            codexLoginService: codexLoginService
        )
        fixturePath = fixtureProbe.fixturePath
    }

    public func loadSoul() async {
        let revision = soulRevision
        let loadedProfile = await soulStore.load()
        isSoulLoaded = true
        guard revision == soulRevision else { return }
        soulProfile = loadedProfile
        soulSaveState = .idle
    }

    public func updateSoulDraft(_ profile: SoulProfile) {
        soulRevision += 1
        soulProfile = profile
    }

    public func saveSoul(_ profile: SoulProfile) async {
        if soulProfile != profile {
            updateSoulDraft(profile)
        }
        await saveSoul()
    }

    public func saveSoul() async {
        let revision = soulRevision
        let draft = soulProfile
        let normalized = draft.normalized
        soulSaveState = .saving
        let previousTask = soulPersistenceTask
        let store = soulStore
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                try await store.save(normalized)
                guard let self, revision == self.soulRevision else { return }
                self.savedSoulRevision = revision
                self.soulSaveState = draft == normalized ? .saved : .savedWithNormalization
            } catch {
                guard let self, revision == self.soulRevision else { return }
                self.soulSaveState = .failed
            }
        }
        soulPersistenceTask = task
        await task.value
    }

    public func resetSoul() async {
        if soulProfile != .empty {
            updateSoulDraft(.empty)
        }
        await saveSoul()
    }

    public func flushSoul() async {
        guard isSoulLoaded, savedSoulRevision != soulRevision else { return }
        await saveSoul()
    }

    public func saveSoulAndResetSession() async -> Bool {
        while savedSoulRevision != soulRevision {
            await saveSoul()
            guard soulSaveState != .failed else { return false }
        }
        await agentRuntime.reset()
        return true
    }

    public var canSendPrompt: Bool {
        guard agentSnapshot.selectedInstallation?.definitionID == .codex else {
            return agentSnapshot.canSend
        }
        return agentSnapshot.canSend && codexLoginState == .signedIn
    }

    public func refreshAgents(trigger: AgentRefreshTrigger) async {
        isDiscoveringAgents = true
        agentSnapshot = await agentRegistry.refresh(trigger: trigger)
        isDiscoveringAgents = false
        await refreshCodexLoginStatus()
    }

    public func selectAgent(
        _ definitionID: AgentDefinitionID,
        path: String,
        modelID: String? = nil
    ) async throws {
        if definitionID == .codex {
            guard let installation = availableCodexInstallations.first(where: { $0.path == path }),
                  try await codexLoginService.status(for: installation) else {
                codexLoginState = .loginRequired
                throw AgentRuntimeError.codexAuthenticationRequired
            }
            codexLoginState = .signedIn
        }
        let snapshot = try await agentRegistry.select(
            definitionID,
            path: path,
            modelID: modelID
        )
        if snapshot.selection != agentSnapshot.selection
            || snapshot.selectedModelID != agentSnapshot.selectedModelID {
            await agentRuntime.reset()
        }
        agentSnapshot = snapshot
        if definitionID == .hermes,
           let selectedPath = snapshot.selectedInstallation?.path,
           hermesModelsSourcePath != selectedPath {
            hermesModels.removeAll()
            hermesModelsSourcePath = nil
            hermesModelsState = .idle
            await refreshHermesModels()
        }
    }

    public func refreshHermesModels(force: Bool = false) async {
        guard hermesModelsState != .loading,
              let installation = effectiveHermesInstallation,
              let path = installation.path,
              let hermesConnector else {
            return
        }

        let sourcePath = URL(fileURLWithPath: path).standardizedFileURL.path
        if hermesModelsSourcePath != sourcePath {
            hermesModels.removeAll()
            hermesModelsState = .idle
        }
        hermesModelsState = .loading
        do {
            let models = try await hermesConnector.models(
                executableURL: URL(fileURLWithPath: sourcePath),
                modelID: agentSnapshot.selectedModelID,
                force: force
            )
            try Task.checkCancellation()
            guard effectiveHermesInstallation?.path == sourcePath else {
                hermesModels.removeAll()
                hermesModelsSourcePath = nil
                hermesModelsState = .idle
                await refreshHermesModels()
                return
            }
            if !models.isEmpty || hermesModels.isEmpty {
                hermesModels = models
            }
            hermesModelsSourcePath = sourcePath
            hermesModelsState = .loaded
        } catch is CancellationError {
            hermesModelsState = hermesModels.isEmpty ? .idle : .loaded
        } catch ACPProtocolError.requestInFlight {
            hermesModelsState = .idle
        } catch {
            hermesModelsState = .failed(
                message: UserFacingErrorRedactor.message(for: error)
            )
        }
    }

    public var effectiveHermesInstallation: AgentInstallation? {
        if let selected = agentSnapshot.selectedInstallation,
           selected.definitionID == .hermes,
           selected.availability == .available {
            return selected
        }
        return agentSnapshot.installations.first {
            $0.definitionID == .hermes && $0.availability == .available
        }
    }

    public func shutdown() async {
        codexStatusTask?.cancel()
        _ = try? await codexStatusTask?.value
        codexLoginTask?.cancel()
        await codexLoginTask?.value
        pendingCodexLoginApproval = nil
        await flushSoul()
        await agentRuntime.close()
    }

    public func refreshCodexLoginStatus(for clickedInstallation: AgentInstallation? = nil) async {
        guard codexLoginTask == nil,
              codexStatusTask == nil,
              let installation = clickedInstallation ?? availableCodexInstallation,
              availableCodexInstallations.contains(where: { $0.id == installation.id }) else {
            if codexLoginTask == nil, codexStatusTask == nil {
                codexLoginState = .unavailable
            }
            return
        }
        codexLoginState = .checking
        let service = codexLoginService
        let task = Task { try await service.status(for: installation) }
        codexStatusTask = task
        do {
            codexLoginState = try await withTaskCancellationHandler {
                try await task.value ? .signedIn : .loginRequired
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            codexLoginState = .cancelled
        } catch CodexLoginError.timedOut {
            codexLoginState = .timedOut
        } catch CodexLoginError.unavailable {
            codexLoginState = .unavailable
        } catch {
            codexLoginState = .failed
        }
        codexStatusTask = nil
    }

    public func requestCodexLoginApproval(
        for installation: AgentInstallation,
        operation: CodexLoginApprovalRequest.Operation = .login
    ) -> CodexLoginApprovalRequest? {
        guard codexLoginTask == nil,
              codexStatusTask == nil,
              availableCodexInstallations.contains(where: { $0.id == installation.id }) else { return nil }
        let request = CodexLoginApprovalRequest(
            id: UUID(),
            installationID: installation.id,
            operation: operation
        )
        pendingCodexLoginApproval = request
        return request
    }

    public func cancelCodexLoginApproval(_ request: CodexLoginApprovalRequest) {
        if pendingCodexLoginApproval == request {
            pendingCodexLoginApproval = nil
        }
    }

    public func confirmCodexLogin(_ request: CodexLoginApprovalRequest) async {
        guard pendingCodexLoginApproval == request else { return }
        pendingCodexLoginApproval = nil
        guard let installation = availableCodexInstallations.first(where: {
            $0.id == request.installationID
        }) else { return }
        await performCodexOperation(request.operation, using: installation)
    }

    private func performCodexOperation(
        _ operation: CodexLoginApprovalRequest.Operation,
        using installation: AgentInstallation
    ) async {
        guard codexLoginTask == nil,
              codexStatusTask == nil else { return }
        switch operation {
        case .login: codexLoginState = .awaitingBrowserSignIn
        case .logout: codexLoginState = .loggingOut
        case .changeAccount: codexLoginState = .changingAccount
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch operation {
                case .login:
                    try await codexLoginService.login(using: installation)
                    codexLoginState = .signedIn
                case .logout:
                    try await codexLoginService.logout(using: installation)
                    codexLoginState = .loggedOut
                case .changeAccount:
                    try await codexLoginService.changeAccount(using: installation)
                    codexLoginState = .signedIn
                }
            } catch is CancellationError {
                codexLoginState = .cancelled
            } catch CodexLoginError.timedOut {
                codexLoginState = .timedOut
            } catch CodexLoginError.unavailable {
                codexLoginState = .unavailable
            } catch {
                codexLoginState = operation == .changeAccount ? .changeFailedNeedsLogin : .failed
            }
        }
        codexLoginTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        codexLoginTask = nil
    }

    public func cancelCodexLogin() {
        codexLoginTask?.cancel()
    }

    public var availableCodexInstallation: AgentInstallation? {
        availableCodexInstallations.first
    }

    private var availableCodexInstallations: [AgentInstallation] {
        agentSnapshot.installations.filter {
            $0.definitionID == .codex && $0.availability == .available
        }
    }

    public func findAndRegisterAgent(_ definitionID: AgentDefinitionID) async {
        isDiscoveringAgents = true
        agentSnapshot = await agentRegistry.restoreInstallations(for: definitionID)
        guard let installation = agentSnapshot.installations.first(where: {
            $0.definitionID == definitionID && $0.availability == .available
        }), let path = installation.path else {
            isDiscoveringAgents = false
            await refreshCodexLoginStatus()
            return
        }
        try? await selectAgent(definitionID, path: path)
        isDiscoveringAgents = false
        await refreshCodexLoginStatus()
    }

    public func addExplicitAgentPath(
        _ path: String,
        for definitionID: AgentDefinitionID
    ) async {
        await agentRegistry.addExplicitPath(path, for: definitionID)
        agentSnapshot = await agentRegistry.refresh(trigger: .manualRescan)
        if let installation = agentSnapshot.installations.first(where: {
            $0.definitionID == definitionID
                && $0.path == URL(fileURLWithPath: path).standardizedFileURL.path
                && $0.availability == .available
        }) {
            try? await selectAgent(definitionID, path: installation.path ?? path)
        }
        await refreshCodexLoginStatus()
    }

    public func removeExplicitAgentPath(
        for definitionID: AgentDefinitionID
    ) async {
        let previousSelection = agentSnapshot.selection
        agentSnapshot = await agentRegistry.removeExplicitPath(for: definitionID)
        if agentSnapshot.selection != previousSelection {
            await agentRuntime.reset()
        }
        await refreshCodexLoginStatus()
    }

    public func removeAgentInstallation(_ installation: AgentInstallation) async {
        let previousSelection = agentSnapshot.selection
        agentSnapshot = await agentRegistry.removeInstallation(installation)
        if agentSnapshot.selection != previousSelection {
            await agentRuntime.reset()
        }
        await refreshCodexLoginStatus()
    }

    public var hermesPathStatus: HermesPathStatus {
        let path = hermesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .empty
        }
        guard NSString(string: path).isAbsolutePath else {
            return .invalidAbsolutePath
        }
        return .absolutePathReady
    }

    public var canCheckHermesConnection: Bool {
        hermesPathStatus == .absolutePathReady && connectionState != .loading
    }

    public func checkHermesConnection() async {
        guard canCheckHermesConnection else {
            return
        }

        let executablePath = hermesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionState = .loading
        do {
            let version = try await connectionChecker.check(executablePath: executablePath)
            try Task.checkCancellation()
            connectionState = .success(version: version)
        } catch is CancellationError {
            connectionState = .idle
        } catch let error as HermesConnectionError {
            switch error {
            case .pathMustBeAbsolute, .executableUnavailable:
                connectionState = .pathError(
                    message: error.errorDescription ?? AppText.localized("Hermes 경로를 확인할 수 없습니다.")
                )
            case .timedOut:
                connectionState = .timedOut
            case .executionFailed, .emptyVersionOutput, .launchFailed:
                connectionState = .executionError(
                    message: error.errorDescription ?? AppText.localized("Hermes 연결 확인을 완료하지 못했습니다.")
                )
            }
        } catch {
            connectionState = .executionError(
                message: AppText.localized("Hermes 연결 확인을 완료하지 못했습니다.")
            )
        }
    }

    public func runFixtureProbe() async {
        guard probeState != .loading else {
            return
        }

        probeState = .loading
        do {
            probeState = .success(version: try await fixtureProbe.probe())
        } catch is CancellationError {
            probeState = .idle
        } catch let error as FixtureProbeError {
            probeState = .failure(
                message: error.errorDescription ?? AppText.localized("안전한 fixture probe를 완료하지 못했습니다.")
            )
        } catch {
            probeState = .failure(message: AppText.localized("안전한 fixture probe를 완료하지 못했습니다."))
        }
    }
}
