import Darwin
import Foundation
import YumYumCore

private struct ProbeOutput: Encodable {
    let standardOutput: String
    let standardError: String
    let exitStatus: Int32?
    let timedOut: Bool
}

private func write(_ value: String, to handle: FileHandle) {
    handle.write(Data(value.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--hermes" else {
    write("Usage: yumyum-probe --hermes <absolute-path>\n", to: .standardError)
    exit(64)
}

do {
    let executableURL = try HermesExecutableLocator(allowedPATHDirectories: []).locate(
        explicitPath: arguments[1],
        pathEnvironment: nil
    )
    let result = try await HermesVersionProbe(processRunner: ProcessRunner()).probe(
        executableURL: executableURL
    )
    let output = ProbeOutput(
        standardOutput: result.standardOutput,
        standardError: result.standardError,
        exitStatus: result.exitStatus,
        timedOut: result.timedOut
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(output))
    write("\n", to: .standardOutput)

    if result.timedOut {
        exit(124)
    }
    guard let exitStatus = result.exitStatus, (0...255).contains(exitStatus) else {
        exit(70)
    }
    exit(exitStatus)
} catch {
    write("yumyum-probe: \(error)\n", to: .standardError)
    exit(70)
}
