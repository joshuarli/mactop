import Darwin
import Foundation
import IOKit

public enum PlatformCPUCoreKind: Sendable {
  case efficiency
  case performance
  case unknown
}

public struct PlatformCPUTick: Sendable {
  public let user: Double
  public let system: Double
  public let idle: Double
  public let nice: Double
}

public struct PlatformCPUHardwareSnapshot: Sendable {
  public let ticks: [PlatformCPUTick]
  public let coreKinds: [PlatformCPUCoreKind]
}

public enum MachCPUPlatform {
  public static let bootDate: Date = {
    var bootTime = timeval()
    var size = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
    return Date(timeIntervalSince1970: Double(bootTime.tv_sec))
  }()

  public static func readHardwareSnapshot() -> PlatformCPUHardwareSnapshot? {
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    var cpuCount: natural_t = 0
    guard
      host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        == KERN_SUCCESS,
      let info
    else { return nil }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(bitPattern: info),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    var ticks: [PlatformCPUTick] = []
    ticks.reserveCapacity(Int(cpuCount))
    for index in 0..<Int(cpuCount) {
      let base = index * Int(CPU_STATE_MAX)
      ticks.append(
        PlatformCPUTick(
          user: Double(info[base + Int(CPU_STATE_USER)]),
          system: Double(info[base + Int(CPU_STATE_SYSTEM)]),
          idle: Double(info[base + Int(CPU_STATE_IDLE)]),
          nice: Double(info[base + Int(CPU_STATE_NICE)])
        ))
    }
    return PlatformCPUHardwareSnapshot(ticks: ticks, coreKinds: readCoreKinds(count: ticks.count))
  }

  public static func loadAverage() -> [Double] {
    var values = [Double](repeating: 0, count: 3)
    getloadavg(&values, 3)
    return values
  }

  private static func readCoreKinds(count: Int) -> [PlatformCPUCoreKind] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &iterator)
        == KERN_SUCCESS
    else {
      return Array(repeating: .unknown, count: count)
    }
    defer { IOObjectRelease(iterator) }
    var result = Array(repeating: PlatformCPUCoreKind.unknown, count: count)
    while let service = nextObject(iterator) {
      defer { IOObjectRelease(service) }
      var children: io_iterator_t = 0
      guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS
      else { continue }
      defer { IOObjectRelease(children) }
      while let child = nextObject(children) {
        defer { IOObjectRelease(child) }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(child, &name) == KERN_SUCCESS,
          let id = Int(nameString(name).dropFirst(3))
        else { continue }
        var properties: Unmanaged<CFMutableDictionary>?
        guard
          IORegistryEntryCreateCFProperties(child, &properties, kCFAllocatorDefault, 0)
            == KERN_SUCCESS,
          let values = properties?.takeRetainedValue() as? [String: Any]
        else { continue }
        let type = (values["cluster-type"] as? Data).flatMap { String(data: $0, encoding: .utf8) }?
          .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if result.indices.contains(id) {
          result[id] =
            type == "E" ? .efficiency : (type == "P" || type == "M" ? .performance : .unknown)
        }
      }
    }
    return result
  }

  private static func nextObject(_ iterator: io_iterator_t) -> io_object_t? {
    let object = IOIteratorNext(iterator)
    return object == 0 ? nil : object
  }

  private static func nameString(_ name: [CChar]) -> String {
    String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
