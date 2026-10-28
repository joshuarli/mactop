import Foundation
import Synchronization
import mactopPlatform


public struct GPUUsageDetail: Sendable {
  public var total: Double
  public var render: Double
  public var tiler: Double
  public var model: String
  public var history: [MetricHistoryPoint<Double>]
  public var renderHistory: [MetricHistoryPoint<Double>]
  public var tilerHistory: [MetricHistoryPoint<Double>]
  public var historyCapacity: Int
  public var hasRenderTilerSplit: Bool
}

public final class GPUUsageReader: Sendable {
  fileprivate struct State: Sendable {
    var history: ScalarHistory
    var renderHistory: ScalarHistory
    var tilerHistory: ScalarHistory
    var total = 0.0
    var render = 0.0
    var tiler = 0.0
    var model = "GPU"
    var renderTilerSplit = false
  }
  private let state: Mutex<State>
  private let platformReader = IOAcceleratorPlatform()
  private let phaseRecorder: CoreReadPhaseRecorder?

  public init(updateInterval: Double = 3, phaseRecorder: CoreReadPhaseRecorder? = nil) {
    self.phaseRecorder = phaseRecorder
    let capacity = metricGraphSampleCapacity(updateInterval: updateInterval)
    state = Mutex(
      State(
        history: ScalarHistory(capacity: capacity),
        renderHistory: ScalarHistory(capacity: capacity),
        tilerHistory: ScalarHistory(capacity: capacity)))
  }

  public func clearGPUUsageHistory() {
    state.withLock { s in
      s.history.removeAll()
      s.renderHistory.removeAll()
      s.tilerHistory.removeAll()
      s.total = 0
      s.render = 0
      s.tiler = 0
    }
  }

  public func readGPUUsageDetail(includeHistory: Bool = false) -> GPUUsageDetail {
    if let snapshot = phaseRecorder?.measure("ioaccelerator.properties", { platformReader.read() })
      ?? platformReader.read()
    {
      if let phaseRecorder {
        phaseRecorder.measure("history.append") {
          state.withLock { s in s.record(snapshot: snapshot) }
        }
      } else {
        state.withLock { s in s.record(snapshot: snapshot) }
      }
    }
    return state.withLock { s in s.detail(includeHistory: includeHistory) }
  }
}

fileprivate extension GPUUsageReader.State {
  mutating func record(snapshot: PlatformGPUHardwareSnapshot) {
    total = snapshot.total
    render = snapshot.render
    tiler = snapshot.tiler
    model = snapshot.model
    renderTilerSplit = snapshot.renderTilerSplit
    history.append(total)
    renderHistory.append(render)
    tilerHistory.append(tiler)
  }

  func detail(includeHistory: Bool) -> GPUUsageDetail {
    let histories =
      includeHistory
      ? (history.orderedValues, renderHistory.orderedValues, tilerHistory.orderedValues)
      : ([], [], [])
    return GPUUsageDetail(
      total: total,
      render: render,
      tiler: tiler,
      model: model,
      history: histories.0,
      renderHistory: histories.1,
      tilerHistory: histories.2,
      historyCapacity: history.capacity,
      hasRenderTilerSplit: renderTilerSplit
    )
  }
}
