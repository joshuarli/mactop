import Foundation
import Synchronization

public enum MetricKind: Sendable, CaseIterable {
  case network
  case cpu
  case ram
  case gpu
}

public final class SystemMetricsCoordinator: Sendable {
  private let cpuReader: CPUUsageReader
  private let ramReader: RAMUsageReader
  private let gpuReader: GPUUsageReader
  private let networkReader: NetworkInterfaceReader
  private let coordinatorQueue = DispatchQueue(
    label: "mactop.system-metrics-coordinator", qos: .utility)
  private let cpuQueue = DispatchQueue(label: "mactop.cpu-metrics-reader", qos: .utility)
  private let ramQueue = DispatchQueue(label: "mactop.ram-metrics-reader", qos: .utility)
  private let gpuQueue = DispatchQueue(label: "mactop.gpu-metrics-reader", qos: .utility)
  private let networkQueue = DispatchQueue(label: "mactop.network-metrics-reader", qos: .utility)
  private let onCPU: @MainActor @Sendable (CPUUsageDetail) -> Void
  private let onRAM: @MainActor @Sendable (RAMUsageDetail) -> Void
  private let onGPU: @MainActor @Sendable (GPUUsageDetail) -> Void
  private let onNetwork: @MainActor @Sendable (NetworkUsageDetail) -> Void
  private let timers: [DispatchSourceTimer]
  private struct State: Sendable {
    var cpuReadInFlight = false
    var ramReadInFlight = false
    var gpuReadInFlight = false
    var networkReadInFlight = false
    var historyEnabled = Set<MetricKind>()
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
    onNetwork: @escaping @MainActor @Sendable (NetworkUsageDetail) -> Void
  ) {

    self.onCPU = onCPU
    self.onRAM = onRAM
    self.onGPU = onGPU
    self.onNetwork = onNetwork
    let interval = normalizedMetricUpdateInterval(config.updateInterval)
    cpuReader = CPUUsageReader(updateInterval: interval)
    ramReader = RAMUsageReader(updateInterval: interval)
    gpuReader = GPUUsageReader(updateInterval: interval)
    networkReader = NetworkInterfaceReader(updateInterval: interval)

    let timer = DispatchSource.makeTimerSource(queue: coordinatorQueue)
    timers = [timer]
    let ms = max(1, Int(interval * 1000))
    let repeating = DispatchTimeInterval.milliseconds(ms)
    timer.schedule(deadline: .now() + repeating, repeating: repeating, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.refreshAll()
    }
    timer.resume()
  }

  private func refreshAll() {
    struct Kick {
      var cpu = false
      var ram = false
      var gpu = false
      var network = false
      var includeHistory = Set<MetricKind>()
      var epoch = 0
    }
    let kick = state.withLock { s -> Kick? in
      guard !s.isPaused, !s.isSleeping else { return nil }
      var kick = Kick(includeHistory: s.historyEnabled, epoch: s.dataEpoch)
      if !s.cpuReadInFlight { s.cpuReadInFlight = true; kick.cpu = true }
      if !s.ramReadInFlight { s.ramReadInFlight = true; kick.ram = true }
      if !s.gpuReadInFlight { s.gpuReadInFlight = true; kick.gpu = true }
      if !s.networkReadInFlight { s.networkReadInFlight = true; kick.network = true }
      return kick
    }
    guard let kick else { return }

    let includeNetworkHistory = kick.includeHistory.contains(.network)
    let includeCPUHistory = kick.includeHistory.contains(.cpu)
    let includeRAMHistory = kick.includeHistory.contains(.ram)
    let includeGPUHistory = kick.includeHistory.contains(.gpu)
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
          DispatchQueue.main.async { self.onCPU(cpu) }
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
          DispatchQueue.main.async { self.onRAM(ram) }
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
          DispatchQueue.main.async { self.onGPU(gpu) }
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
          DispatchQueue.main.async { self.onNetwork(network) }
        }
      }
    }
  }

  public func setHistoryEnabled(_ enabled: Bool, for kind: MetricKind) {
    coordinatorQueue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        if enabled {
          s.historyEnabled.insert(kind)
        } else {
          s.historyEnabled.remove(kind)
        }
      }
      if enabled {
        self.refreshAll()
      }
    }
  }

  public func setAllHistoryDisabled() {
    coordinatorQueue.async { [weak self] in
      self?.state.withLock { s in
        s.historyEnabled = []
      }
    }
  }

  public func setPaused(_ paused: Bool) {
    coordinatorQueue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        s.isPaused = paused
        s.dataEpoch += 1
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
    networkQueue.async { [weak self] in self?.networkReader.clearNetworkUsageHistory() }
  }

  public func systemWillSleep() {
    coordinatorQueue.async { [weak self] in
      self?.state.withLock { $0.isSleeping = true; $0.dataEpoch += 1 }
    }
  }

  public func systemDidWake() {
    coordinatorQueue.async { [weak self] in
      self?.state.withLock { $0.isSleeping = false }
    }
  }

  deinit {
    timers.forEach { $0.cancel() }
  }
}
