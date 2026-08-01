import Foundation
import mactopPlatform

// Combines AppleSmartBattery system-power telemetry with modeled IOReport component
// energy so the UI can distinguish whole-machine draw from the SoC subtotal.

public struct PowerUsageDetail: Sendable {
  public var total: Double?
  public var system: Double?
  public var modeled: Double?
  public var charging: BatteryChargingDetail?
  public var cpu: Double?
  public var gpu: Double?
  public var ane: Double?
  public var memory: Double?
  public var media: Double?
  public var display: Double?
  public var other: Double?
  public var history: [MetricHistoryPoint<PowerHistorySample>]
}

// Apple power telemetry and IOReport counters can briefly contain impossible
// values while the system is waking. Reject them instead of turning a reset
// or stale counter into a visible multi-kilowatt reading.
let maximumReasonablePowerWatts = 2_000.0

func validatedPowerReadingWatts(_ watts: Double) -> Double? {
  guard watts.isFinite, watts >= 0, watts <= maximumReasonablePowerWatts else { return nil }
  return watts
}

public struct PowerHistorySample: Equatable, Sendable {
  public var total: Double
  public var modeled: Double
  public var cpu: Double
  public var gpu: Double
  public var ane: Double
  public var memory: Double
  public var media: Double
  public var display: Double
  public var other: Double

  public func smoothed(after previous: PowerHistorySample?) -> PowerHistorySample {
    guard let previous else { return self }
    return PowerHistorySample(
      total: smoothMetricValue(total, previous: previous.total),
      modeled: smoothMetricValue(modeled, previous: previous.modeled),
      cpu: smoothMetricValue(cpu, previous: previous.cpu),
      gpu: smoothMetricValue(gpu, previous: previous.gpu),
      ane: smoothMetricValue(ane, previous: previous.ane),
      memory: smoothMetricValue(memory, previous: previous.memory),
      media: smoothMetricValue(media, previous: previous.media),
      display: smoothMetricValue(display, previous: previous.display),
      other: smoothMetricValue(other, previous: previous.other)
    )
  }
}

public struct BatteryChargingDetail: Sendable {
  public var externalConnected: Bool
  public var isCharging: Bool
  public var isFullyCharged: Bool
  public var adapterName: String?
  public var adapterWatts: Double?
  public var inputWatts: Double?
  public var batteryWatts: Double?
  public var batteryFraction: Double?
  public var wallWatts: Double?
  // SystemEnergyConsumed from IOKit telemetry: actual CPU/GPU/etc consumption,
  // excludes battery charging power. Preferred over inputWatts for system load display.
  public var energyConsumedWatts: Double?
  public var chargerWatts: Double? {
    guard let inputWatts else { return nil }
    return inputWatts + max(batteryWatts ?? 0, 0)
  }
  public var consumptionWatts: Double? {
    energyConsumedWatts ?? inputWatts
  }
  public var status: String {
    if !externalConnected { return "Battery" }
    if isCharging { return "Charging" }
    if isFullyCharged { return "Full" }
    return "Connected"
  }
}

public final class PowerTelemetryReader: @unchecked Sendable {
  private struct PowerSample {
    var cpu: Double
    var gpu: Double
    var ane: Double
    var memory: Double
    var media: Double
    var display: Double
    var other: Double
    var system: Double?
    var hasModeled: Bool
    var modeled: Double { cpu + gpu + ane + memory + media + display + other }
    var total: Double { system ?? modeled }
    var historySample: PowerHistorySample? {
      guard hasModeled else { return nil }
      return PowerHistorySample(
        total: total,
        modeled: modeled,
        cpu: cpu,
        gpu: gpu,
        ane: ane,
        memory: memory,
        media: media,
        display: display,
        other: other
      )
    }
  }

  private struct PowerHistory {
    private var samples: [MetricHistoryPoint<PowerHistorySample>]
    private var nextIndex = 0
    private var count = 0
    private var smoothed: PowerHistorySample?

    init(capacity: Int) {
      let capacity = max(capacity, 1)
      samples = Array(
        repeating: MetricHistoryPoint(
          date: .distantPast,
          value: PowerHistorySample(
            total: 0, modeled: 0, cpu: 0, gpu: 0, ane: 0, memory: 0, media: 0, display: 0, other: 0)
        ), count: capacity)
    }

    mutating func removeAll() {
      samples = Array(
        repeating: MetricHistoryPoint(
          date: .distantPast,
          value: PowerHistorySample(
            total: 0, modeled: 0, cpu: 0, gpu: 0, ane: 0, memory: 0, media: 0, display: 0, other: 0)
        ), count: samples.count)
      nextIndex = 0
      count = 0
      smoothed = nil
    }

    mutating func append(_ sample: PowerSample, at date: Date) {
      guard let rawHistorySample = sample.historySample else { return }
      let historySample = rawHistorySample.smoothed(after: smoothed)
      smoothed = historySample
      samples[nextIndex] = MetricHistoryPoint(date: date, value: historySample)
      nextIndex = (nextIndex + 1) % samples.count
      count = min(count + 1, samples.count)
    }

