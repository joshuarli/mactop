import XCTest
@testable import mactop

final class InsertTopTests: XCTestCase {
    private func make(_ value: Double) -> TopProcess { TopProcess(name: "\(value)", value: value) }
    private func desc(_ top: [TopProcess]) -> Bool { zip(top, top.dropFirst()).allSatisfy { $0.value >= $1.value } }

    func testBuildsInDescendingOrder() {
        var top: [TopProcess] = []
        for v in [10.0, 30.0, 20.0] {
            insertTop(make(v), into: &top, count: 3) { $0.value > $1.value }
        }
        XCTAssertTrue(desc(top))
        XCTAssertEqual(top.map(\.value), [30, 20, 10])
    }

    func testEnforcesCountLimit() {
        var top: [TopProcess] = []
        for v in 0..<10 {
            insertTop(make(Double(v)), into: &top, count: 3) { $0.value > $1.value }
        }
        XCTAssertEqual(top.count, 3)
        XCTAssertEqual(top.first?.value, 9)
    }

    func testSmallValueDoesNotDisplaceWhenFull() {
        var top: [TopProcess] = []
        insertTop(make(10), into: &top, count: 1) { $0.value > $1.value }
        insertTop(make(5),  into: &top, count: 1) { $0.value > $1.value }
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].value, 10)
    }

    func testCountZeroInsertsNothing() {
        var top: [TopProcess] = []
        insertTop(make(99), into: &top, count: 0) { $0.value > $1.value }
        XCTAssertTrue(top.isEmpty)
    }
}

final class CPUDeltaTests: XCTestCase {
    func testNormalDelta() {
        let pct = cpuDelta(current: (time: 2_000_000_000, start: 1),
                           previous: (time: 1_000_000_000, start: 1),
                           elapsed: 1.0)
        XCTAssertEqual(try XCTUnwrap(pct), 100.0, accuracy: 0.001)
    }

    func testHalfCore() {
        let pct = cpuDelta(current: (time: 500_000_000, start: 1),
                           previous: (time: 0, start: 1),
                           elapsed: 1.0)
        XCTAssertEqual(pct!, 50.0, accuracy: 0.001)
    }

    func testMultiThreadedExceeds100() {
        let pct = cpuDelta(current: (time: 4_000_000_000, start: 1),
                           previous: (time: 0, start: 1),
                           elapsed: 1.0)
        XCTAssertEqual(pct!, 400.0, accuracy: 0.001)
    }

    func testPIDReuseReturnedNil() {
        let pct = cpuDelta(current: (time: 1_000_000_000, start: 200),
                           previous: (time: 500_000_000, start: 100),
                           elapsed: 1.0)
        XCTAssertNil(pct)
    }

    func testTimeWentBackwardsReturnsNil() {
        let pct = cpuDelta(current: (time: 100, start: 1),
                           previous: (time: 500, start: 1),
                           elapsed: 1.0)
        XCTAssertNil(pct)
    }

    func testElapsedZeroReturnsNil() {
        let pct = cpuDelta(current: (time: 1_000_000_000, start: 1),
                           previous: (time: 0, start: 1),
                           elapsed: 0)
        XCTAssertNil(pct)
    }

    func testScalesWithElapsed() {
        // Same delta, twice the elapsed → half the %
        let pct1 = cpuDelta(current: (time: 1_000_000_000, start: 1), previous: (time: 0, start: 1), elapsed: 1.0)
        let pct2 = cpuDelta(current: (time: 1_000_000_000, start: 1), previous: (time: 0, start: 1), elapsed: 2.0)
        XCTAssertEqual(pct1!, pct2! * 2, accuracy: 0.001)
    }
}

final class PowerValidationTests: XCTestCase {
    func testAcceptsNormalPower() {
        XCTAssertEqual(validatedPowerWatts(42), 42)
    }

    func testRejectsWakeSpike() {
        XCTAssertNil(validatedPowerWatts(100_000))
    }

    func testRejectsNonFinitePower() {
        XCTAssertNil(validatedPowerWatts(.infinity))
        XCTAssertNil(validatedPowerWatts(.nan))
    }
}

final class ParsePSOutputTests: XCTestCase {
    private let sample = """
      PID  %CPU COMM
      411   6.9 WindowServer
     1234  12.5 mds_stores
     5678   0.5 Spotlight
        9   0.0 launchd
    """

    func testParsesFieldsCorrectly() {
        let results = parsePSOutput(sample, count: 8)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].pid,  411)
        XCTAssertEqual(results[0].pct,  6.9,  accuracy: 0.001)
        XCTAssertEqual(results[0].comm, "WindowServer")
        XCTAssertEqual(results[1].pid,  1234)
        XCTAssertEqual(results[1].pct,  12.5, accuracy: 0.001)
    }

    func testStopsAtZeroPct() {
        // launchd at 0.0 should not appear
        let results = parsePSOutput(sample, count: 8)
        XCTAssertFalse(results.contains { $0.comm == "launchd" })
    }

    func testSkipsHeader() {
        let results = parsePSOutput(sample, count: 8)
        XCTAssertFalse(results.contains { $0.comm == "COMM" })
    }

    func testCountLimit() {
        let results = parsePSOutput(sample, count: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testCommaDecimalSeparator() {
        let input = "  PID  %CPU COMM\n  100   1,5 Safari\n"
        let results = parsePSOutput(input, count: 8)
        XCTAssertEqual(try XCTUnwrap(results.first?.pct), 1.5, accuracy: 0.001)
    }

    func testMultiWordComm() {
        let input = "  PID  %CPU COMM\n  999   5.0 com.apple.WebKit.Networking\n"
        let results = parsePSOutput(input, count: 8)
        XCTAssertEqual(results.first?.comm, "com.apple.WebKit.Networking")
    }

    func testEmptyOutputReturnsEmpty() {
        XCTAssertTrue(parsePSOutput("", count: 8).isEmpty)
    }

    func testHeaderOnlyReturnsEmpty() {
        XCTAssertTrue(parsePSOutput("  PID  %CPU COMM\n", count: 8).isEmpty)
    }
}
