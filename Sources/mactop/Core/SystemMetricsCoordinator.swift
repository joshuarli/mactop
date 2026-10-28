import Foundation
import Synchronization

public final class SystemMetricsCoordinator: Sendable {
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
  private let timers: [DispatchSourceTimer]
  private struct State: Sendable {
    var cpuReadInFlight = false
    var ramReadInFlight = false
    var gpuReadInFlight = false
    var powerReadInFlight = false
    var networkReadInFlight = false
    var historyEnabled = Array(repeating: false, count: 5)
    var isPaused = false
    var isSleeping = false
    var dataEpoch = 0
  }
  private let state = Mutex(State())

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
    timers = [timer]
    let ms = max(1, Int(interval * 1000))
    let repeating = DispatchTimeInterval.milliseconds(ms)
    timer.schedule(deadline: .now() + repeating, repeating: repeating, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.refreshAll(onCPU: onCPU, onRAM: onRAM, onGPU: onGPU, onNetwork: onNetwork)
    }
    timer.resume()
  }

  private func refreshAll(
    onCPU: @escaping @MainActor @Sendable (CPUUsageDetail) -> Void,
    onRAM: @escaping @MainActor @Sendable (RAMUsageDetail) -> Void,
    onGPU: @escaping @MainActor @Sendable (GPUUsageDetail) -> Void,
    onNetwork: @escaping @MainActor @Sendable (NetworkUsageDetail) -> Void
  ) {
    struct Kick {
      var cpu = false
      var ram = false
      var gpu = false
      var power = false
      var network = false
      var includeHistory: [Bool] = []
      var epoch = 0
    }
    let kick = state.withLock { s -> Kick? in
      guard !s.isPaused, !s.isSleeping else { return nil }
      var kick = Kick(includeHistory: s.historyEnabled, epoch: s.dataEpoch)
      if !s.cpuReadInFlight { s.cpuReadInFlight = true; kick.cpu = true }
      if !s.ramReadInFlight { s.ramReadInFlight = true; kick.ram = true }
      if !s.gpuReadInFlight { s.gpuReadInFlight = true; kick.gpu = true }
      if !s.powerReadInFlight { s.powerReadInFlight = true; kick.power = true }
      if !s.networkReadInFlight { s.networkReadInFlight = true; kick.network = true }
      return kick
    }
    guard let kick else { return }

    let includeNetworkHistory = kick.includeHistory[0]
    let includeCPUHistory = kick.includeHistory[1]
    let includeRAMHistory = kick.includeHistory[2]
    let includeGPUHistory = kick.includeHistory[3]
    let includePowerHistory = kick.includeHistory[4]
    let epoch = kick.epoch

    if kick.cpu {
      cpuQueue.async { [weak self] in
        guard let self else { return }
        let cpu = self.cpuReader.readCPUUsageDetail(includeHistory: includeCPUHistory)
        self.coordinatorQueue.async {
          let proceed = self.state.withLock { s -> Bool in
            s.cpuReadInFlight = false
            return !s.isPaused && s.dataEpoch == epoch
          }
          guard proceed else { return }
          DispatchQueue.main.async { onCPU(cpu) }
        }
      }
    }

    if kick.ram {
      ramQueue.async { [weak self] in
        guard let self else { return }
        let ram = self.ramReader.readRAMUsageDetail(includeHistory: includeRAMHistory)
        self.coordinatorQueue.async {
          let proceed = self.state.withLock { s -> Bool in
            s.ramReadInFlight = false
            return !s.isPaused && s.dataEpoch == epoch
          }
          guard proceed else { return }
          DispatchQueue.main.async { onRAM(ram) }
        }
      }
    }

    if kick.gpu {
      gpuQueue.async { [weak self] in
        guard let self else { return }
        let gpu = self.gpuReader.readGPUUsageDetail(includeHistory: includeGPUHistory)
        self.coordinatorQueue.async {
          let proceed = self.state.withLock { s -> Bool in
            s.gpuReadInFlight = false
            return !s.isPaused && s.dataEpoch == epoch
          }
          guard proceed else { return }
          DispatchQueue.main.async { onGPU(gpu) }
        }
      }
    }

    if kick.power {
      powerQueue.async { [weak self] in
        guard let self else { return }
        let power = self.powerReader.readPowerUsageDetail(includeHistory: includePowerHistory)
        self.coordinatorQueue.async {
          let proceed = self.state.withLock { s -> Bool in
            s.powerReadInFlight = false
            return !s.isPaused && s.dataEpoch == epoch
          }
          guard proceed else { return }
          DispatchQueue.main.async { self.onPower(power) }
        }
      }
    }

    if kick.network {
      networkQueue.async { [weak self] in
        guard let self else { return }
        let network = self.networkReader.readNetworkUsageDetail(
          includeHistory: includeNetworkHistory)
        self.coordinatorQueue.async {
          let proceed = self.state.withLock { s -> Bool in
            s.networkReadInFlight = false
            return !s.isPaused && s.dataEpoch == epoch
          }
          guard proceed else { return }
          DispatchQueue.main.async { onNetwork(network) }
        }
      }
    }
  }

  public func setHistoryEnabled(_ enabled: Bool, for index: Int) {
    coordinatorQueue.async { [weak self] in
      self?.state.withLock { s in
        guard s.historyEnabled.indices.contains(index) else { return }
        s.historyEnabled[index] = enabled
      }
    }
  }

  public func setAllHistoryDisabled() {
    coordinatorQueue.async { [weak self] in
      self?.state.withLock { s in
        s.historyEnabled = Array(repeating: false, count: 5)
      }
    }
  }

  public func setPaused(_ paused: Bool) {
    coordinatorQueue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        s.isPaused = paused
        s.dataEpoch += 1
        if paused {
          s.historyEnabled = Array(repeating: false, count: 5)
        }
      }
      if paused {
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
      self?.state.withLock { $0.isSleeping = true }
    }
  }

  public func systemDidWake() {
    coordinatorQueue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { $0.isSleeping = false }
      self.powerQueue.async { [weak self] in
        self?.powerReader.resetAfterWake()
      }
    }
  }

  deinit {
    timers.forEach { $0.cancel() }
  }
}
