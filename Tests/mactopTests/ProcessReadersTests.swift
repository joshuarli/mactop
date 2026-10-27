import Darwin
import XCTest

@testable import mactopPlatform
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

final class NetworkCounterRateTests: XCTestCase {
  func testNormalCounterDeltaProducesRate() {
    XCTAssertEqual(networkCounterRate(current: 3_000, previous: 1_000, elapsed: 2), 1_000)
  }

  func testCounterResetProducesZeroInsteadOfUnderflowing() {
    XCTAssertEqual(networkCounterRate(current: 100, previous: 1_000, elapsed: 1), 0)
  }

  func testInitialCounterAndInvalidElapsedProduceZero() {
    XCTAssertEqual(networkCounterRate(current: 1_000, previous: 0, elapsed: 1), 0)
    XCTAssertEqual(networkCounterRate(current: 1_000, previous: 500, elapsed: 0), 0)
  }
}

final class NetworkProcessAccountingTests: XCTestCase {
  func testCombinesSocketsForOnePID() {
    var accounting = NetworkProcessAccounting()
    let first = UUID()
    let second = UUID()
    let baseline = [
      PlatformNetworkProcessCounter(sourceID: first, pid: 42, name: "browser", inputBytes: 100, outputBytes: 0),
      PlatformNetworkProcessCounter(sourceID: second, pid: 42, name: "browser", inputBytes: 200, outputBytes: 0),
    ]
    XCTAssertTrue(accounting.metrics(counters: baseline, elapsed: 1, limit: 8).isEmpty)
    let current = [
      PlatformNetworkProcessCounter(sourceID: first, pid: 42, name: "browser", inputBytes: 1_000_100, outputBytes: 0),
      PlatformNetworkProcessCounter(sourceID: second, pid: 42, name: "browser", inputBytes: 201, outputBytes: 0),
    ]
    let rows = accounting.metrics(counters: current, elapsed: 1, limit: 8)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.pid, 42)
    XCTAssertEqual(rows.first?.value, 1_000_001)
  }
}

private final class SnapshotScript: @unchecked Sendable {
  private var remaining: [PlatformNetworkInterfaceSnapshot]

  init(_ snapshots: [PlatformNetworkInterfaceSnapshot]) {
    remaining = snapshots
  }

  func read() -> PlatformNetworkInterfaceSnapshot? {
    guard !remaining.isEmpty else { return nil }
    return remaining.removeFirst()
  }
}

private func networkSnapshot(upload: UInt64, download: UInt64) -> PlatformNetworkInterfaceSnapshot {
  PlatformNetworkInterfaceSnapshot(
    uploadBytes: upload, downloadBytes: download, interfaceName: "en0", displayName: "Wi-Fi",
    macAddress: "", ssid: nil, localIP: "", transmitRate: 0, isUp: true)
}

final class NetworkSessionTotalTests: XCTestCase {
  func testFirstClearAndZeroResetLeaveTotalsUnchanged() {
    let script = SnapshotScript([
      networkSnapshot(upload: 4_000, download: 9_000),
      networkSnapshot(upload: 4_250, download: 9_010),
      networkSnapshot(upload: 8_000, download: 20_000),
      networkSnapshot(upload: 8_030, download: 20_005),
      networkSnapshot(upload: 0, download: 0),
      networkSnapshot(upload: 100, download: 50),
      networkSnapshot(upload: 140, download: 80),
    ])
    let reader = NetworkInterfaceReader(updateInterval: 1, readSnapshot: { script.read() })

    var detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 0)
    XCTAssertEqual(detail.totalDown, 0)
    XCTAssertEqual(detail.upload, 0)
    XCTAssertEqual(detail.download, 0)

    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 250)
    XCTAssertEqual(detail.totalDown, 10)

    reader.clearNetworkUsageHistory()
    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 0)
    XCTAssertEqual(detail.totalDown, 0)
    XCTAssertEqual(detail.upload, 0)
    XCTAssertEqual(detail.download, 0)

    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 30)
    XCTAssertEqual(detail.totalDown, 5)

    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 30)
    XCTAssertEqual(detail.totalDown, 5)

    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 30)
    XCTAssertEqual(detail.totalDown, 5)
    XCTAssertEqual(detail.upload, 0)
    XCTAssertEqual(detail.download, 0)

    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 70)
    XCTAssertEqual(detail.totalDown, 35)
  }
}

