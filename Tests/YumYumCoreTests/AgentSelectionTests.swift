import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AgentSelectionTests {
    @Test
    func userDefaultsSelectionRoundTripsModelID() async {
        let keyPrefix = "YumYumTests.SelectedAgent.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "\(keyPrefix).definitionID")
            UserDefaults.standard.removeObject(forKey: "\(keyPrefix).path")
            UserDefaults.standard.removeObject(forKey: "\(keyPrefix).modelID")
        }
        let store = UserDefaultsAgentSelectionStore(
            keyPrefix: keyPrefix
        )
        let reference = SelectedAgentReference(
            definitionID: .hermes,
            path: "/safe/hermes",
            modelID: "anthropic:claude-sonnet"
        )

        await store.save(reference)

        #expect(await store.load() == reference)
    }

    @Test
    func nonHermesSelectionIgnoresModelID() async throws {
        for definitionID in [AgentDefinitionID.codex, .gemini] {
            let installation = available(
                definitionID,
                path: "/safe/\(definitionID.rawValue)"
            )
            let persistence = SelectionPersistence()
            let registry = AgentRegistry(
                discovery: SelectionDiscovery(scans: [[installation]]),
                persistence: persistence
            )

            _ = await registry.refresh(trigger: .appStart)
            let snapshot = try await registry.select(
                definitionID,
                path: installation.path!,
                modelID: "openai:gpt-5"
            )

            #expect(snapshot.selectedModelID == nil)
            #expect(await persistence.storedReference?.modelID == nil)
        }
    }

    @Test
    func selectedModelIDIsExposedAndRemovalClearsModelSelection() async throws {
        let hermes = available(.hermes, path: "/safe/hermes")
        let persistence = SelectionPersistence()
        let registry = AgentRegistry(
            discovery: SelectionDiscovery(scans: [[hermes]]),
            persistence: persistence,
            visibilityPersistence: VisibilityPersistence()
        )

        _ = await registry.refresh(trigger: .appStart)
        let selected = try await registry.select(
            .hermes,
            path: hermes.path!,
            modelID: "openai:gpt-5"
        )
        #expect(selected.selectedModelID == "openai:gpt-5")

        let removed = await registry.removeInstallation(hermes)
        #expect(removed.selection == .unselected)
        #expect(removed.selectedModelID == nil)
        #expect(await persistence.storedReference == nil)
    }

    @Test
    func unavailableSelectionNeverFallsBackAndRequiresExplicitReselection() async throws {
        let selectedPath = "/known/hermes"
        let fallbackPath = "/other/hermes"
        let discovery = SelectionDiscovery(
            scans: [
                [available(.hermes, path: selectedPath)],
                [
                    unavailable(.hermes, path: selectedPath, reason: "missing"),
                    available(.hermes, path: fallbackPath),
                ],
                [
                    available(.hermes, path: selectedPath),
                    available(.hermes, path: fallbackPath),
                ],
            ]
        )
        let persistence = SelectionPersistence()
        let registry = AgentRegistry(discovery: discovery, persistence: persistence)

        _ = await registry.refresh(trigger: .appStart)
        let selected = try await registry.select(.hermes, path: selectedPath)

        #expect(selected.canSend)
        #expect(
            await persistence.storedReference
                == SelectedAgentReference(definitionID: .hermes, path: selectedPath)
        )

        let unavailableSnapshot = await registry.refresh(trigger: .quickMenuOpened)
        #expect(!unavailableSnapshot.canSend)
        #expect(unavailableSnapshot.requiresExplicitReselection)
        #expect(unavailableSnapshot.selectedInstallation == nil)
        #expect(await persistence.storedReference == nil)

        let restoredSnapshot = await registry.refresh(trigger: .manualRescan)
        #expect(!restoredSnapshot.canSend)
        #expect(restoredSnapshot.requiresExplicitReselection)

        do {
            _ = try await registry.validatedSelection()
            Issue.record("Expected sending to remain blocked until explicit reselection")
        } catch {
            #expect(error as? AgentSelectionError == .explicitReselectionRequired)
        }

        let reselected = try await registry.select(.hermes, path: fallbackPath)
        #expect(reselected.canSend)
        #expect(reselected.selectedInstallation?.path == fallbackPath)
    }

    @Test
    func removingAnExplicitSelectedPathClearsSelectionWithoutFallback() async throws {
        let selectedPath = "/custom/hermes"
        let fallbackPath = "/known/hermes"
        let discovery = SelectionDiscovery(
            scans: [
                [
                    available(.hermes, path: selectedPath),
                    available(.hermes, path: fallbackPath),
                ],
                [available(.hermes, path: fallbackPath)],
            ]
        )
        let persistence = SelectionPersistence()
        let registry = AgentRegistry(discovery: discovery, persistence: persistence)

        await registry.addExplicitPath(selectedPath, for: .hermes)
        let discovered = await registry.refresh(trigger: .manualRescan)
        let selected = try await registry.select(.hermes, path: selectedPath)

        #expect(discovered.isExplicitPath(try #require(discovered.installations.first)))
        #expect(selected.selectedInstallation?.path == selectedPath)

        let removed = await registry.removeExplicitPath(for: .hermes)

        #expect(removed.selection == .unselected)
        #expect(removed.explicitPaths.isEmpty)
        #expect(removed.installations.map(\.path) == [fallbackPath])
        #expect(await persistence.storedReference == nil)
    }

    @Test
    func removingAnInstallationHidesItUntilItIsFoundAgain() async throws {
        let path = "/known/codex"
        let codex = available(.codex, path: path)
        let hermes = available(.hermes, path: "/known/hermes")
        let discovery = SelectionDiscovery(scans: [[codex, hermes]])
        let selection = SelectionPersistence()
        let visibility = VisibilityPersistence()
        let registry = AgentRegistry(
            discovery: discovery,
            persistence: selection,
            visibilityPersistence: visibility
        )

        _ = await registry.refresh(trigger: .appStart)
        _ = try await registry.select(.codex, path: path)

        let removed = await registry.removeInstallation(codex)

        #expect(removed.installations == [hermes])
        #expect(removed.selection == .unselected)
        #expect(removed.hiddenDefinitionIDs == [.codex])
        #expect(await selection.storedReference == nil)

        let restoredRegistry = AgentRegistry(
            discovery: discovery,
            persistence: selection,
            visibilityPersistence: visibility
        )
        let stillHidden = await restoredRegistry.refresh(trigger: .appStart)
        #expect(stillHidden.installations == [hermes])
        #expect(stillHidden.hiddenDefinitionIDs == [.codex])

        let restored = await restoredRegistry.restoreInstallations(for: .codex)
        #expect(restored.installations == [codex, hermes])
        #expect(restored.hiddenDefinitionIDs.isEmpty)
    }

    @Test
    func hiddenAgentTypesRemainRestorableAfterAnotherAgentIsRegistered() async throws {
        let codex = available(.codex, path: "/known/codex")
        let hermes = available(.hermes, path: "/known/hermes")
        let registry = AgentRegistry(
            discovery: SelectionDiscovery(scans: [[codex, hermes]]),
            persistence: SelectionPersistence(),
            visibilityPersistence: VisibilityPersistence()
        )

        _ = await registry.refresh(trigger: .appStart)
        _ = await registry.removeInstallation(codex)
        let removed = await registry.removeInstallation(hermes)

        #expect(removed.installations.isEmpty)
        #expect(removed.hiddenDefinitionIDs == [.hermes, .codex])

        let restored = await registry.restoreInstallations(for: .hermes)
        #expect(restored.installations == [hermes])
        #expect(restored.hiddenDefinitionIDs == [.codex])
    }
}

