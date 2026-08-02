import Foundation

public enum LegacyPreferencesMigration {
    public static let oldDomain = "kr.yumyum.phase0"
    static let completionKey = "YumYum.LegacyPreferencesMigration.kr.yumyum.phase0.completed"
    public static let knownKeys = [
        "appLanguage",
        "YumYum.appTheme",
        "YumYum.GlobalShortcut",
        "YumYum.SelectedAgent.definitionID",
        "YumYum.SelectedAgent.path",
    ]

    public static func migrate(
        to defaults: UserDefaults = .standard,
        domainValues: (String) -> [String: Any]? = {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
    ) {
        guard !defaults.bool(forKey: completionKey) else { return }
        if let oldValues = domainValues(oldDomain) {
            for key in knownKeys where defaults.object(forKey: key) == nil {
                if let value = oldValues[key] {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: completionKey)
    }
}
