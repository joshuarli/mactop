import Darwin
import Foundation
import IOKit

public struct PlatformGPUHardwareSnapshot: Sendable {
  public let total: Double
  public let render: Double
  public let tiler: Double
  public let model: String
  public let renderTilerSplit: Bool
}

public final class IOAcceleratorPlatform: @unchecked Sendable {
  private var service: io_object_t = 0
  private var hasSplit = false

  public init() {}

  deinit {
    if service != 0 { IOObjectRelease(service) }
  }

  public func read() -> PlatformGPUHardwareSnapshot? {
    if service != 0, let values = readStatistics(service) {
      return snapshot(values)
    }
    if service != 0 {
      IOObjectRelease(service)
      service = 0
    }
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    while let candidate = next(iterator) {
      if let values = readStatistics(candidate) {
        service = candidate
        return snapshot(values)
      }
      IOObjectRelease(candidate)
    }
    return nil
  }

  private func snapshot(_ values: (total: Double, render: Double, tiler: Double))
    -> PlatformGPUHardwareSnapshot
  {
    if abs(values.render - values.tiler) > 0.005 { hasSplit = true }
    return PlatformGPUHardwareSnapshot(
      total: values.total, render: values.render, tiler: values.tiler, model: modelName(),
      renderTilerSplit: hasSplit)
  }

  private func readStatistics(_ service: io_object_t) -> (
    total: Double, render: Double, tiler: Double
  )? {
    if let unmanaged = IORegistryEntryCreateCFProperty(
      service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
    {
      let value = unmanaged.takeRetainedValue()
      if CFGetTypeID(value) == CFDictionaryGetTypeID() {
        let dictionary = unsafeDowncast(value, to: CFDictionary.self)
        return utilizationValues(dictionary)
      }
    }
    var properties: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        == KERN_SUCCESS,
      let dictionary = properties?.takeRetainedValue() as? [String: Any],
      let performance = dictionary["PerformanceStatistics"] as? [String: Any]
    else { return nil }
    let total =
      (performance["Device Utilization %"] as? Double ?? performance["GPU Activity(%)"] as? Double
        ?? 0) / 100
    return (
      total, (performance["Renderer Utilization %"] as? Double ?? 0) / 100,
      (performance["Tiler Utilization %"] as? Double ?? 0) / 100
    )
  }

  private func utilizationValues(_ dictionary: CFDictionary) -> (
    total: Double, render: Double, tiler: Double
  )? {
    func number(_ key: String) -> Double? {
      let cfKey = key as CFString
      guard
        let pointer = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(cfKey).toOpaque())
      else { return nil }
      let value = unsafeBitCast(pointer, to: CFNumber.self)
      var result = 0.0
      return CFNumberGetValue(value, .doubleType, &result) ? result : nil
    }
    let total = number("Device Utilization %") ?? number("GPU Activity(%)") ?? 0
    return (
      total / 100, (number("Renderer Utilization %") ?? 0) / 100,
      (number("Tiler Utilization %") ?? 0) / 100
    )
  }

  private func modelName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    var size = buffer.count
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    let value = String(
      decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return value.isEmpty ? "GPU" : "\(value) GPU"
  }

  private func next(_ iterator: io_iterator_t) -> io_object_t? {
    let value = IOIteratorNext(iterator)
    return value == 0 ? nil : value
  }
}
