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