private func interfaceListMessage(
  name: String, input: UInt64, output: UInt64, baudrate: UInt64
) -> [UInt8] {
  var header = if_msghdr2()
  let nameBytes = Array(name.utf8)
  let addressLength = (8 + nameBytes.count + 3) & ~3
  header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size + addressLength)
  header.ifm_type = UInt8(RTM_IFINFO2)
  header.ifm_addrs = RTA_IFP
  header.ifm_data.ifi_ibytes = input
  header.ifm_data.ifi_obytes = output
  header.ifm_data.ifi_baudrate = baudrate
  var bytes = [UInt8](repeating: 0, count: Int(header.ifm_msglen))
  withUnsafeBytes(of: header) { raw in
    for (offset, byte) in raw.enumerated() {
      bytes[offset] = byte
    }
  }
  let start = MemoryLayout<if_msghdr2>.size
  bytes[start] = UInt8(addressLength)
  bytes[start + 1] = UInt8(AF_LINK)
  bytes[start + 5] = UInt8(nameBytes.count)
  for (offset, byte) in nameBytes.enumerated() {
    bytes[start + 8 + offset] = byte
  }
  return bytes
}

private func counterFixture(input: UInt64, output: UInt64, baudrate: UInt64) -> [UInt8] {
  [8, 0, 0, UInt8(RTM_NEWADDR), 0, 0, 0, 0]
    + interfaceListMessage(name: "gif0", input: 7, output: 8, baudrate: 0)
    + interfaceListMessage(name: "en0", input: input, output: output, baudrate: baudrate)
}

final class InterfaceData64CounterTests: XCTestCase {
  func testCounterCrosses32BitsAndBaudrateStaysWide() throws {
    let baudrate = UInt64(UInt32.max) + 1_000_000
    let below = counterFixture(
      input: UInt64(UInt32.max) - 3, output: UInt64(UInt32.max) - 9, baudrate: baudrate
    ).withUnsafeBytes { interfaceData64Counters(in: $0) }
    let above = counterFixture(
      input: UInt64(UInt32.max) + 7, output: UInt64(UInt32.max) + 16, baudrate: baudrate
    ).withUnsafeBytes { interfaceData64Counters(in: $0) }
    let low = try XCTUnwrap(below["en0"])
    let high = try XCTUnwrap(above["en0"])
    XCTAssertEqual(below["gif0"]?.inputBytes, 7)
    XCTAssertEqual(below["gif0"]?.outputBytes, 8)
    XCTAssertEqual(low.inputBytes, UInt64(UInt32.max) - 3)
    XCTAssertEqual(low.outputBytes, UInt64(UInt32.max) - 9)
    XCTAssertEqual(low.baudrate, baudrate)
    XCTAssertEqual(high.inputBytes, UInt64(UInt32.max) + 7)
    XCTAssertEqual(high.outputBytes, UInt64(UInt32.max) + 16)
    XCTAssertEqual(high.baudrate, baudrate)
    XCTAssertGreaterThan(high.baudrate, UInt64(UInt32.max))

    let script = SnapshotScript([
      networkSnapshot(upload: low.outputBytes, download: low.inputBytes),
      networkSnapshot(upload: high.outputBytes, download: high.inputBytes),
      networkSnapshot(upload: 20, download: 5),
      networkSnapshot(upload: 25, download: 9),
    ])
    let reader = NetworkInterfaceReader(updateInterval: 1, readSnapshot: { script.read() })
    var detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 0)
    XCTAssertEqual(detail.totalDown, 0)
    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 25)
    XCTAssertEqual(detail.totalDown, 10)
    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 25)
    XCTAssertEqual(detail.totalDown, 10)
    detail = reader.readNetworkUsageDetail()
    XCTAssertEqual(detail.totalUp, 30)
    XCTAssertEqual(detail.totalDown, 14)
  }
}
