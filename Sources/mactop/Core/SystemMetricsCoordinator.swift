import Foundation

// Coordinates timed reads from core metric sources and delivers typed snapshots
// to the UI without importing AppKit or owning presentation state.
// Reader state and coordinator flags are confined to their respective serial
// queues. The unchecked conformance makes that ownership boundary explicit to
// Swift's concurrency checker when DispatchQueue invokes @Sendable closures.
public final class SystemMetricsCoordinator: @unchecked Sendable {
  private let cpuReader: CPUUsageReader
  private let ramReader: RAMUsageReader
  private let gpuReader: GPUUsageReader
  private let powerReader: PowerTelemetryReader
  private let networkReader: NetworkInterfaceReader
  private let coordinatorQueue = DispatchQueue(
    label: "mactop.system-metrics-coordinator", qos: .utility)
  private let cpuQueue = DispatchQueue(label: "mactop.cpu-metrics-reader", qos: .utility)
  private let ramQueue = DispatchQueue(label: "mactop.ram-metrics-reader", qos: .utility)
  private let gpuQueue = DispatchQueue(label: "mactop.gpu-metrics-reader", qos: .utility)
  private let powerQueue = DispatchQueue(label: "mactop.power-metrics-reader", qos: .utility)
  private let networkQueue = DispatchQueue(label: "mactop.network-metrics-reader", qos: .utility)
  private let onPower: @MainActor @Sendable (PowerUsageDetail) -> Void
  private var timers: [DispatchSourceTimer] = []
  private var cpuReadInFlight = false
  private var ramReadInFlight = false
  private var gpuReadInFlight = false
  private var powerReadInFlight = false
  private var networkReadInFlight = false
  private var historyEnabled = Array(repeating: false, count: 5)
  private var isPaused = false
  private var isSleeping = false
  private var dataEpoch = 0

  public init(
    config: MactopConfig,
    onCPU: @escaping @MainActor @Sendable (CPUUsageDetail) -> Void,
    onRAM: @escaping @MainActor @Sendable (RAMUsageDetail) -> Void,
    onGPU: @escaping @MainActor @Sendable (GPUUsageDetail) -> Void,
    onPower: @escaping @MainActor @Sendable (PowerUsageDetail) -> Void,
    onNetwork: @escaping @MainActor @Sendable (NetworkUsageDetail) -> Void
  ) {

    let interval = normalizedMetricUpdateInterval(config.updateInterval)
    cpuReader = CPUUsageReader(updateInterval: interval)
    ramReader = RAMUsageReader(updateInterval: interval)
    gpuReader = GPUUsageReader(updateInterval: interval)
    powerReader = PowerTelemetryReader(updateInterval: interval)
    networkReader = NetworkInterfaceReader(updateInterval: interval)
    self.onPower = onPower

    let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
    let ms = max(1, Int(interval * 1000))
    let repeating = DispatchTimeInterval.milliseconds(ms)
    timer.schedule(deadline: .now() + repeating, repeating: repeating, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.refreshAll(onCPU: onCPU, onRAM: onRAM, onGPU: onGPU, onNetwork: onNetwork)
    }
    timer.resume()
    timers = [timer]
  }

