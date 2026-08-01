import Foundation

public let metricGraphHistoryWindow: TimeInterval = 5 * 60
private let metricGraphSmoothingAlpha = 0.3

// Keep real sample timestamps so charts can represent long unavailable spans
// without allocating one placeholder entry for every missed update.
public struct MetricHistoryPoint<Value> {
    public var date: Date
    public var value: Value

    public init(date: Date, value: Value) {
        self.date = date
        self.value = value
    }
}

func metricGraphSampleCapacity(updateInterval: Double) -> Int {
    max(2, Int(ceil(metricGraphHistoryWindow / max(updateInterval, 1))))
}

func smoothMetricValue(_ value: Double, previous: Double?, alpha: Double = metricGraphSmoothingAlpha) -> Double {
    guard let previous else { return value }
    return alpha * value + (1 - alpha) * previous
}

struct ScalarHistory {
    private var values: [MetricHistoryPoint<Double>]
    private var nextIndex = 0
    private var count = 0
    private var smoothed: Double?

    init(capacity: Int) {
        let capacity = max(capacity, 1)
        values = Array(repeating: MetricHistoryPoint(date: .distantPast, value: 0), count: capacity)
    }

    var capacity: Int { values.count }

    mutating func removeAll() {
        values = Array(repeating: MetricHistoryPoint(date: .distantPast, value: 0), count: values.count)
        nextIndex = 0
        count = 0
        smoothed = nil
    }

    mutating func append(_ value: Double) {
        let value = smoothMetricValue(value, previous: smoothed)
        smoothed = value
        values[nextIndex] = MetricHistoryPoint(date: Date(), value: value)
        nextIndex = (nextIndex + 1) % values.count
        count = min(count + 1, values.count)
    }

    var orderedValues: [MetricHistoryPoint<Double>] {
        guard count > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-metricGraphHistoryWindow)
        var output: [MetricHistoryPoint<Double>] = []
        output.reserveCapacity(count)
        let start = count == values.count ? nextIndex : 0
        for offset in 0..<count {
            let index = (start + offset) % values.count
            if values[index].date >= cutoff {
                output.append(values[index])
            }
        }
        return output
    }
}

struct PairHistory {
    private var values: [MetricHistoryPoint<(up: Double, down: Double)>]
    private var nextIndex = 0
    private var count = 0
    private var smoothedUp: Double?
    private var smoothedDown: Double?

    init(capacity: Int) {
        let capacity = max(capacity, 1)
        values = Array(repeating: MetricHistoryPoint(date: .distantPast, value: (up: 0, down: 0)), count: capacity)
    }

    var capacity: Int { values.count }

    mutating func removeAll() {
        values = Array(repeating: MetricHistoryPoint(date: .distantPast, value: (up: 0, down: 0)), count: values.count)
        nextIndex = 0
        count = 0
        smoothedUp = nil
        smoothedDown = nil
    }

    mutating func append(up: Double, down: Double) {
        let up = smoothMetricValue(up, previous: smoothedUp)
        let down = smoothMetricValue(down, previous: smoothedDown)
        smoothedUp = up
        smoothedDown = down
        values[nextIndex] = MetricHistoryPoint(date: Date(), value: (up: up, down: down))
        nextIndex = (nextIndex + 1) % values.count
        count = min(count + 1, values.count)
    }

    var orderedValues: [MetricHistoryPoint<(up: Double, down: Double)>] {
        guard count > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-metricGraphHistoryWindow)
        var output: [MetricHistoryPoint<(up: Double, down: Double)>] = []
        output.reserveCapacity(count)
        let start = count == values.count ? nextIndex : 0
        for offset in 0..<count {
            let index = (start + offset) % values.count
            if values[index].date >= cutoff {
                output.append(values[index])
            }
        }
        return output
    }
}

// MARK: - CPU
