import Foundation
import Testing
@testable import YumYumCore

@Suite
struct LegacyPreferencesMigrationTests {
    @Test
    func copiesOnlyKnownKeysFromOldDomain() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in [
            "appLanguage": "korean",
            "YumYum.appTheme": "light",
            "YumYum.GlobalShortcut": "commandShiftSpace",
            "YumYum.SelectedAgent.definitionID": "codex",
            "YumYum.SelectedAgent.path": "/usr/local/bin/codex",
            "unknown": "must-not-migrate",
        ] }

        #expect(suite.defaults.string(forKey: "appLanguage") == "korean")
        #expect(suite.defaults.string(forKey: "YumYum.appTheme") == "light")
        #expect(suite.defaults.string(forKey: "YumYum.GlobalShortcut") == "commandShiftSpace")
        #expect(suite.defaults.string(forKey: "YumYum.SelectedAgent.definitionID") == "codex")
        #expect(suite.defaults.string(forKey: "YumYum.SelectedAgent.path") == "/usr/local/bin/codex")
        #expect(suite.defaults.object(forKey: "unknown") == nil)
    }

    @Test
    func firstCopyIsNotRepeatedWhenLegacySourceChanges() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        var oldValues = ["appLanguage": "korean"]

        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in oldValues }
        oldValues["appLanguage"] = "english"
        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in oldValues }

        #expect(suite.defaults.string(forKey: "appLanguage") == "korean")
    }

    @Test
    func removedDestinationDoesNotResurrectAfterCompletedMigration() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }

        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in ["appLanguage": "korean"] }
        suite.defaults.removeObject(forKey: "appLanguage")
        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in ["appLanguage": "english"] }

        #expect(suite.defaults.object(forKey: "appLanguage") == nil)
    }

    @Test
    func absentOldDomainCompletesMigration() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }

        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in nil }
        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in ["appLanguage": "korean"] }

        #expect(suite.defaults.bool(forKey: LegacyPreferencesMigration.completionKey))
        #expect(suite.defaults.object(forKey: "appLanguage") == nil)
    }

    @Test
    func existingDestinationValueIsPreserved() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        suite.defaults.set("english", forKey: "appLanguage")

        LegacyPreferencesMigration.migrate(to: suite.defaults) { _ in ["appLanguage": "korean"] }

        #expect(suite.defaults.string(forKey: "appLanguage") == "english")
    }

    @Test
    func knownKeySetIsExact() {
        #expect(LegacyPreferencesMigration.knownKeys == [
            "appLanguage",
            "YumYum.appTheme",
            "YumYum.GlobalShortcut",
            "YumYum.SelectedAgent.definitionID",
            "YumYum.SelectedAgent.path",
        ])
    }

    private func makeDefaults() throws -> DefaultsSuite {
        let name = "LegacyPreferencesMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return DefaultsSuite(name: name, defaults: defaults)
    }

    private struct DefaultsSuite {
        let name: String
        let defaults: UserDefaults

        func remove() {
            defaults.removePersistentDomain(forName: name)
        }
    }
}