  private func refreshAll(
    onCPU: @escaping @MainActor @Sendable (CPUUsageDetail) -> Void,
    onRAM: @escaping @MainActor @Sendable (RAMUsageDetail) -> Void,
    onGPU: @escaping @MainActor @Sendable (GPUUsageDetail) -> Void,
    onNetwork: @escaping @MainActor @Sendable (NetworkUsageDetail) -> Void
  ) {
    guard !isPaused, !isSleeping else { return }

    let includeNetworkHistory = historyEnabled[0]
    let includeCPUHistory = historyEnabled[1]
    let includeRAMHistory = historyEnabled[2]
    let includeGPUHistory = historyEnabled[3]
    let includePowerHistory = historyEnabled[4]
    let epoch = dataEpoch

    if !cpuReadInFlight {
      cpuReadInFlight = true
      cpuQueue.async { [weak self] in
        guard let self else { return }
        let cpu = self.cpuReader.readCPUUsageDetail(includeHistory: includeCPUHistory)
        self.coordinatorQueue.async {
          self.cpuReadInFlight = false
          guard !self.isPaused, self.dataEpoch == epoch else { return }
          DispatchQueue.main.async { onCPU(cpu) }
        }
      }
    }

    if !ramReadInFlight {
      ramReadInFlight = true
      ramQueue.async { [weak self] in
        guard let self else { return }
        let ram = self.ramReader.readRAMUsageDetail(includeHistory: includeRAMHistory)
        self.coordinatorQueue.async {
          self.ramReadInFlight = false
          guard !self.isPaused, self.dataEpoch == epoch else { return }
          DispatchQueue.main.async { onRAM(ram) }
        }
      }
    }

    if !gpuReadInFlight {
      gpuReadInFlight = true
      gpuQueue.async { [weak self] in
        guard let self else { return }
        let gpu = self.gpuReader.readGPUUsageDetail(includeHistory: includeGPUHistory)
        self.coordinatorQueue.async {
          self.gpuReadInFlight = false
          guard !self.isPaused, self.dataEpoch == epoch else { return }
          DispatchQueue.main.async { onGPU(gpu) }
        }
      }
    }

    if !powerReadInFlight {
      powerReadInFlight = true
      powerQueue.async { [weak self] in
        guard let self else { return }
        let power = self.powerReader.readPowerUsageDetail(includeHistory: includePowerHistory)
        self.coordinatorQueue.async {
          self.powerReadInFlight = false
          guard !self.isPaused, self.dataEpoch == epoch else { return }
          DispatchQueue.main.async { self.onPower(power) }
        }
      }
    }

    if !networkReadInFlight {
      networkReadInFlight = true
      networkQueue.async { [weak self] in
        guard let self else { return }
        let network = self.networkReader.readNetworkUsageDetail(
          includeHistory: includeNetworkHistory)
        self.coordinatorQueue.async {
          self.networkReadInFlight = false
          guard !self.isPaused, self.dataEpoch == epoch else { return }
          DispatchQueue.main.async { onNetwork(network) }
        }
      }
    }
  }

  public func setHistoryEnabled(_ enabled: Bool, for index: Int) {
    guard historyEnabled.indices.contains(index) else { return }
    coordinatorQueue.async { [weak self] in
      self?.historyEnabled[index] = enabled
    }
  }

  public func setAllHistoryDisabled() {
    coordinatorQueue.async { [weak self] in
      self?.historyEnabled = Array(repeating: false, count: 5)
    }
  }

  public func setPaused(_ paused: Bool) {
    coordinatorQueue.async { [weak self] in
      guard let self else { return }
      self.isPaused = paused
      self.dataEpoch += 1
      if paused {
        self.historyEnabled = Array(repeating: false, count: 5)
        self.clearReaderData()
      }
    }
  }

  private func clearReaderData() {
    cpuQueue.async { [weak self] in self?.cpuReader.clearCPUUsageHistory() }
    ramQueue.async { [weak self] in self?.ramReader.clearRAMUsageHistory() }
    gpuQueue.async { [weak self] in self?.gpuReader.clearGPUUsageHistory() }
    powerQueue.async { [weak self] in self?.powerReader.clearPowerUsageHistory() }
    networkQueue.async { [weak self] in self?.networkReader.clearNetworkUsageHistory() }
  }

  public func powerSourceChanged() {
    powerQueue.async { [weak self] in
      guard let self else { return }
      self.powerReader.invalidateChargingCache()
    }
  }

  public func systemWillSleep() {
    coordinatorQueue.async { [weak self] in
      self?.isSleeping = true
    }
  }

  public func systemDidWake() {
    coordinatorQueue.async { [weak self] in
      guard let self else { return }
      self.isSleeping = false
      self.powerQueue.async { [weak self] in
        self?.powerReader.resetAfterWake()
      }
    }
  }

  deinit {
    timers.forEach { $0.cancel() }
  }
}
