import Foundation
import Testing
@testable import YumYumCore

@Suite
struct HermesACPCommandTests {
    @Test
    func rejectsCommandConstructionWhenACPCapabilityIsUnavailable() throws {
        let builder = HermesACPCommandBuilder(
            capabilityGate: HermesCapabilityGate(advertisedCapabilities: [])
        )

        do {
            _ = try builder.makeCommand(
                executableURL: URL(fileURLWithPath: "/allowed/hermes")
            )
            Issue.record("Expected ACP command construction to be gated")
        } catch {
            #expect(
                error as? HermesCapabilityError
                    == .capabilityUnavailable(.acp)
            )
        }
    }

    @Test
    func constructsDirectACPArgvWhenCapabilityIsAvailable() throws {
        let executable = URL(fileURLWithPath: "/allowed/hermes")
        let builder = HermesACPCommandBuilder(
            capabilityGate: HermesCapabilityGate(advertisedCapabilities: [.acp])
        )

        let command = try builder.makeCommand(executableURL: executable)

        #expect(command.executableURL == executable)
        #expect(command.arguments == ["acp"])
        #expect(command.environment == nil)
        #expect(command.currentDirectoryURL == nil)
    }
}
