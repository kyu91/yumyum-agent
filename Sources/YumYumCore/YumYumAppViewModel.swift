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
    @Published public var soulProfile = SoulProfile.empty
    @Published public private(set) var soulSaveState = SoulSaveState.idle
    @Published public private(set) var isSoulLoaded = false

    public let fixturePath: String
    public let agentRegistry: AgentRegistry
    public let agentRuntime: AgentRuntime
    public let soulStore: any SoulProfileStoring

    private let fixtureProbe: any FixtureProbing
    private let connectionChecker: any HermesConnectionChecking
    private var soulRevision = 0
    private var savedSoulRevision = 0
    private var soulPersistenceTask: Task<Void, Never>?

    public init(
        fixtureProbe: any FixtureProbing,
        connectionChecker: any HermesConnectionChecking = HermesConnectionService(),
        agentRegistry: AgentRegistry = AgentRegistry(),
        connectors: [any AgentConnecting]? = nil,
        soulStore: any SoulProfileStoring = SoulProfileStore()
    ) {
        self.fixtureProbe = fixtureProbe
        self.connectionChecker = connectionChecker
        self.agentRegistry = agentRegistry
        self.soulStore = soulStore
        let runtimeConnectors = connectors ?? [
            HermesACPConnector(transport: ACPProcessTransport()),
            OpenCodeConnector(),
            CodexConnector(),
            ClaudeCodeConnector(),
        ]
        agentRuntime = AgentRuntime(
            selection: agentRegistry,
            connectors: runtimeConnectors,
            soulStore: soulStore
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
        let task = Task { @MainActor [weak self] in
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

    public var canSendPrompt: Bool {
        agentSnapshot.canSend
    }

    public func refreshAgents(trigger: AgentRefreshTrigger) async {
        isDiscoveringAgents = true
        agentSnapshot = await agentRegistry.refresh(trigger: trigger)
        isDiscoveringAgents = false
    }

    public func selectAgent(
        _ definitionID: AgentDefinitionID,
        path: String
    ) async throws {
        let snapshot = try await agentRegistry.select(definitionID, path: path)
        if snapshot.selection != agentSnapshot.selection {
            await agentRuntime.reset()
        }
        agentSnapshot = snapshot
    }

    public func shutdown() async {
        await flushSoul()
        await agentRuntime.close()
    }

    public func addExplicitAgentPath(
        _ path: String,
        for definitionID: AgentDefinitionID
    ) async {
        await agentRegistry.addExplicitPath(path, for: definitionID)
        await refreshAgents(trigger: .manualRescan)
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
                    message: error.errorDescription ?? "Hermes 경로를 확인할 수 없습니다."
                )
            case .timedOut:
                connectionState = .timedOut
            case .executionFailed, .emptyVersionOutput, .launchFailed:
                connectionState = .executionError(
                    message: error.errorDescription ?? "Hermes 연결 확인을 완료하지 못했습니다."
                )
            }
        } catch {
            connectionState = .executionError(
                message: "Hermes 연결 확인을 완료하지 못했습니다."
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
                message: error.errorDescription ?? "안전한 fixture probe를 완료하지 못했습니다."
            )
        } catch {
            probeState = .failure(message: "안전한 fixture probe를 완료하지 못했습니다.")
        }
    }
}
