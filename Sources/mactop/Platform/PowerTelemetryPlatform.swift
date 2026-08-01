import Darwin
import Foundation
import IOKit

public struct PlatformModeledPowerSample: Sendable {
  public let cpu: Double
  public let gpu: Double
  public let ane: Double
  public let memory: Double
  public let media: Double
  public let display: Double
  public let other: Double

  public var modeled: Double { cpu + gpu + ane + memory + media + display + other }
}

public struct PlatformBatteryChargingDetail: Sendable {
  public let externalConnected: Bool
  public let isCharging: Bool
  public let isFullyCharged: Bool
  public let adapterName: String?
  public let adapterWatts: Double?
  public let inputWatts: Double?
  public let batteryWatts: Double?
  public let batteryFraction: Double?
  public let wallWatts: Double?
  public let energyConsumedWatts: Double?
}

public struct PlatformPowerPhaseTiming: Sendable {
  public let name: String
  public let wallNanoseconds: UInt64
}

private let platformMaximumPowerWatts = 2_000.0
private func platformValidatedPower(_ watts: Double) -> Double? {
  watts.isFinite && watts >= 0 && watts <= platformMaximumPowerWatts ? watts : nil
}
public final class PlatformModeledPowerReader {
  // Buckets mirror the aggregate-versus-detail-channel rules the parser
  // applies to Energy Model and DCP groups. Both subscription filtering and
  // parsePower use these so a renamed channel is treated the same way.
  private enum ModeledBucket {
    case cpu
    case gpu
    case ane
    case memory
    case media
    case dcsDisplay
    case dcpDisplay
    case other
  }

  private static func classifyChannel(group: String, subgroup: String, name: String)
    -> ModeledBucket?
  {
    if group == "Energy Model" {
      switch name {
      case "GPU Energy":
        return .gpu
      case let name where name.hasSuffix("CPU Energy"):
        return .cpu
      case let name where name.hasPrefix("ANE"):
        return .ane
      case let name
      where name.hasPrefix("DRAM") || name.hasPrefix("AMCC") || name.hasPrefix("GPU SRAM"):
        return .memory
      case let name where name.hasPrefix("DCS"):
        return .dcsDisplay
      case let name where name.hasPrefix("AVE") || name.hasPrefix("ISP") || name.hasPrefix("MSR"):
        return .media
      case let name where name.contains("PCIe") || name.hasPrefix("apciec"):
        return .other
      default:
        return nil
      }
    }
    if group.hasPrefix("DCP"), subgroup == "display stats", name == "power" {
      return .dcpDisplay
    }
    return nil
  }

  // A channel is addressed by its provider (driver) plus channel id. The id
  // alone is not unique: PCIe ports and apciec rails share the "EngyPt0" id
  // and DCP/DCPEXT display controllers share the "IOMFBENG" id, so the
  // classification cache must key on both values.
  private struct ChannelKey: Hashable {
    let driverID: UInt64
    let channelID: UInt64
  }

  private struct ChannelEntry {
    let bucket: ModeledBucket
    // Energy-unit raw value divisor, e.g. 1_000 for mJ. nil for DCP
    // display power, which is interpreted as microwatt-seconds directly.
    let rawUnitDivisor: Double?
  }

  private struct IOReportAPI {
    typealias CopyChannelsInGroup =
      @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) ->
      UnsafeRawPointer?
    typealias CreateSubscription =
      @convention(c) (
        UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?, UInt64,
        UnsafeRawPointer?
      ) -> UnsafeRawPointer?
    typealias CreateSamples =
      @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias CreateSamplesDelta =
      @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias MergeChannels =
      @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
    typealias ChannelString = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias ChannelID = @convention(c) (UnsafeRawPointer?) -> UInt64
    typealias SimpleIntegerValue = @convention(c) (UnsafeRawPointer?, Int32) -> Int64

