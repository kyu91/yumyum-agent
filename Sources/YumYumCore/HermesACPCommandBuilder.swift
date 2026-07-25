import Foundation

public enum HermesCapability: String, Hashable, Sendable {
    case acp
}

public enum HermesCapabilityError: Error, Equatable, Sendable {
    case capabilityUnavailable(HermesCapability)
}

public struct HermesCapabilityGate: Equatable, Sendable {
    private let advertisedCapabilities: Set<HermesCapability>

    public init(advertisedCapabilities: Set<HermesCapability>) {
        self.advertisedCapabilities = advertisedCapabilities
    }

    public func require(_ capability: HermesCapability) throws {
        guard advertisedCapabilities.contains(capability) else {
            throw HermesCapabilityError.capabilityUnavailable(capability)
        }
    }
}

public struct HermesACPCommandBuilder: Equatable, Sendable {
    private let capabilityGate: HermesCapabilityGate

    public init(capabilityGate: HermesCapabilityGate) {
        self.capabilityGate = capabilityGate
    }

    public func makeCommand(executableURL: URL) throws -> ProcessCommand {
        try capabilityGate.require(.acp)
        return ProcessCommand(executableURL: executableURL, arguments: ["acp"])
    }
}
