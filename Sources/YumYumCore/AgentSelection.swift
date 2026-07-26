import Foundation

public struct SelectedAgentReference: Codable, Equatable, Sendable {
    public let definitionID: AgentDefinitionID
    public let path: String

    public init(definitionID: AgentDefinitionID, path: String) {
        self.definitionID = definitionID
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public protocol AgentSelectionPersisting: Sendable {
    func load() async -> SelectedAgentReference?
    func save(_ reference: SelectedAgentReference?) async
}

public actor UserDefaultsAgentSelectionStore: AgentSelectionPersisting {
    private let defaults: UserDefaults
    private let definitionKey: String
    private let pathKey: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "YumYum.SelectedAgent"
    ) {
        self.defaults = defaults
        definitionKey = "\(keyPrefix).definitionID"
        pathKey = "\(keyPrefix).path"
    }

    public func load() -> SelectedAgentReference? {
        guard let rawDefinition = defaults.string(forKey: definitionKey),
              let definitionID = AgentDefinitionID(rawValue: rawDefinition),
              let path = defaults.string(forKey: pathKey) else {
            return nil
        }
        return SelectedAgentReference(definitionID: definitionID, path: path)
    }

    public func save(_ reference: SelectedAgentReference?) {
        guard let reference else {
            defaults.removeObject(forKey: definitionKey)
            defaults.removeObject(forKey: pathKey)
            return
        }
        defaults.set(reference.definitionID.rawValue, forKey: definitionKey)
        defaults.set(reference.path, forKey: pathKey)
    }
}

public enum AgentRefreshTrigger: Equatable, Sendable {
    case appStart
    case manualRescan
    case quickMenuOpened
    case beforeSend
}

public enum AgentSelectionState: Equatable, Sendable {
    case unselected
    case selected(AgentInstallation)
    case unavailable(reference: SelectedAgentReference, reason: String)
}

public struct AgentRegistrySnapshot: Equatable, Sendable {
    public let installations: [AgentInstallation]
    public let selection: AgentSelectionState

    public var selectedInstallation: AgentInstallation? {
        guard case let .selected(installation) = selection else {
            return nil
        }
        return installation
    }

    public var canSend: Bool {
        selectedInstallation != nil
    }

    public var requiresExplicitReselection: Bool {
        if case .unavailable = selection {
            return true
        }
        return false
    }

    public init(
        installations: [AgentInstallation],
        selection: AgentSelectionState
    ) {
        self.installations = installations
        self.selection = selection
    }
}

public enum AgentSelectionError: Error, Equatable, LocalizedError, Sendable {
    case noSelection
    case unavailable(definitionID: AgentDefinitionID, path: String)
    case explicitReselectionRequired

    public var errorDescription: String? {
        switch self {
        case .noSelection:
            "기본 에이전트를 먼저 선택하세요."
        case let .unavailable(definitionID, path):
            "실행 가능한 \(definitionID.displayName)을 확인할 수 없습니다: \(path)"
        case .explicitReselectionRequired:
            "선택한 에이전트를 사용할 수 없어 명시적으로 다시 선택해야 합니다."
        }
    }
}

public protocol AgentSelectionValidating: Sendable {
    func validatedSelection() async throws -> AgentInstallation
}

public actor AgentRegistry: AgentSelectionValidating {
    private let discovery: any AgentDiscovering
    private let persistence: any AgentSelectionPersisting
    private var installations: [AgentInstallation] = []
    private var selectedReference: SelectedAgentReference?
    private var explicitPaths: [AgentDefinitionID: String] = [:]
    private var didLoadSelection = false
    private var selectionWasInvalidated = false

    public init(
        discovery: any AgentDiscovering = AgentDiscovery(),
        persistence: any AgentSelectionPersisting = UserDefaultsAgentSelectionStore()
    ) {
        self.discovery = discovery
        self.persistence = persistence
    }

    @discardableResult
    public func refresh(trigger: AgentRefreshTrigger) async -> AgentRegistrySnapshot {
        await loadSelectionIfNeeded()
        installations = await discovery.scan(explicitPaths: explicitPaths)

        guard let selectedReference else {
            return snapshot(selection: .unselected)
        }
        guard !selectionWasInvalidated else {
            return snapshot(
                selection: .unavailable(
                    reference: selectedReference,
                    reason: "이전에 사용할 수 없었던 에이전트는 명시적으로 다시 선택해야 합니다."
                )
            )
        }

        guard let exactMatch = exactInstallation(for: selectedReference),
              exactMatch.availability == .available else {
            selectionWasInvalidated = true
            await persistence.save(nil)
            return snapshot(
                selection: .unavailable(
                    reference: selectedReference,
                    reason: unavailableReason(for: selectedReference)
                )
            )
        }
        return snapshot(selection: .selected(exactMatch))
    }

    @discardableResult
    public func select(
        _ definitionID: AgentDefinitionID,
        path: String
    ) async throws -> AgentRegistrySnapshot {
        let reference = SelectedAgentReference(definitionID: definitionID, path: path)
        guard let installation = exactInstallation(for: reference),
              installation.availability == .available else {
            throw AgentSelectionError.unavailable(
                definitionID: definitionID,
                path: reference.path
            )
        }

        selectedReference = reference
        explicitPaths[definitionID] = reference.path
        selectionWasInvalidated = false
        await persistence.save(reference)
        return snapshot(selection: .selected(installation))
    }

    public func addExplicitPath(
        _ path: String,
        for definitionID: AgentDefinitionID
    ) {
        explicitPaths[definitionID] = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public func validatedSelection() async throws -> AgentInstallation {
        let refreshed = await refresh(trigger: .beforeSend)
        if selectionWasInvalidated {
            throw AgentSelectionError.explicitReselectionRequired
        }
        guard let installation = refreshed.selectedInstallation else {
            throw AgentSelectionError.noSelection
        }
        return installation
    }

    public func currentSnapshot() -> AgentRegistrySnapshot {
        guard let selectedReference else {
            return snapshot(selection: .unselected)
        }
        if selectionWasInvalidated {
            return snapshot(
                selection: .unavailable(
                    reference: selectedReference,
                    reason: "선택한 에이전트를 명시적으로 다시 선택해야 합니다."
                )
            )
        }
        if let installation = exactInstallation(for: selectedReference),
           installation.availability == .available {
            return snapshot(selection: .selected(installation))
        }
        return snapshot(
            selection: .unavailable(
                reference: selectedReference,
                reason: unavailableReason(for: selectedReference)
            )
        )
    }

    private func loadSelectionIfNeeded() async {
        guard !didLoadSelection else {
            return
        }
        didLoadSelection = true
        selectedReference = await persistence.load()
        if let selectedReference {
            explicitPaths[selectedReference.definitionID] = selectedReference.path
        }
    }

    private func exactInstallation(
        for reference: SelectedAgentReference
    ) -> AgentInstallation? {
        installations.first {
            $0.definitionID == reference.definitionID && $0.path == reference.path
        }
    }

    private func unavailableReason(for reference: SelectedAgentReference) -> String {
        guard let match = exactInstallation(for: reference),
              case let .unavailable(reason) = match.availability else {
            return "저장된 정확한 실행 경로를 찾지 못했습니다."
        }
        return reason
    }

    private func snapshot(selection: AgentSelectionState) -> AgentRegistrySnapshot {
        AgentRegistrySnapshot(installations: installations, selection: selection)
    }
}
