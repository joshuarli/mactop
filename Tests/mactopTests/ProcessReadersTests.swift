import XCTest

@testable import mactopCore

final class RankedMetricInsertionTests: XCTestCase {
  private func makeRankedMetric(_ value: Double) -> RankedProcessMetric {
    RankedProcessMetric(name: "\(value)", value: value)
  }
  private func isDescendingByMetricValue(_ metrics: [RankedProcessMetric]) -> Bool {
    zip(metrics, metrics.dropFirst()).allSatisfy { $0.value >= $1.value }
  }

  func testBuildsInDescendingOrder() {
    var top: [RankedProcessMetric] = []
    for v in [10.0, 30.0, 20.0] {
      insertRankedMetric(makeRankedMetric(v), into: &top, count: 3) { $0.value > $1.value }
    }
    XCTAssertTrue(isDescendingByMetricValue(top))
    XCTAssertEqual(top.map(\.value), [30, 20, 10])
  }

  func testEnforcesCountLimit() {
    var top: [RankedProcessMetric] = []
    for v in 0..<10 {
      insertRankedMetric(makeRankedMetric(Double(v)), into: &top, count: 3) { $0.value > $1.value }
    }
    XCTAssertEqual(top.count, 3)
    XCTAssertEqual(top.first?.value, 9)
  }

  func testSmallValueDoesNotDisplaceWhenFull() {
    var top: [RankedProcessMetric] = []
    insertRankedMetric(makeRankedMetric(10), into: &top, count: 1) { $0.value > $1.value }
    insertRankedMetric(makeRankedMetric(5), into: &top, count: 1) { $0.value > $1.value }
    XCTAssertEqual(top.count, 1)
    XCTAssertEqual(top[0].value, 10)
  }

  func testCountZeroInsertsNothing() {
    var top: [RankedProcessMetric] = []
    insertRankedMetric(makeRankedMetric(99), into: &top, count: 0) { $0.value > $1.value }
    XCTAssertTrue(top.isEmpty)
  }
}

final class CPUProcessUsageDeltaTests: XCTestCase {
  func testNormalDelta() {
    let pct = calculateCPUProcessUsagePercent(
      current: (time: 2_000_000_000, start: 1),
      previous: (time: 1_000_000_000, start: 1),
      elapsed: 1.0)
    XCTAssertEqual(try XCTUnwrap(pct), 100.0, accuracy: 0.001)
  }

  func testHalfCore() {
    let pct = calculateCPUProcessUsagePercent(
      current: (time: 500_000_000, start: 1),
      previous: (time: 0, start: 1),
      elapsed: 1.0)
    XCTAssertEqual(pct!, 50.0, accuracy: 0.001)
  }

  func testMultiThreadedExceeds100() {
    let pct = calculateCPUProcessUsagePercent(
      current: (time: 4_000_000_000, start: 1),
      previous: (time: 0, start: 1),
      elapsed: 1.0)
    XCTAssertEqual(pct!, 400.0, accuracy: 0.001)
  }

  func testPIDReuseReturnedNil() {
    let pct = calculateCPUProcessUsagePercent(
      current: (time: 1_000_000_000, start: 200),
      previous: (time: 500_000_000, start: 100),
      elapsed: 1.0)
    XCTAssertNil(pct)
  }

  func testTimeWentBackwardsReturnsNil() {
    let pct = calculateCPUProcessUsagePercent(
      current: (time: 100, start: 1),
      previous: (time: 500, start: 1),
      elapsed: 1.0)
    XCTAssertNil(pct)
  }

  func testElapsedZeroReturnsNil() {
    let pct = calculateCPUProcessUsagePercent(
      current: (time: 1_000_000_000, start: 1),
      previous: (time: 0, start: 1),
      elapsed: 0)
    XCTAssertNil(pct)
  }

  func testScalesWithElapsed() {
    // Same delta, twice the elapsed → half the %
    let pct1 = calculateCPUProcessUsagePercent(
      current: (time: 1_000_000_000, start: 1), previous: (time: 0, start: 1), elapsed: 1.0)
    let pct2 = calculateCPUProcessUsagePercent(
      current: (time: 1_000_000_000, start: 1), previous: (time: 0, start: 1), elapsed: 2.0)
    XCTAssertEqual(pct1!, pct2! * 2, accuracy: 0.001)
  }
}

final class PowerReadingValidationTests: XCTestCase {
  func testAcceptsNormalPower() {
    XCTAssertEqual(validatedPowerReadingWatts(42), 42)
  }

  func testRejectsWakeSpike() {
    XCTAssertNil(validatedPowerReadingWatts(100_000))
  }

  func testRejectsNonFinitePower() {
    XCTAssertNil(validatedPowerReadingWatts(.infinity))
    XCTAssertNil(validatedPowerReadingWatts(.nan))
  }
}

final class PSProcessOutputParsingTests: XCTestCase {
  private let sample = """
      PID  %CPU COMM
      411   6.9 WindowServer
     1234  12.5 mds_stores
     5678   0.5 Spotlight
        9   0.0 launchd
    """

  func testParsesFieldsCorrectly() {
    let results = parsePSProcessOutput(sample, count: 8)
    XCTAssertEqual(results.count, 3)
    XCTAssertEqual(results[0].pid, 411)
    XCTAssertEqual(results[0].pct, 6.9, accuracy: 0.001)
    XCTAssertEqual(results[0].comm, "WindowServer")
    XCTAssertEqual(results[1].pid, 1234)
    XCTAssertEqual(results[1].pct, 12.5, accuracy: 0.001)
  }

  func testStopsAtZeroPct() {
    // launchd at 0.0 should not appear
    let results = parsePSProcessOutput(sample, count: 8)
    XCTAssertFalse(results.contains { $0.comm == "launchd" })
  }

  func testSkipsHeader() {
    let results = parsePSProcessOutput(sample, count: 8)
    XCTAssertFalse(results.contains { $0.comm == "COMM" })
  }

  func testCountLimit() {
    let results = parsePSProcessOutput(sample, count: 2)
    XCTAssertEqual(results.count, 2)
  }

  func testCommaDecimalSeparator() {
    let input = "  PID  %CPU COMM\n  100   1,5 Safari\n"
    let results = parsePSProcessOutput(input, count: 8)
    XCTAssertEqual(try XCTUnwrap(results.first?.pct), 1.5, accuracy: 0.001)
  }

  func testMultiWordComm() {
    let input = "  PID  %CPU COMM\n  999   5.0 com.apple.WebKit.Networking\n"
    let results = parsePSProcessOutput(input, count: 8)
    XCTAssertEqual(results.first?.comm, "com.apple.WebKit.Networking")
  }

  func testEmptyOutputReturnsEmpty() {
    XCTAssertTrue(parsePSProcessOutput("", count: 8).isEmpty)
  }

  func testHeaderOnlyReturnsEmpty() {
    XCTAssertTrue(parsePSProcessOutput("  PID  %CPU COMM\n", count: 8).isEmpty)
  }
}
