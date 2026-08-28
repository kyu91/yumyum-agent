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

    @Test
    func sendingDoesNotRescanAndVerifiesOnlyTheSelectedPath() async throws {
        let selectedPath = "/known/hermes"
        let otherPath = "/known/codex"
        let hermes = available(.hermes, path: selectedPath)
        let codex = available(.codex, path: otherPath)
        let discovery = SelectionDiscovery(scans: [[hermes, codex]])
        let registry = AgentRegistry(discovery: discovery, persistence: SelectionPersistence())

        _ = await registry.refresh(trigger: .appStart)
        _ = try await registry.select(.hermes, path: selectedPath)

        let scanCountAfterSelect = await discovery.scanCount

        for _ in 0..<3 {
            _ = try await registry.validatedSelection()
        }

        #expect(await discovery.scanCount == scanCountAfterSelect)
        #expect(await discovery.verifyCalls == Array(repeating: "hermes:\(selectedPath)", count: 3))
    }

    @Test
    func sendVerificationFailureInvalidatesSelectionWithoutFallback() async throws {
        let selectedPath = "/known/hermes"
        let fallbackPath = "/known/hermes-fallback"
        let hermes = available(.hermes, path: selectedPath)
        let fallback = available(.hermes, path: fallbackPath)
        let discovery = SelectionDiscovery(scans: [[hermes, fallback]])
        let persistence = SelectionPersistence()
        let registry = AgentRegistry(discovery: discovery, persistence: persistence)

        _ = await registry.refresh(trigger: .appStart)
        _ = try await registry.select(.hermes, path: selectedPath)

        await discovery.setForcedVerifyResult(
            unavailable(.hermes, path: selectedPath, reason: "vanished")
        )

        do {
            _ = try await registry.validatedSelection()
            Issue.record("Expected verification failure to block sending")
        } catch {
            #expect(error as? AgentSelectionError == .explicitReselectionRequired)
        }

        #expect(await persistence.storedReference == nil)
        #expect(await discovery.verifyCalls.filter { $0.hasPrefix("hermes:\(fallbackPath)") }.isEmpty)
    }
}

private actor SelectionDiscovery: AgentDiscovering {
    private var scans: [[AgentInstallation]]
    private var lastScan: [AgentInstallation] = []
    private(set) var scanCount = 0
    private(set) var verifyCalls: [String] = []
    private var forcedVerifyResult: AgentInstallation?

    init(scans: [[AgentInstallation]]) {
        self.scans = scans
    }

    func scan(explicitPaths: [AgentDefinitionID: String]) async -> [AgentInstallation] {
        scanCount += 1
        if !scans.isEmpty {
            lastScan = scans.removeFirst()
        }
        return lastScan
    }

    func setForcedVerifyResult(_ installation: AgentInstallation?) {
        forcedVerifyResult = installation
    }

    func verify(_ definitionID: AgentDefinitionID, at executableURL: URL) async -> AgentInstallation {
        verifyCalls.append("\(definitionID.rawValue):\(executableURL.path)")
        if let forced = forcedVerifyResult,
           forced.definitionID == definitionID,
           forced.path == executableURL.path {
            return forced
        }
        if let match = lastScan.first(where: { $0.definitionID == definitionID && $0.path == executableURL.path }) {
            return match
        }
        return AgentInstallation(
            definitionID: definitionID,
            path: executableURL.path,
            version: nil,
            runtimeContract: .hermesACP,
            availability: .unavailable(reason: "not found")
        )
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