    var handle: UnsafeMutableRawPointer
    var copyChannelsInGroup: CopyChannelsInGroup
    var createSubscription: CreateSubscription
    var createSamples: CreateSamples
    var createSamplesDelta: CreateSamplesDelta
    var mergeChannels: MergeChannels
    var channelGetGroup: ChannelString
    var channelGetSubGroup: ChannelString
    var channelGetChannelName: ChannelString
    var channelGetChannelID: ChannelID
    var channelGetDriverID: ChannelID
    var channelGetUnitLabel: ChannelString
    var simpleGetIntegerValue: SimpleIntegerValue
  }

  private let api: IOReportAPI
  private let channels: CFMutableDictionary
  private let subscription: UnsafeRawPointer
  private let channelCache: [ChannelKey: ChannelEntry]
  private let debugEnabled = ProcessInfo.processInfo.environment["MACTOP_DEBUG_POWER"] == "1"
  private var didLogDebug = false
  private var previousSample: (sample: CFDictionary, time: Date)?
  private let maximumSampleInterval: TimeInterval
  // Sampling the filtered subscription is the dominant modeled-power cost
  // (~2.9 ms/tick, mostly a fixed DCP display channel floor). IOReport
  // counters are accumulated energy, so sampling at half cadence and
  // reusing the last computed sample between samples loses no accuracy
  // while cutting the per-tick kernel cost in half. The outer reader keeps
  // the System total live every tick via AppleSmartBattery; only the
  // component breakdown refreshes on the slower cadence.
  private let sampleInterval: TimeInterval = 2
  private var lastComputedSample: PlatformModeledPowerSample?
  private var lastComputedAt = Date.distantPast
  private var phaseTotals: [String: UInt64] = [:]

  public init?(updateInterval: Double) {
    maximumSampleInterval = max(5, updateInterval * 2)
    guard let api = Self.loadAPI(),
      let channels = Self.copyPowerChannels(api: api)
    else { return nil }

    var returnedChannels: UnsafeRawPointer?
    let channelsPtr = Unmanaged.passUnretained(channels).toOpaque()
    guard let subscription = api.createSubscription(nil, channelsPtr, &returnedChannels, 0, nil)
    else { return nil }

    self.api = api
    self.channels = channels
    self.subscription = subscription
    self.channelCache = Self.buildChannelCache(api: api, channels: channels)
  }

  deinit {
    Unmanaged<AnyObject>.fromOpaque(subscription).release()
    dlclose(api.handle)
  }

  public func clearModeledPowerHistory() {
    previousSample = nil
    lastComputedSample = nil
    lastComputedAt = .distantPast
  }

  public func readModeledPowerSample() -> PlatformModeledPowerSample? {
    phaseTotals.removeAll(keepingCapacity: true)
    let now = Date()
    if let lastComputedSample, now.timeIntervalSince(lastComputedAt) < sampleInterval {
      return lastComputedSample
    }

    let next = measurePhase("io_report.sample") {
      rawSample()
    }
    guard let next else { return nil }
    guard let previous = previousSample else {
      previousSample = next
      return nil
    }

    let elapsed = next.time.timeIntervalSince(previous.time)
    previousSample = next
    guard elapsed > 0, elapsed <= maximumSampleInterval else { return nil }

    let previousPtr = Unmanaged.passUnretained(previous.sample).toOpaque()
    let nextPtr = Unmanaged.passUnretained(next.sample).toOpaque()
    let deltaPtr = measurePhase("io_report.delta") {
      api.createSamplesDelta(previousPtr, nextPtr, nil)
    }
    guard let deltaPtr else { return nil }
    let delta = Unmanaged<CFDictionary>.fromOpaque(deltaPtr).takeRetainedValue()

    let sample = measurePhase("io_report.parse") {
      parsePower(delta: delta, elapsed: elapsed)
    }
    if let sample {
      lastComputedSample = sample
      lastComputedAt = now
    }
    return sample
  }

  public func consumePhaseTimings() -> [PlatformPowerPhaseTiming] {
    let result = phaseTotals.map {
      PlatformPowerPhaseTiming(name: $0.key, wallNanoseconds: $0.value)
    }
    phaseTotals.removeAll(keepingCapacity: true)
    return result
  }

  private func measurePhase<Value>(_ name: String, _ work: () -> Value) -> Value {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = work()
    phaseTotals[name, default: 0] += DispatchTime.now().uptimeNanoseconds - start
    return value
  }

  private func rawSample() -> (sample: CFDictionary, time: Date)? {
    let subscriptionPtr = UnsafeRawPointer(subscription)
    let channelsPtr = Unmanaged.passUnretained(channels).toOpaque()
    guard let samplePtr = api.createSamples(subscriptionPtr, channelsPtr, nil) else { return nil }
    let sample = Unmanaged<CFDictionary>.fromOpaque(samplePtr).takeRetainedValue()
    return (sample, Date())
  }

  private func parsePower(delta: CFDictionary, elapsed: TimeInterval) -> PlatformModeledPowerSample?
  {
    let key = "IOReportChannels" as CFString
    guard let arrayPtr = CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque())
    else { return nil }
    let array = Unmanaged<CFArray>.fromOpaque(arrayPtr).takeUnretainedValue()
    let count = CFArrayGetCount(array)

    var cpu = 0.0
    var gpu = 0.0
    var ane = 0.0
    var memory = 0.0
    var media = 0.0
    var energyDisplay = 0.0
    var dcpDisplay = 0.0
    var other = 0.0
    var found = false
    var debugRows: [String] = []

    for i in 0..<count {
      guard let item = CFArrayGetValueAtIndex(array, i) else { continue }

      let key = ChannelKey(
        driverID: api.channelGetDriverID(item), channelID: api.channelGetChannelID(item))
      let classified = classifiedChannel(item: item, key: key)
      guard let bucket = classified.bucket else { continue }

      let watts: Double?
      if bucket == .dcpDisplay {
        watts = microwattSecondsToWatts(api.simpleGetIntegerValue(item, 0), elapsed: elapsed)
      } else if let divisor = classified.rawUnitDivisor {
        watts = rawJoulesToWatts(
          api.simpleGetIntegerValue(item, 0), divisor: divisor, elapsed: elapsed)
      } else {
        watts = nil
      }
      guard let watts else { continue }

      switch bucket {
      case .cpu:
        cpu += watts
      case .gpu:
        gpu += watts
      case .ane:
        ane += watts
      case .memory:
        memory += watts
      case .media:
        media += watts
      case .dcsDisplay:
        energyDisplay += watts
      case .other:
        other += watts
      case .dcpDisplay:
        dcpDisplay += watts
      }
      found = true
      if debugEnabled {
        let group = Self.cfString(api.channelGetGroup(item))
        let subgroup = Self.cfString(api.channelGetSubGroup(item))
        let channel = Self.cfString(api.channelGetChannelName(item))
        if bucket == .dcpDisplay {
          debugRows.append(String(format: "%@/%@/%@: %.3f W", group, subgroup, channel, watts))
        } else {
          debugRows.append(String(format: "Energy Model/%@: %.3f W", channel, watts))
        }
      }
    }

    guard found else { return nil }
    let display = dcpDisplay > 0 ? dcpDisplay : energyDisplay
    guard platformValidatedPower(cpu + gpu + ane + memory + media + display + other) != nil else {
      return nil
    }
    if debugEnabled, !didLogDebug {
      didLogDebug = true
      fputs(
        (["mactop power channels:"] + debugRows.sorted()).joined(separator: "\n") + "\n", stderr)
    }

    return PlatformModeledPowerSample(
      cpu: cpu, gpu: gpu, ane: ane, memory: memory, media: media, display: display, other: other)
  }

  // Resolves a delta channel to its bucket and unit divisor. The cache is
  // keyed on provider and channel id and is always hit because the delta
  // contains exactly the subscribed channels. The string fallback keeps
  // modeled power working if a getter changes across a macOS update.
  private func classifiedChannel(item: UnsafeRawPointer, key: ChannelKey) -> (
    bucket: ModeledBucket?, rawUnitDivisor: Double?
  ) {
    if let entry = channelCache[key] {
      return (entry.bucket, entry.rawUnitDivisor)
    }
    let group = Self.cfString(api.channelGetGroup(item))
    let subgroup = Self.cfString(api.channelGetSubGroup(item))
    let channel = Self.cfString(api.channelGetChannelName(item))
    guard let bucket = Self.classifyChannel(group: group, subgroup: subgroup, name: channel) else {
      return (nil, nil)
    }
    let unit = Self.cfString(api.channelGetUnitLabel(item)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return (bucket, Self.rawUnitDivisor(unitLabel: unit))
  }

  private func rawJoulesToWatts(_ value: Int64, divisor: Double, elapsed: TimeInterval) -> Double? {
    platformValidatedPower(Double(value) / divisor / elapsed)
  }

  private func microwattSecondsToWatts(_ value: Int64, elapsed: TimeInterval) -> Double? {
    platformValidatedPower(Double(value) / 1_000_000 / elapsed)
  }

  private static func cfString(_ pointer: UnsafeRawPointer?) -> String {
    guard let pointer else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }

  private static func loadAPI() -> IOReportAPI? {
    let paths = [
      "/usr/lib/libIOReport.dylib",
      "libIOReport.dylib",
      "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
      "IOReport",
    ]

    guard let handle = paths.lazy.compactMap({ dlopen($0, RTLD_LAZY) }).first else { return nil }

    guard
      let copyChannelsInGroup = symbol(
        handle, "IOReportCopyChannelsInGroup", as: IOReportAPI.CopyChannelsInGroup.self),
      let createSubscription = symbol(
        handle, "IOReportCreateSubscription", as: IOReportAPI.CreateSubscription.self),
      let createSamples = symbol(
        handle, "IOReportCreateSamples", as: IOReportAPI.CreateSamples.self),
      let createSamplesDelta = symbol(
        handle, "IOReportCreateSamplesDelta", as: IOReportAPI.CreateSamplesDelta.self),
      let mergeChannels = symbol(
        handle, "IOReportMergeChannels", as: IOReportAPI.MergeChannels.self),
      let channelGetGroup = symbol(
        handle, "IOReportChannelGetGroup", as: IOReportAPI.ChannelString.self),
      let channelGetSubGroup = symbol(
        handle, "IOReportChannelGetSubGroup", as: IOReportAPI.ChannelString.self),
      let channelGetChannelName = symbol(
        handle, "IOReportChannelGetChannelName", as: IOReportAPI.ChannelString.self),
      let channelGetChannelID = symbol(
        handle, "IOReportChannelGetChannelID", as: IOReportAPI.ChannelID.self),
      let channelGetDriverID = symbol(
        handle, "IOReportChannelGetDriverID", as: IOReportAPI.ChannelID.self),
      let channelGetUnitLabel = symbol(
        handle, "IOReportChannelGetUnitLabel", as: IOReportAPI.ChannelString.self),
      let simpleGetIntegerValue = symbol(
        handle, "IOReportSimpleGetIntegerValue", as: IOReportAPI.SimpleIntegerValue.self)
    else {
      dlclose(handle)
      return nil
    }

    return IOReportAPI(
      handle: handle,
      copyChannelsInGroup: copyChannelsInGroup,
      createSubscription: createSubscription,
      createSamples: createSamples,
      createSamplesDelta: createSamplesDelta,
      mergeChannels: mergeChannels,
      channelGetGroup: channelGetGroup,
      channelGetSubGroup: channelGetSubGroup,
      channelGetChannelName: channelGetChannelName,
      channelGetChannelID: channelGetChannelID,
      channelGetDriverID: channelGetDriverID,
      channelGetUnitLabel: channelGetUnitLabel,
      simpleGetIntegerValue: simpleGetIntegerValue
    )
  }

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type)
    -> T?
  {
    guard let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  private static func copyPowerChannels(api: IOReportAPI) -> CFMutableDictionary? {
    let groups = [
      (group: "Energy Model", subgroup: nil as String?),
      (group: "DCP", subgroup: nil as String?),
      (group: "DCPEXT0", subgroup: nil as String?),
      (group: "DCPEXT1", subgroup: nil as String?),
    ]
    var dictionaries: [CFDictionary] = []
    for entry in groups {
      let group = entry.group as CFString
      let groupPtr = Unmanaged.passUnretained(group).toOpaque()
      let subgroup = entry.subgroup.map { $0 as CFString }
      let subgroupPtr = subgroup.map { Unmanaged.passUnretained($0).toOpaque() }
      guard let rawPtr = api.copyChannelsInGroup(groupPtr, subgroupPtr, 0, 0, 0) else { continue }
      dictionaries.append(Unmanaged<CFDictionary>.fromOpaque(rawPtr).takeRetainedValue())
    }

    guard let first = dictionaries.first,
      let channels = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault, CFDictionaryGetCount(first), first)
    else { return nil }

    let channelsPtr = Unmanaged.passUnretained(channels).toOpaque()
    for dictionary in dictionaries.dropFirst() {
      api.mergeChannels(channelsPtr, Unmanaged.passUnretained(dictionary).toOpaque(), nil)
    }

    let key = "IOReportChannels" as CFString
    guard let arrayPtr = CFDictionaryGetValue(channels, Unmanaged.passUnretained(key).toOpaque())
    else { return nil }
    let array = Unmanaged<CFArray>.fromOpaque(arrayPtr).takeUnretainedValue()
    let count = CFArrayGetCount(array)

    // Sampling every channel in the Energy Model and DCP groups is the
    // dominant modeled-power cost. Subscribe only to channels the parser
    // classifies so the kernel samples and the per-tick parse both see a
    // small fixed set. classifyChannel is the same rule parsePower uses, so
    // a renamed channel is ignored exactly as it was before filtering.
    var kept: [UnsafeRawPointer?] = []
    kept.reserveCapacity(count)
    for i in 0..<count {
      guard let item = CFArrayGetValueAtIndex(array, i) else { continue }
      let group = cfString(api.channelGetGroup(item))
      let subgroup = cfString(api.channelGetSubGroup(item))
      let name = cfString(api.channelGetChannelName(item))
      if classifyChannel(group: group, subgroup: subgroup, name: name) != nil {
        kept.append(item)
      }
    }
    guard !kept.isEmpty else { return nil }

    var callbacks = kCFTypeArrayCallBacks
    guard
      let filteredArray = kept.withUnsafeMutableBufferPointer({ buffer in
        CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, &callbacks)
      })
    else { return nil }
    CFDictionarySetValue(
      channels, Unmanaged.passUnretained(key).toOpaque(),
      Unmanaged.passUnretained(filteredArray).toOpaque())
    return channels
  }

  // Precomputes the per-channel bucket and unit divisor so parsePower avoids
  // bridging group/subgroup/channel/unit strings on every tick. The cache is
  // built from the same filtered channel set the subscription uses, so delta
  // channels always hit it.
  private static func buildChannelCache(api: IOReportAPI, channels: CFMutableDictionary)
    -> [ChannelKey: ChannelEntry]
  {
    let key = "IOReportChannels" as CFString
    guard let arrayPtr = CFDictionaryGetValue(channels, Unmanaged.passUnretained(key).toOpaque())
    else { return [:] }
    let array = Unmanaged<CFArray>.fromOpaque(arrayPtr).takeUnretainedValue()
    let count = CFArrayGetCount(array)
    var cache: [ChannelKey: ChannelEntry] = [:]
    cache.reserveCapacity(count)
    for i in 0..<count {
      guard let item = CFArrayGetValueAtIndex(array, i) else { continue }
      let group = Self.cfString(api.channelGetGroup(item))
      let subgroup = Self.cfString(api.channelGetSubGroup(item))
      let channel = Self.cfString(api.channelGetChannelName(item))
      guard let bucket = classifyChannel(group: group, subgroup: subgroup, name: channel) else {
        continue
      }
      let divisor: Double?
      if bucket == .dcpDisplay {
        divisor = nil
      } else {
        let unit = Self.cfString(api.channelGetUnitLabel(item)).trimmingCharacters(
          in: .whitespacesAndNewlines)
        divisor = rawUnitDivisor(unitLabel: unit)
      }
      let key = ChannelKey(
        driverID: api.channelGetDriverID(item), channelID: api.channelGetChannelID(item))
      cache[key] = ChannelEntry(bucket: bucket, rawUnitDivisor: divisor)
    }
    return cache
  }

  private static func rawUnitDivisor(unitLabel: String) -> Double? {
    switch unitLabel {
    case "mJ": return 1_000
    case "uJ": return 1_000_000
    case "nJ": return 1_000_000_000
    default: return nil
    }
  }
}

