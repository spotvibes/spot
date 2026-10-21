import Foundation

enum AppConfig {
    static let apiBaseURL: String = string(forKey: "API_BASE_URL")

    static let gatewayURL: String = string(forKey: "WS_URL", trimTrailingSlash: false)

    private static func string(forKey key: String, trimTrailingSlash: Bool = true) -> String {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !raw.isEmpty,
            !raw.hasPrefix("$(")
        else {
            fatalError("""
                Missing Info.plist value '\(key)'. Copy Config.example.xcconfig to \
                Config.xcconfig, fill it in, and attach it to the project/target \
                configurations (Info tab > Configurations).
                """)
        }
        return trimTrailingSlash && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}