private actor SelectionDiscovery: AgentDiscovering {
    private var scans: [[AgentInstallation]]
    private var lastScan: [AgentInstallation] = []

    init(scans: [[AgentInstallation]]) {
        self.scans = scans
    }

    func scan(explicitPaths: [AgentDefinitionID: String]) async -> [AgentInstallation] {
        if !scans.isEmpty {
            lastScan = scans.removeFirst()
        }
        return lastScan
    }
}

private actor SelectionPersistence: AgentSelectionPersisting {
    private(set) var storedReference: SelectedAgentReference?

    func load() -> SelectedAgentReference? {
        storedReference
    }

    func save(_ reference: SelectedAgentReference?) {
        storedReference = reference
    }
}

private actor VisibilityPersistence: AgentVisibilityPersisting {
    private var identifiers: Set<String> = []

    func loadHiddenInstallationIDs() -> Set<String> {
        identifiers
    }

    func saveHiddenInstallationIDs(_ identifiers: Set<String>) {
        self.identifiers = identifiers
    }
}

private func available(
    _ definitionID: AgentDefinitionID,
    path: String
) -> AgentInstallation {
    AgentInstallation(
        definitionID: definitionID,
        path: path,
        version: "1.0.0",
        runtimeContract: .hermesACP,
        availability: .available
    )
}

private func unavailable(
    _ definitionID: AgentDefinitionID,
    path: String,
    reason: String
) -> AgentInstallation {
    AgentInstallation(
        definitionID: definitionID,
        path: path,
        version: nil,
        runtimeContract: .hermesACP,
        availability: .unavailable(reason: reason)
    )
}
