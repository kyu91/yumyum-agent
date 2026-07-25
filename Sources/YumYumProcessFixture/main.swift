import Darwin
import Foundation

private func write(_ value: String, to handle: FileHandle) {
    handle.write(Data(value.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    write("missing fixture mode\n", to: .standardError)
    exit(64)
}

switch mode {
case "--version":
    write("Hermes Fixture 0.0.0\n", to: .standardOutput)

case "emit":
    write("stdout-value", to: .standardOutput)
    write("stderr-value", to: .standardError)
    exit(7)

case "flood":
    let standardOutputChunk = Data(repeating: 0x4F, count: 4_096)
    let standardErrorChunk = Data(repeating: 0x45, count: 4_096)
    for _ in 0..<256 {
        FileHandle.standardOutput.write(standardOutputChunk)
        FileHandle.standardError.write(standardErrorChunk)
    }

case "arguments":
    let payload = try JSONSerialization.data(
        withJSONObject: Array(arguments.dropFirst()),
        options: [.sortedKeys]
    )
    FileHandle.standardOutput.write(payload)

case "ignore-term":
    signal(SIGTERM, SIG_IGN)
    write("ready\n", to: .standardOutput)
    while true {
        sleep(60)
    }

case "exit-with-descendant-holding-pipes":
    let descendant = Process()
    descendant.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    descendant.arguments = ["hold-pipes-open"]
    descendant.standardOutput = FileHandle.standardOutput
    descendant.standardError = FileHandle.standardError
    try descendant.run()
    write("parent-exited\n", to: .standardOutput)

case "hold-pipes-open":
    sleep(3)

default:
    write("unknown fixture mode: \(mode)\n", to: .standardError)
    exit(64)
}
