import Foundation

// Read from ~/Library/Preferences/com.mactop.plist first,
// then fall back to hardcoded defaults.
//
// Configure with: defaults write com.mactop UpdateInterval 2

public struct MactopConfig: Sendable {
  public var updateInterval: Double

  private static let minimumUpdateInterval = 1.0
  private static let maximumUpdateInterval = 3_600.0

  public init(updateInterval: Double) {
    guard updateInterval.isFinite else {
      self.updateInterval = Self.minimumUpdateInterval
      return
    }
    self.updateInterval = min(
      max(Self.minimumUpdateInterval, updateInterval), Self.maximumUpdateInterval)
  }

  static let bundleID = "com.mactop"

  public static func load() -> MactopConfig {
    let own = UserDefaults(suiteName: bundleID)

    func seconds(key: String, fallback: Int) -> Double {
      let value: Double?
      if let v = own?.object(forKey: key) as? Double {
        value = v
      } else if let v = own?.object(forKey: key) as? Int {
        value = Double(v)
      } else {
        value = nil
      }
      guard let value, value.isFinite else { return Double(fallback) }
      return min(max(1, value), 3_600)
    }

    return MactopConfig(updateInterval: seconds(key: "UpdateInterval", fallback: 1))
  }
}