public final class PlatformBatteryPowerReader {
  private let debugEnabled = ProcessInfo.processInfo.environment["MACTOP_DEBUG_BATTERY"] == "1"
  private var didLogDebug = false

  public init() {}

  public func readPlatformBatteryChargingDetail() -> PlatformBatteryChargingDetail? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    // Single-key reads avoid materializing the entire AppleSmartBattery
    // property tree (~60 keys, ~0.6 ms). Each key we need costs
    // ~0.005-0.015 ms, so the whole read is ~0.1 ms. Values are
    // identical to the full-tree read.
    let telemetry = readProperty(service, "PowerTelemetryData") as? [String: Any]
    let externalConnected =
      bool(readProperty(service, "ExternalConnected"))
      ?? bool(readProperty(service, "AppleRawExternalConnected"))
      ?? false
    let isCharging = bool(readProperty(service, "IsCharging")) ?? false
    let isFullyCharged = bool(readProperty(service, "FullyCharged")) ?? false
    let voltage =
      numeric(readProperty(service, "Voltage"))
      ?? numeric(readProperty(service, "AppleRawBatteryVoltage"))
      ?? 0
    let amperage =
      numeric(readProperty(service, "InstantAmperage"))
      ?? numeric(readProperty(service, "Amperage"))
      ?? 0

