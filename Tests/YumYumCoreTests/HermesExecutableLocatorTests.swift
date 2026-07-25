import Foundation
import Testing
@testable import YumYumCore

@Suite
struct HermesExecutableLocatorTests {
    @Test
    func explicitAbsoluteExecutableIsReturnedOutsidePATHAllowlist() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let explicitExecutable = try makeExecutable(
            in: temporaryDirectory,
            name: "custom-hermes"
        )
        let locator = HermesExecutableLocator(allowedPATHDirectories: [])

        let located = try locator.locate(
            explicitPath: explicitExecutable.path,
            pathEnvironment: nil
        )

        #expect(located == explicitExecutable.standardizedFileURL)
    }

    @Test
    func relativeExplicitPathIsRejected() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let locator = HermesExecutableLocator(allowedPATHDirectories: [temporaryDirectory])

        do {
            _ = try locator.locate(
                explicitPath: "bin/hermes",
                pathEnvironment: temporaryDirectory.path
            )
            Issue.record("Expected a relative explicit path to be rejected")
        } catch {
            #expect(
                error as? HermesExecutableLocationError
                    == .explicitPathMustBeAbsolute("bin/hermes")
            )
        }
    }

    @Test
    func invalidExplicitPathDoesNotFallBackToPATH() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let explicitExecutable = temporaryDirectory.appendingPathComponent("not-executable")
        try Data().write(to: explicitExecutable)
        _ = try makeExecutable(in: temporaryDirectory, name: "hermes")
        let locator = HermesExecutableLocator(allowedPATHDirectories: [temporaryDirectory])

        do {
            _ = try locator.locate(
                explicitPath: explicitExecutable.path,
                pathEnvironment: temporaryDirectory.path
            )
            Issue.record("Expected a non-executable explicit path to be rejected")
        } catch {
            #expect(
                error as? HermesExecutableLocationError
                    == .notExecutable(explicitExecutable.path)
            )
        }
    }

    @Test
    func pathSearchUsesOnlyAllowedDirectoriesInPATHOrder() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let firstAllowed = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
        let secondAllowed = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        let unallowed = temporaryDirectory.appendingPathComponent("unallowed", isDirectory: true)
        for directory in [firstAllowed, secondAllowed, unallowed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        _ = try makeExecutable(in: firstAllowed, name: "hermes")
        let expected = try makeExecutable(in: secondAllowed, name: "hermes")
        _ = try makeExecutable(in: unallowed, name: "hermes")
        let locator = HermesExecutableLocator(
            allowedPATHDirectories: [firstAllowed, secondAllowed]
        )

        let located = try locator.locate(
            pathEnvironment: [unallowed.path, secondAllowed.path, firstAllowed.path]
                .joined(separator: ":")
        )

        #expect(located == expected.standardizedFileURL)
    }

    @Test
    func unallowedPATHCandidateIsNotSearched() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let unallowed = temporaryDirectory.appendingPathComponent("unallowed", isDirectory: true)
        try FileManager.default.createDirectory(at: unallowed, withIntermediateDirectories: true)
        _ = try makeExecutable(in: unallowed, name: "hermes")
        let locator = HermesExecutableLocator(allowedPATHDirectories: [])

        do {
            _ = try locator.locate(pathEnvironment: unallowed.path)
            Issue.record("Expected an unallowed PATH entry to be ignored")
        } catch {
            #expect(
                error as? HermesExecutableLocationError
                    == .notFound(searchedPaths: [])
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }
}
