import Foundation

public enum HermesExecutableLocationError: Error, Equatable, Sendable {
    case explicitPathMustBeAbsolute(String)
    case notExecutable(String)
    case notFound(searchedPaths: [String])
}

public struct HermesExecutableLocator: Sendable {
    public static var defaultAllowedPATHDirectories: [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    private let allowedPATHDirectories: Set<String>

    public init(
        allowedPATHDirectories: [URL] = HermesExecutableLocator.defaultAllowedPATHDirectories
    ) {
        self.allowedPATHDirectories = Set(
            allowedPATHDirectories.map { $0.standardizedFileURL.path }
        )
    }

    public func locate(
        explicitPath: String? = nil,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) throws -> URL {
        if let explicitPath {
            guard NSString(string: explicitPath).isAbsolutePath else {
                throw HermesExecutableLocationError.explicitPathMustBeAbsolute(explicitPath)
            }

            let executable = URL(fileURLWithPath: explicitPath).standardizedFileURL
            guard isExecutableFile(executable) else {
                throw HermesExecutableLocationError.notExecutable(executable.path)
            }
            return executable
        }

        var searchedPaths: [String] = []
        var visitedDirectories: Set<String> = []

        for component in pathEnvironment?.split(separator: ":", omittingEmptySubsequences: true) ?? [] {
            let path = String(component)
            guard NSString(string: path).isAbsolutePath else {
                continue
            }

            let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard allowedPATHDirectories.contains(directory.path) else {
                continue
            }
            guard visitedDirectories.insert(directory.path).inserted else {
                continue
            }

            let candidate = directory.appendingPathComponent("hermes", isDirectory: false)
            searchedPaths.append(candidate.path)
            if isExecutableFile(candidate) {
                return candidate
            }
        }

        throw HermesExecutableLocationError.notFound(searchedPaths: searchedPaths)
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