    var values: [MetricHistoryPoint<PowerHistorySample>] {
      guard count > 0 else { return [] }
      let cutoff = Date().addingTimeInterval(-metricGraphHistoryWindow)
      var output: [MetricHistoryPoint<PowerHistorySample>] = []
      output.reserveCapacity(count)
      let start = count == samples.count ? nextIndex : 0
      for offset in 0..<count {
        let index = (start + offset) % samples.count
        if samples[index].date >= cutoff {
          output.append(samples[index])
        }
      }
      return output
    }
  }

  private var modeledPowerReaderAttempted = false
  private var modeledPowerReader: PlatformModeledPowerReader?
  private let batteryPowerReader = PlatformBatteryPowerReader()
  private var history: PowerHistory
  private var systemOverhead: Double?
  private var lastRawSystem: Double?
  private var cachedCharging: BatteryChargingDetail?
  private var rawSystemLastRead = Date.distantPast
  private var current: PowerSample?
  private let chargingCacheInterval: TimeInterval = 2
  private let updateInterval: Double
  private let phaseRecorder: CoreReadPhaseRecorder?

  public init(updateInterval: Double = 1, phaseRecorder: CoreReadPhaseRecorder? = nil) {
    self.updateInterval = updateInterval
    self.phaseRecorder = phaseRecorder
    history = PowerHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))
  }

  public func clearPowerUsageHistory() {
    history.removeAll()
    resetAfterWake()
  }

  public func resetAfterWake() {
    // Preserve history so the chart can show the sleep interval after wake.
    systemOverhead = nil
    lastRawSystem = nil
    current = nil
    cachedCharging = nil
    rawSystemLastRead = .distantPast
    modeledPowerReader?.clearModeledPowerHistory()
  }

  public func invalidateChargingCache() {
    cachedCharging = nil
    rawSystemLastRead = .distantPast
    lastRawSystem = nil
    systemOverhead = nil
  }

  public func readPowerUsageDetail(includeHistory: Bool = false) -> PowerUsageDetail {
    if !modeledPowerReaderAttempted {
      modeledPowerReader = PlatformModeledPowerReader(updateInterval: updateInterval)
      modeledPowerReaderAttempted = true
    }

    let charging = measureCoreReadPhase(phaseRecorder, name: "battery.read") {
      readChargingDetail()
    }
    let rawSystem = charging?.consumptionWatts
    let modeledSample = modeledPowerReader?.readModeledPowerSample()
    if let phaseRecorder, let modeledPowerReader {
      for phase in modeledPowerReader.consumePhaseTimings() {
        phaseRecorder.record(name: phase.name, wallNanoseconds: phase.wallNanoseconds)
      }
    }
    if let sample = modeledSample {
      if let rawSystem, lastRawSystem != rawSystem || systemOverhead == nil {
        systemOverhead = max(0, rawSystem - sample.modeled)
        lastRawSystem = rawSystem
      }
      let system = systemOverhead.map { sample.modeled + $0 } ?? rawSystem
      current = PowerSample(
        cpu: sample.cpu,
        gpu: sample.gpu,
        ane: sample.ane,
        memory: sample.memory,
        media: sample.media,
        display: sample.display,
        other: sample.other,
        system: system,
        hasModeled: true
      )
    } else if let current, current.system != rawSystem {
      self.current = PowerSample(
        cpu: current.cpu,
        gpu: current.gpu,
        ane: current.ane,
        memory: current.memory,
        media: current.media,
        display: current.display,
        other: current.other,
        system: rawSystem,
        hasModeled: current.hasModeled
      )
    } else if current == nil, rawSystem != nil {
      current = PowerSample(
        cpu: 0, gpu: 0, ane: 0, memory: 0, media: 0, display: 0, other: 0, system: rawSystem,
        hasModeled: false)
    }

    if let sample = current {
      if let phaseRecorder {
        phaseRecorder.measure("history.append") {
          history.append(sample, at: Date())
        }
      } else {
        history.append(sample, at: Date())
      }
    }

    let hasModeled = current?.hasModeled == true
    let historyValues =
      includeHistory
      ? measureCoreReadPhase(phaseRecorder, name: "history.snapshot") { history.values }
      : []
    return PowerUsageDetail(
      total: current?.total,
      system: current?.system,
      modeled: hasModeled ? current?.modeled : nil,
      charging: charging,
      cpu: hasModeled ? current?.cpu : nil,
      gpu: hasModeled ? current?.gpu : nil,
      ane: hasModeled ? current?.ane : nil,
      memory: hasModeled ? current?.memory : nil,
      media: hasModeled ? current?.media : nil,
      display: hasModeled ? current?.display : nil,
      other: hasModeled ? current?.other : nil,
      history: historyValues
    )
  }

  private func readChargingDetail() -> BatteryChargingDetail? {
    let now = Date()
    if cachedCharging == nil || now.timeIntervalSince(rawSystemLastRead) >= chargingCacheInterval {
      cachedCharging = batteryPowerReader.readPlatformBatteryChargingDetail().map { value in
        BatteryChargingDetail(
          externalConnected: value.externalConnected,
          isCharging: value.isCharging,
          isFullyCharged: value.isFullyCharged,
          adapterName: value.adapterName,
          adapterWatts: value.adapterWatts,
          inputWatts: value.inputWatts,
          batteryWatts: value.batteryWatts,
          batteryFraction: value.batteryFraction,
          wallWatts: value.wallWatts,
          energyConsumedWatts: value.energyConsumedWatts
        )
      }
      rawSystemLastRead = now
    }
    return cachedCharging
  }
}
