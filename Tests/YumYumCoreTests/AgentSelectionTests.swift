import Testing
@testable import YumYumCore

@Suite
struct AgentSelectionTests {
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
