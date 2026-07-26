import Foundation

public enum ToolsetEffect: Equatable, Sendable {
    case readOnly
    case externalChange
}

public struct ToolsetDescriptor: Equatable, Sendable {
    public let identifier: String
    public let effect: ToolsetEffect

    public init(identifier: String, effect: ToolsetEffect) {
        self.identifier = identifier
        self.effect = effect
    }
}

public enum ToolsetPolicyDenialReason: Equatable, Sendable {
    case externalChangeRequiresApproval(toolsetID: String)
}

public enum ToolsetPolicyDecision: Equatable, Sendable {
    case allowed
    case denied(ToolsetPolicyDenialReason)
}

public struct ExternalChangeToolsetPolicy: Equatable, Sendable {
    private let approvedExternalChangeToolsetIDs: Set<String>

    public init(approvedExternalChangeToolsetIDs: Set<String> = []) {
        self.approvedExternalChangeToolsetIDs = approvedExternalChangeToolsetIDs
    }

    public func decision(for toolset: ToolsetDescriptor) -> ToolsetPolicyDecision {
        switch toolset.effect {
        case .readOnly:
            return .allowed
        case .externalChange:
            guard approvedExternalChangeToolsetIDs.contains(toolset.identifier) else {
                return .denied(
                    .externalChangeRequiresApproval(toolsetID: toolset.identifier)
                )
            }
            return .allowed
        }
    }
}

public struct TaskScopedApproval: Hashable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let toolsetID: String

    public init(id: UUID, taskID: UUID, toolsetID: String) {
        self.id = id
        self.taskID = taskID
        self.toolsetID = toolsetID
    }
}

public actor TaskApprovalGate {
    private var approvals: Set<TaskScopedApproval> = []

    public init() {}

    public func grant(_ approval: TaskScopedApproval) {
        approvals.insert(approval)
    }

    public func consume(
        taskID: UUID,
        approvalID: UUID,
        toolsetID: String
    ) -> ToolsetPolicyDecision {
        let approval = TaskScopedApproval(
            id: approvalID,
            taskID: taskID,
            toolsetID: toolsetID
        )
        guard approvals.remove(approval) != nil else {
            return .denied(.externalChangeRequiresApproval(toolsetID: toolsetID))
        }
        return .allowed
    }

    public func revokeAll(for taskID: UUID) {
        approvals = approvals.filter { $0.taskID != taskID }
    }
}
