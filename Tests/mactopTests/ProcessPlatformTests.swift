import XCTest

import mactopPlatform

final class ProcessPlatformTests: XCTestCase {
  func testAllProcessIDsReturnsManyPositivePIDs() {
    let pids = ProcessPlatform.allProcessIDs()
    XCTAssertGreaterThan(pids.count, 0)
    XCTAssertTrue(pids.allSatisfy { $0 > 0 })
    XCTAssertGreaterThan(pids.count, 56)
  }
}