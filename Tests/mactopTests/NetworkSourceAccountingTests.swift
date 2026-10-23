import XCTest
@testable import mactopCore
@testable import mactopPlatform

final class NetworkSourceAccountingTests: XCTestCase {
  private func counter(
    _ id: UUID, pid: Int32 = 42, input: UInt64, output: UInt64 = 0
  ) -> PlatformNetworkProcessCounter {
    PlatformNetworkProcessCounter(
      sourceID: id, pid: pid, name: "process", inputBytes: input, outputBytes: output)
  }

  func testReorderingDoesNotChangeCombinedRate() {
    var accounting = NetworkProcessAccounting()
    let first = UUID(), second = UUID()
    _ = accounting.metrics(
      counters: [counter(first, input: 100), counter(second, input: 10_000)], elapsed: 1, limit: 8)
    let rows = accounting.metrics(
      counters: [counter(second, input: 10_004, output: 2), counter(first, input: 106)],
      elapsed: 2, limit: 8)
    XCTAssertEqual(rows.map(\.value), [6])
  }

  func testDisappearingSocketDoesNotHideSurvivingTraffic() {
    var accounting = NetworkProcessAccounting()
    let first = UUID(), second = UUID()
    _ = accounting.metrics(
      counters: [counter(first, input: 10_000), counter(second, input: 100)], elapsed: 1, limit: 8)
    XCTAssertEqual(accounting.metrics(
      counters: [counter(second, input: 150)], elapsed: 1, limit: 8).map(\.value), [50])
    XCTAssertTrue(accounting.metrics(
      counters: [counter(first, input: 20_000)], elapsed: 1, limit: 8).isEmpty)
  }

  func testResetRebaselinesBothDirections() {
    var accounting = NetworkProcessAccounting()
    let id = UUID()
    _ = accounting.metrics(
      counters: [counter(id, input: 100, output: 100)], elapsed: 1, limit: 8)
    XCTAssertTrue(accounting.metrics(
      counters: [counter(id, input: 10, output: 500)], elapsed: 1, limit: 8).isEmpty)
    XCTAssertEqual(accounting.metrics(
      counters: [counter(id, input: 20, output: 510)], elapsed: 2, limit: 8).map(\.value), [10])
    XCTAssertTrue(accounting.metrics(
      counters: [counter(id, input: 50, output: 5)], elapsed: 1, limit: 8).isEmpty)
  }

  func testNewSourceAndChangedPIDEstablishBaselines() {
    var accounting = NetworkProcessAccounting()
    let first = UUID(), second = UUID()
    _ = accounting.metrics(counters: [counter(first, input: 100)], elapsed: 1, limit: 8)
    XCTAssertTrue(accounting.metrics(
      counters: [counter(second, input: 10_000)], elapsed: 1, limit: 8).isEmpty)
    XCTAssertTrue(accounting.metrics(
      counters: [counter(second, pid: 43, input: 20_000)], elapsed: 1, limit: 8).isEmpty)
  }

  func testRanksSeparatePIDsAfterCombiningSockets() {
    var accounting = NetworkProcessAccounting()
    let first = UUID(), second = UUID(), third = UUID()
    _ = accounting.metrics(counters: [
      counter(first, input: 0), counter(second, input: 0), counter(third, pid: 43, input: 0),
    ], elapsed: 1, limit: 8)
    let rows = accounting.metrics(counters: [
      counter(first, input: 60), counter(second, input: 60), counter(third, pid: 43, input: 100),
    ], elapsed: 1, limit: 2)
    XCTAssertEqual(rows.map(\.pid), [42, 43])
    XCTAssertEqual(rows.map(\.value), [120, 100])
  }

  func testInvalidIntervalsRebaselineWithoutProducingRates() {
    for elapsed in [0, -1, Double.infinity, Double.nan] {
      var accounting = NetworkProcessAccounting()
      let id = UUID()
      _ = accounting.metrics(counters: [counter(id, input: 0)], elapsed: 1, limit: 8)
      XCTAssertTrue(accounting.metrics(
        counters: [counter(id, input: 100)], elapsed: elapsed, limit: 8).isEmpty)
      XCTAssertEqual(accounting.metrics(
        counters: [counter(id, input: 110)], elapsed: 1, limit: 8).map(\.value), [10])
    }
  }

  func testPartialCallbacksPreserveCountsBeforeDescription() throws {
    var sources = NetworkSourceStore()
    let id = sources.register(key: 1)
    sources.update(key: 1, sourceID: id, input: 100)
    XCTAssertTrue(sources.takeSnapshot().isEmpty)
    sources.update(key: 1, sourceID: id, pid: 42, name: "browser", output: 200)
    let snapshot = sources.takeSnapshot()
    let value = try XCTUnwrap(snapshot.first)
    XCTAssertEqual(value.sourceID, id)
    XCTAssertEqual(value.pid, 42)
    XCTAssertEqual(value.name, "browser")
    XCTAssertEqual(value.inputBytes, 100)
    XCTAssertEqual(value.outputBytes, 200)
  }

