import Foundation
import Synchronization

public struct CoreReadPhaseStats: Sendable {
  public let name: String
  public let count: Int
  public let wallNanoseconds: UInt64
}

public final class CoreReadPhaseRecorder: Sendable {
  private struct State: Sendable {
    var counts: [String: Int] = [:]
    var wallNanoseconds: [String: UInt64] = [:]
  }
  private let state = Mutex(State())

  public init() {}

  public func reset() {
    state.withLock { $0 = State() }
  }

  public func record(name: String, wallNanoseconds: UInt64) {
    state.withLock {
      $0.counts[name, default: 0] += 1
      $0.wallNanoseconds[name, default: 0] += wallNanoseconds
    }
  }

  @discardableResult
  public func measure<Value>(_ name: String, _ work: () -> Value) -> Value {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = work()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    record(name: name, wallNanoseconds: elapsed)
    return value
  }

  public func snapshot() -> [CoreReadPhaseStats] {
    state.withLock { s in
      s.counts.keys.sorted().map { name in
        CoreReadPhaseStats(
          name: name,
          count: s.counts[name] ?? 0,
          wallNanoseconds: s.wallNanoseconds[name] ?? 0
        )
      }
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
