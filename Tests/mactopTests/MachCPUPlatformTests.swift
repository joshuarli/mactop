import XCTest

@testable import mactopPlatform

final class MachCPUPlatformTests: XCTestCase {
  func testCoreKindMapsClusterTypes() {
    XCTAssertEqual(MachCPUPlatform.coreKind(forClusterType: "E"), .efficiency)
    XCTAssertEqual(MachCPUPlatform.coreKind(forClusterType: "M"), .efficiency)
    XCTAssertEqual(MachCPUPlatform.coreKind(forClusterType: "P"), .performance)
    XCTAssertEqual(MachCPUPlatform.coreKind(forClusterType: "X"), .unknown)
    XCTAssertEqual(MachCPUPlatform.coreKind(forClusterType: nil), .unknown)
  }
}
