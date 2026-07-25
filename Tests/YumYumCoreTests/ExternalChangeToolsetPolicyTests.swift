import Testing
@testable import YumYumCore

@Suite
struct ExternalChangeToolsetPolicyTests {
    @Test
    func allowsReadOnlyToolsetByDefault() {
        let policy = ExternalChangeToolsetPolicy()
        let toolset = ToolsetDescriptor(identifier: "search", effect: .readOnly)

        #expect(policy.decision(for: toolset) == .allowed)
    }

    @Test
    func deniesExternalChangeToolsetByDefault() {
        let policy = ExternalChangeToolsetPolicy()
        let toolset = ToolsetDescriptor(identifier: "calendar", effect: .externalChange)

        #expect(
            policy.decision(for: toolset)
                == .denied(.externalChangeRequiresApproval(toolsetID: "calendar"))
        )
    }

    @Test
    func allowsOnlyTheExplicitlyApprovedExternalChangeToolset() {
        let policy = ExternalChangeToolsetPolicy(
            approvedExternalChangeToolsetIDs: ["calendar"]
        )

        #expect(
            policy.decision(
                for: ToolsetDescriptor(identifier: "calendar", effect: .externalChange)
            ) == .allowed
        )
        #expect(
            policy.decision(
                for: ToolsetDescriptor(identifier: "email", effect: .externalChange)
            ) == .denied(.externalChangeRequiresApproval(toolsetID: "email"))
        )
    }
}