    if debugEnabled, !didLogDebug {
      didLogDebug = true
      var rows: [String] = ["mactop battery telemetry:"]
      if let telemetry {
        for (k, v) in telemetry.sorted(by: { $0.key < $1.key }) {
          rows.append("  \(k): \(v)")
        }
      } else {
        rows.append("  (PowerTelemetryData unavailable)")
        for key in [
          "Voltage", "AppleRawBatteryVoltage", "InstantAmperage", "Amperage", "IsCharging",
          "ExternalConnected",
        ] {
          if let v = readProperty(service, key) { rows.append("  \(key): \(v)") }
        }
      }
      fputs(rows.joined(separator: "\n") + "\n", stderr)
    }

    let systemWatts = systemWatts(telemetry: telemetry, voltage: voltage, amperage: amperage)
    let batteryWatts = numeric(telemetry?["BatteryPower"]).flatMap { batteryPowerWatts($0) }
    let batteryFraction = batteryFraction(
      current: numeric(readProperty(service, "CurrentCapacity"))
        ?? numeric(readProperty(service, "AppleRawCurrentCapacity")),
      capacity: numeric(readProperty(service, "MaxCapacity"))
        ?? numeric(readProperty(service, "AppleRawMaxCapacity")))
    let adapter = adapterDetails(service)

