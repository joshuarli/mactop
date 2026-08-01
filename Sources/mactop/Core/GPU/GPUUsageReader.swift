import Foundation
import mactopPlatform

// Reads GPU, renderer, and tiler utilization from the typed IOKit platform boundary.

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

public final class GPUUsageReader: @unchecked Sendable {
  private var history: ScalarHistory
  private var renderHistory: ScalarHistory
  private var tilerHistory: ScalarHistory
  private var total = 0.0
  private var render = 0.0
  private var tiler = 0.0
  private var model = "GPU"
  private var renderTilerSplit = false
  private let platformReader = IOAcceleratorPlatform()
  private let phaseRecorder: CoreReadPhaseRecorder?

  public init(updateInterval: Double = 3, phaseRecorder: CoreReadPhaseRecorder? = nil) {
    self.phaseRecorder = phaseRecorder
    let capacity = metricGraphSampleCapacity(updateInterval: updateInterval)
    history = ScalarHistory(capacity: capacity)
    renderHistory = ScalarHistory(capacity: capacity)
    tilerHistory = ScalarHistory(capacity: capacity)
  }

  public func clearGPUUsageHistory() {
    history.removeAll()
    renderHistory.removeAll()
    tilerHistory.removeAll()
    total = 0
    render = 0
    tiler = 0
  }

  public func readGPUUsageDetail(includeHistory: Bool = false) -> GPUUsageDetail {
    if let snapshot = phaseRecorder?.measure("ioaccelerator.properties", { platformReader.read() })
      ?? platformReader.read()
    {
      total = snapshot.total
      render = snapshot.render
      tiler = snapshot.tiler
      model = snapshot.model
      renderTilerSplit = snapshot.renderTilerSplit
      let append = { [self] in
        history.append(total)
        renderHistory.append(render)
        tilerHistory.append(tiler)
      }
      if let phaseRecorder { phaseRecorder.measure("history.append", append) } else { append() }
    }
    return detail(includeHistory: includeHistory)
  }

  private func detail(includeHistory: Bool) -> GPUUsageDetail {
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
