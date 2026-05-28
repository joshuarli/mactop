import Foundation

// Read from ~/Library/Preferences/com.mactop.plist first,
// then fall back to hardcoded defaults.
//
// Configure with: defaults write com.mactop UpdateInterval 2

struct Config {
    var updateInterval: Double

    static let bundleID = "com.mactop"

    static func load() -> Config {
        let own = UserDefaults(suiteName: bundleID)

        func seconds(key: String, fallback: Int) -> Double {
            if let v = own?.object(forKey: key) as? Double { return max(1, v) }
            if let v = own?.object(forKey: key) as? Int { return Double(max(1, v)) }
            return Double(fallback)
        }

        return Config(updateInterval: seconds(key: "UpdateInterval", fallback: 1))
    }
}
