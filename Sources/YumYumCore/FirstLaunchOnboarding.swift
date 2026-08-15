import Foundation

public enum FirstLaunchOnboarding {
    static let completionKey = "YumYum.FirstLaunchOnboarding.completed"

    public static func presentOnce(
        in defaults: UserDefaults = .standard,
        present: () -> Void
    ) {
        guard !defaults.bool(forKey: completionKey) else { return }
        defaults.set(true, forKey: completionKey)
        present()
    }
}
