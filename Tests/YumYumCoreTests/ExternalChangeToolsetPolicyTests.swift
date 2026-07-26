import Foundation
import Testing
@testable import YumYumCore

@Suite
struct ExternalChangeToolsetPolicyTests {
    @Test
    func taskApprovalIsScopedConsumedOnceAndNeverPersisted() async {
        let taskID = UUID()
        let otherTaskID = UUID()
        let approvalID = UUID()
        let gate = TaskApprovalGate()

        await gate.grant(
            TaskScopedApproval(
                id: approvalID,
                taskID: taskID,
                toolsetID: "calendar"
            )
        )

        #expect(
            await gate.consume(
                taskID: otherTaskID,
                approvalID: approvalID,
                toolsetID: "calendar"
            ) == .denied(.externalChangeRequiresApproval(toolsetID: "calendar"))
        )
        #expect(
            await gate.consume(
                taskID: taskID,
                approvalID: approvalID,
                toolsetID: "calendar"
            ) == .allowed
        )
        #expect(
            await gate.consume(
                taskID: taskID,
                approvalID: approvalID,
                toolsetID: "calendar"
            ) == .denied(.externalChangeRequiresApproval(toolsetID: "calendar"))
        )
        #expect(
            await TaskApprovalGate().consume(
                taskID: taskID,
                approvalID: approvalID,
                toolsetID: "calendar"
            ) == .denied(.externalChangeRequiresApproval(toolsetID: "calendar"))
        )
    }

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
