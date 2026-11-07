import Foundation
import Synchronization
import XCTest
@testable import mactopCore

final class SystemMetricsCoordinatorTests: XCTestCase {
  func testHistoryDeliveryResumesAfterPauseAndResume() {
    final class Box: @unchecked Sendable {
      private let lock = NSLock()
      private var values: [CPUUsageDetail] = []

      func append(_ detail: CPUUsageDetail) {
        lock.lock()
        values.append(detail)
        lock.unlock()
      }

      func snapshot() -> [CPUUsageDetail] {
        lock.lock()
        defer { lock.unlock() }
        return values
      }
    }

    let box = Box()
    let coordinator = SystemMetricsCoordinator(
      config: MactopConfig(updateInterval: 1),
      onCPU: { detail in box.append(detail) },
      onRAM: { _ in },
      onGPU: { _ in },
      onNetwork: { _ in }
    )
    coordinator.setHistoryEnabled(true, for: 1)

    XCTAssertTrue(
      waitUntil(timeout: 5) { box.snapshot().contains { !$0.history.isEmpty } },
      "expected a CPU delivery with history before pausing")

    let deliveredBeforePause = box.snapshot().count
    coordinator.setPaused(true)
    coordinator.setPaused(false)

    XCTAssertTrue(
      waitUntil(timeout: 6) {
        box.snapshot().dropFirst(deliveredBeforePause).contains { !$0.history.isEmpty }
      },
      "expected history in CPU deliveries after resume")
    withExtendedLifetime(coordinator) {}
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
  }
}