  func testRemovalPublishesFinalAvailableDeltaExactlyOnce() {
    var sources = NetworkSourceStore()
    var accounting = NetworkProcessAccounting()
    let first = sources.register(key: 1)
    let second = sources.register(key: 2)
    sources.update(key: 1, sourceID: first, pid: 42, name: "browser", input: 100, output: 0)
    sources.update(key: 2, sourceID: second, pid: 42, name: "browser", input: 200, output: 0)
    _ = accounting.metrics(counters: sources.takeSnapshot(), elapsed: 1, limit: 8)
    sources.update(key: 1, sourceID: first, input: 110)
    sources.update(key: 2, sourceID: second, input: 220)
    XCTAssertTrue(sources.remove(key: 1, sourceID: first))
    XCTAssertFalse(sources.remove(key: 1, sourceID: first))
    sources.update(key: 1, sourceID: first, input: 1_000_000)
    XCTAssertEqual(accounting.metrics(
      counters: sources.takeSnapshot(), elapsed: 1, limit: 8).map(\.value), [30])
    sources.update(key: 2, sourceID: second, input: 230)
    XCTAssertEqual(accounting.metrics(
      counters: sources.takeSnapshot(), elapsed: 1, limit: 8).map(\.value), [10])
    XCTAssertEqual(sources.takeSnapshot().map(\.sourceID), [second])
  }

  func testReusedPointerRejectsOldCallbacksAndEstablishesNewBaseline() {
    var sources = NetworkSourceStore()
    var accounting = NetworkProcessAccounting()
    let old = sources.register(key: 1)
    sources.update(key: 1, sourceID: old, pid: 42, name: "browser", input: 100, output: 0)
    _ = accounting.metrics(counters: sources.takeSnapshot(), elapsed: 1, limit: 8)
    sources.update(key: 1, sourceID: old, input: 120)
    XCTAssertTrue(sources.remove(key: 1, sourceID: old))
    let new = sources.register(key: 1)
    XCTAssertNotEqual(old, new)
    sources.update(key: 1, sourceID: new, pid: 42, name: "browser", input: 10_000, output: 0)
    sources.update(key: 1, sourceID: old, pid: 99, input: 1_000_000)
    XCTAssertFalse(sources.remove(key: 1, sourceID: old))
    XCTAssertEqual(accounting.metrics(
      counters: sources.takeSnapshot(), elapsed: 1, limit: 8).map(\.value), [20])
    sources.update(key: 1, sourceID: new, input: 10_005)
    XCTAssertEqual(accounting.metrics(
      counters: sources.takeSnapshot(), elapsed: 1, limit: 8).map(\.value), [5])
  }

  func testUnnamedSocketContributesToNamedProcess() {
    var accounting = NetworkProcessAccounting()
    let first = UUID(), second = UUID()
    let unnamed = PlatformNetworkProcessCounter(
      sourceID: second, pid: 42, name: "", inputBytes: 10, outputBytes: 0)
    _ = accounting.metrics(
      counters: [counter(first, input: 0), unnamed], elapsed: 1, limit: 8)
    let rows = accounting.metrics(counters: [
      counter(first, input: 20),
      PlatformNetworkProcessCounter(
        sourceID: second, pid: 42, name: "", inputBytes: 40, outputBytes: 0),
    ], elapsed: 1, limit: 8)
    XCTAssertEqual(rows.map(\.value), [50])
    XCTAssertEqual(rows.map(\.name), ["process"])
  }

  func testSourcesNeverSampledDoNotAccumulateRemovalSnapshots() {
    var sources = NetworkSourceStore()
    for key in UInt(0)..<100 {
      let id = sources.register(key: key)
      sources.update(key: key, sourceID: id, pid: 42, input: 100, output: 0)
      XCTAssertTrue(sources.remove(key: key, sourceID: id))
    }
    XCTAssertTrue(sources.takeSnapshot().isEmpty)
  }

  func testRegistrationOverExistingPointerRetiresOldLifetime() {
    var sources = NetworkSourceStore()
    let old = sources.register(key: 1)
    sources.update(key: 1, sourceID: old, pid: 42, input: 100, output: 0)
    _ = sources.takeSnapshot()
    sources.update(key: 1, sourceID: old, input: 120)
    let new = sources.register(key: 1)
    sources.update(key: 1, sourceID: new, pid: 42, input: 10_000, output: 0)
    XCTAssertFalse(sources.remove(key: 1, sourceID: old))
    let snapshot = sources.takeSnapshot()
    XCTAssertEqual(Set(snapshot.map(\.sourceID)), [old, new])
    XCTAssertEqual(snapshot.first { $0.sourceID == old }?.inputBytes, 120)
    XCTAssertEqual(sources.takeSnapshot().map(\.sourceID), [new])
  }

}
