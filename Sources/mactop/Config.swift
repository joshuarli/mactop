import Foundation

// Read from ~/Library/Preferences/com.mactop.plist first,
// then fall back to Stats' plist, then hardcoded defaults.
//
// Configure with: defaults write com.mactop CPU_updateInterval 2
// Keys mirror Stats: CPU_updateInterval, RAM_updateInterval,
//                    GPU_updateInterval, Network_updateInterval
// mactop also supports Power_updateInterval for the PWR widget.

struct Config {
    var cpuInterval: Double
    var ramInterval: Double
    var gpuInterval: Double
    var netInterval: Double
    var powerInterval: Double
    var syncedInterval: Double {
        max(cpuInterval, ramInterval, gpuInterval, netInterval, powerInterval)
    }

    static let bundleID = "com.mactop"

    static func load() -> Config {
        let own   = UserDefaults(suiteName: bundleID)
        let stats = UserDefaults(suiteName: "eu.exelban.Stats")

        func seconds(key: String, fallback: Int) -> Double {
            if let v = own?.object(forKey: key) as? Int  { return Double(max(1, v)) }
            if let v = stats?.object(forKey: key) as? Int { return Double(max(1, v)) }
            return Double(fallback)
        }

        return Config(
            cpuInterval: seconds(key: "CPU_updateInterval",     fallback: 1),
            ramInterval: seconds(key: "RAM_updateInterval",     fallback: 1),
            gpuInterval: seconds(key: "GPU_updateInterval",     fallback: 3),
            netInterval: seconds(key: "Network_updateInterval", fallback: 1),
            powerInterval: seconds(key: "Power_updateInterval", fallback: 1)
        )
    }
}
