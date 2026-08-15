import Foundation
import Testing
@testable import YumYumCore

@Suite
struct FirstLaunchOnboardingTests {
    @Test
    func presentsOnceAndMarksCompletion() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        var presentations = 0

        FirstLaunchOnboarding.presentOnce(in: suite.defaults) { presentations += 1 }

        #expect(presentations == 1)
        #expect(suite.defaults.bool(forKey: FirstLaunchOnboarding.completionKey))
    }

    @Test
    func doesNotPresentAgainAfterCompletion() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        var presentations = 0

        FirstLaunchOnboarding.presentOnce(in: suite.defaults) { presentations += 1 }
        FirstLaunchOnboarding.presentOnce(in: suite.defaults) { presentations += 1 }

        #expect(presentations == 1)
    }

    @Test
    func dismissalWithoutPermissionStillSuppressesFuturePresentation() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        var presentations = 0

        FirstLaunchOnboarding.presentOnce(in: suite.defaults) { presentations += 1 }
        FirstLaunchOnboarding.presentOnce(in: suite.defaults) { presentations += 1 }

        #expect(presentations == 1)
    }

    @Test
    func completionKeyIsStable() {
        #expect(FirstLaunchOnboarding.completionKey == "YumYum.FirstLaunchOnboarding.completed")
    }

    private func makeDefaults() throws -> DefaultsSuite {
        let name = "FirstLaunchOnboardingTests.\(UUID().uuidString)"
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
