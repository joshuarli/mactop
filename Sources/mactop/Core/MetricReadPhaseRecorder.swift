import Foundation

public struct CoreReadPhaseStats: Sendable {
    public let name: String
    public let count: Int
    public let wallNanoseconds: UInt64
}

public final class CoreReadPhaseRecorder: @unchecked Sendable {
    private var counts: [String: Int] = [:]
    private var wallNanoseconds: [String: UInt64] = [:]

    public init() {}

    public func reset() {
        counts.removeAll(keepingCapacity: true)
        wallNanoseconds.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public func measure<Value>(_ name: String, _ work: () -> Value) -> Value {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = work()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        counts[name, default: 0] += 1
        wallNanoseconds[name, default: 0] += elapsed
        return value
    }

    public func snapshot() -> [CoreReadPhaseStats] {
        counts.keys.sorted().map { name in
            CoreReadPhaseStats(
                name: name,
                count: counts[name] ?? 0,
                wallNanoseconds: wallNanoseconds[name] ?? 0
            )
        }
    }
}

func measureCoreReadPhase<Value>(
    _ recorder: CoreReadPhaseRecorder?,
    name: String,
    _ work: () -> Value
) -> Value {
    guard let recorder else { return work() }
    return recorder.measure(name, work)
}
