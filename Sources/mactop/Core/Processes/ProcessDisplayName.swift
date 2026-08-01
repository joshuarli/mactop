import Foundation
import mactopPlatform

// Resolves stable display names for process rows, including app bundle and versioned
// executable fallbacks when the platform process name is implementation-oriented.
func processDisplayName(pid: Int32) -> String {
  let rawName = ProcessPlatform.processName(pid: pid)

  if rawName == "plugin-container" {
    return bundleDisplayName(pid: pid) ?? rawName
  }

  if rawName.isVersionNumber,
    let ownerName = versionedExecutableOwnerName(pid: pid, rawName: rawName)
  {
    return ownerName
  }

  return rawName.isEmpty ? "pid \(pid)" : rawName
}

private func bundleDisplayName(pid: Int32) -> String? {
  guard let path = ProcessPlatform.processPath(pid: pid) else { return nil }
  var url = URL(fileURLWithPath: path)
  while url.path != "/" {
    if url.pathExtension == "app" {
      if let bundle = Bundle(url: url),
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
          ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
        !name.isEmpty
      {
        return name
      }
      let fallback = url.deletingPathExtension().lastPathComponent
      return fallback.isEmpty ? nil : fallback
    }
    url.deleteLastPathComponent()
  }

  return nil
}

private func versionedExecutableOwnerName(pid: Int32, rawName: String) -> String? {
  guard let path = ProcessPlatform.processPath(pid: pid) else { return nil }
  let url = URL(fileURLWithPath: path)
  let components = url.pathComponents
  guard components.last == rawName,
    components.count >= 3,
    components[components.count - 2] == "versions"
  else { return nil }

  let owner = components[components.count - 3]
  guard !owner.isEmpty else { return nil }
  return owner.prefix(1).uppercased() + owner.dropFirst()
}

extension String {
  fileprivate var isVersionNumber: Bool {
    range(of: #"^[0-9]+(\.[0-9]+)+$"#, options: .regularExpression) != nil
  }
}