    return PlatformBatteryChargingDetail(
      externalConnected: externalConnected,
      isCharging: isCharging,
      isFullyCharged: isFullyCharged,
      adapterName: adapter.name,
      adapterWatts: adapter.watts,
      inputWatts: systemWatts,
      batteryWatts: batteryWatts,
      batteryFraction: batteryFraction,
      wallWatts: numeric(telemetry?["WallEnergyEstimate"]).map { $0 / 1_000 },
      energyConsumedWatts: numeric(telemetry?["SystemEnergyConsumed"]).flatMap {
        platformValidatedPower(wattsFromMilliwatts($0))
      }
    )
  }

  private func readProperty(_ service: io_service_t, _ key: String) -> Any? {
    guard
      let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
    else { return nil }
    return value.takeRetainedValue()
  }

  private func systemWatts(telemetry: [String: Any]?, voltage: Double, amperage: Double) -> Double?
  {
    if let telemetry {
      if let power = numeric(telemetry["SystemPowerIn"]), power > 0 {
        return platformValidatedPower(wattsFromMilliwatts(power))
      }
      if let current = numeric(telemetry["SystemCurrentIn"]),
        let voltage = numeric(telemetry["SystemVoltageIn"]),
        current > 0, voltage > 0
      {
        return platformValidatedPower(
          wattsFromMillivoltsAndMilliamps(voltage: voltage, amperage: current))
      }
      if let power = numeric(telemetry["SystemLoad"]), power > 0 {
        return platformValidatedPower(wattsFromMilliwatts(power))
      }
      if let power = numeric(telemetry["BatteryPower"]), power != 0 {
        return platformValidatedPower(abs(wattsFromMilliwatts(power)))
      }
    }

    guard voltage > 0, amperage != 0 else { return nil }
    return platformValidatedPower(
      wattsFromMillivoltsAndMilliamps(voltage: voltage, amperage: amperage))
  }

  private func adapterDetails(_ service: io_service_t) -> (name: String?, watts: Double?) {
    if let details = readProperty(service, "AdapterDetails") as? [String: Any] {
      return (details["Name"] as? String, numeric(details["Watts"]))
    }
    if let array = readProperty(service, "AppleRawAdapterDetails") as? [[String: Any]],
      let first = array.first
    {
      return (first["Name"] as? String, numeric(first["Watts"]))
    }
    return (nil, nil)
  }

  private func batteryPowerWatts(_ milliwatts: Double) -> Double? {
    guard milliwatts != 0 else { return nil }
    guard abs(milliwatts) < 1_000_000 else { return nil }
    return wattsFromMilliwatts(milliwatts)
  }

  private func wattsFromMilliwatts(_ milliwatts: Double) -> Double {
    milliwatts / 1_000
  }

  private func wattsFromMillivoltsAndMilliamps(voltage: Double, amperage: Double) -> Double {
    abs(voltage * amperage) / 1_000_000
  }

  private func batteryFraction(current: Double?, capacity: Double?) -> Double? {
    guard let current, let capacity, capacity > 0 else { return nil }
    return min(1, max(0, current / capacity))
  }

  private func bool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      return value
    case let number as NSNumber:
      return number.boolValue
    default:
      return nil
    }
  }

  private func numeric(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
      return number.doubleValue
    case let value as Int:
      return Double(value)
    case let value as Int64:
      return Double(value)
    case let value as UInt64:
      return Double(value)
    case let value as Double:
      return value
    default:
      return nil
    }
  }
}
