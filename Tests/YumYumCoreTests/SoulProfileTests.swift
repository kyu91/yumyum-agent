import Foundation
import Testing
@testable import YumYumCore

@Suite
struct SoulProfileTests {
    @Test
    func normalizesBoundsRendersAndParsesDeterministically() throws {
        let profile = SoulProfile(
            name: "  Yum   Yum  ",
            role: "Helper\n\n  Planner\n## Name\n\\literal",
            personality: String(repeating: "a", count: 2_100)
        )

        let normalized = profile.normalized
        #expect(profile.name == "  Yum   Yum  ")
        #expect(normalized.name == "Yum Yum")
        #expect(normalized.role == "Helper\n\nPlanner\n## Name\n\\literal")
        #expect(normalized.personality.count == SoulProfile.maximumFieldLength)
        #expect(normalized.markdown.contains("subordinate to YumYum safety"))
        #expect(!normalized.markdown.contains("## Likes"))
        #expect(SoulProfile.parse(markdown: normalized.markdown) == normalized)
    }

    @Test
    func totalLengthIsBoundedInFieldOrder() {
        let value = String(repeating: "x", count: SoulProfile.maximumFieldLength)
        let profile = SoulProfile(
            name: value, role: value, personality: value, speakingStyle: value,
            coreValues: value, likes: value, dislikes: value, userAddress: value,
            behaviorPrinciples: value, additionalInstructions: value
        )
        let normalized = profile.normalized
        let total = [normalized.name, normalized.role, normalized.personality, normalized.speakingStyle,
                     normalized.coreValues, normalized.likes, normalized.dislikes, normalized.userAddress,
                     normalized.behaviorPrinciples, normalized.additionalInstructions]
            .reduce(0) { $0 + $1.count }
        #expect(total == SoulProfile.maximumTotalLength)
    }

    @Test
    func normalizesAllNewlineStylesBeforeWhitespaceAndEscapesHeadingLines() throws {
        let profile = SoulProfile(role: " first \r\n## Unknown\rthird ").normalized

        #expect(profile.role == "first\n## Unknown\nthird")
        #expect(profile.markdown.contains("\\## Unknown"))
        #expect(SoulProfile.parse(markdown: profile.markdown) == profile)
    }

    @Test(arguments: [
        "# YumYum Soul\n",
        SoulProfile(name: "Momo").normalized.markdown.replacingOccurrences(
            of: "## Name", with: "## Unknown"
        ),
        SoulProfile(name: "Momo", role: "Helper").normalized.markdown.replacingOccurrences(
            of: "## Name\n\nMomo\n\n## Role / Identity",
            with: "## Role / Identity\n\nHelper\n\n## Name\n\nMomo"
        ),
        SoulProfile(name: "Momo").normalized.markdown + "\n## Name\n\nAgain\n",
    ])
    func rejectsMalformedOwnedGrammar(_ markdown: String) {
        #expect(SoulProfile.parse(markdown: markdown) == nil)
    }

    @Test
    func storeRoundTripsAndMalformedOrOversizedFilesLoadEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("SOUL.md")
        let store = SoulProfileStore(fileURL: url)
        let profile = SoulProfile(name: "Momo", coreValues: "Kindness")

        try await store.save(profile)
        #expect(await store.load() == profile)
        try Data("not owned".utf8).write(to: url, options: .atomic)
        #expect(await store.load() == .empty)
        try Data(repeating: 65, count: SoulProfile.maximumTotalLength * 4 + 1)
            .write(to: url, options: .atomic)
        #expect(await store.load() == .empty)
    }

    @Test
    func appOwnedStoreRejectsDirectoryAndFileSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("YumYum"),
            withDestinationURL: outside
        )
        let directoryStore = SoulProfileStore(appSupportDirectoryURL: support)

        #expect(await directoryStore.load() == .empty)
        await #expect(throws: (any Error).self) {
            try await directoryStore.save(SoulProfile(name: "Momo"))
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("SOUL.md").path))

        try FileManager.default.removeItem(at: support.appendingPathComponent("YumYum"))
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("YumYum"),
            withIntermediateDirectories: false
        )
        let outsideFile = outside.appendingPathComponent("SOUL.md")
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("YumYum/SOUL.md"),
            withDestinationURL: outsideFile
        )
        let fileStore = SoulProfileStore(appSupportDirectoryURL: support)

        #expect(await fileStore.load() == .empty)
        await #expect(throws: (any Error).self) {
            try await fileStore.save(SoulProfile(name: "Momo"))
        }
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside")
    }
}
