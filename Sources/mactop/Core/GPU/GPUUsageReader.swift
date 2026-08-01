import Darwin
import Foundation
import IOKit

// Reads GPU, renderer, and tiler utilization from IOKit IOAccelerator statistics.

struct GPUUsageDetail {
    var total: Double
    var render: Double
    var tiler: Double
    var model: String
    var history: [MetricHistoryPoint<Double>]
    var renderHistory: [MetricHistoryPoint<Double>]
    var tilerHistory: [MetricHistoryPoint<Double>]
    var historyCapacity: Int
}

final class GPUUsageReader {
    private var history: ScalarHistory
    private var renderHistory: ScalarHistory
    private var tilerHistory: ScalarHistory
    private var total: Double = 0
    private var render: Double = 0
    private var tiler: Double = 0
    private var acceleratorService: io_object_t = 0

    init(updateInterval: Double = 3) {
        let capacity = metricGraphSampleCapacity(updateInterval: updateInterval)
        history = ScalarHistory(capacity: capacity)
        renderHistory = ScalarHistory(capacity: capacity)
        tilerHistory = ScalarHistory(capacity: capacity)
    }

    func clearGPUUsageHistory() {
        history.removeAll()
        renderHistory.removeAll()
        tilerHistory.removeAll()
        total = 0
        render = 0
        tiler = 0
    }

    deinit {
        if acceleratorService != 0 {
            IOObjectRelease(acceleratorService)
        }
    }

    // Read once — brand string never changes at runtime
    private static let modelName: String = {
        var buf = [CChar](repeating: 0, count: 256)
        var size = buf.count
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let brand = String(cString: buf)
        return brand.isEmpty ? "GPU" : brand + " GPU"
    }()

    func readGPUUsageDetail(includeHistory: Bool = false) -> GPUUsageDetail {
        if readCachedService() {
            return detail(includeHistory: includeHistory)
        }

        if acceleratorService != 0 {
            IOObjectRelease(acceleratorService)
            acceleratorService = 0
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return detail() }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if readGPUPerformanceStatistics(service: service) {
                acceleratorService = service
                return detail(includeHistory: includeHistory)
            }
            IOObjectRelease(service)
        }
        return detail(includeHistory: includeHistory)
    }

    private func readCachedService() -> Bool {
        acceleratorService != 0 && readGPUPerformanceStatistics(service: acceleratorService)
    }

    private func readGPUPerformanceStatistics(service: io_object_t) -> Bool {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any] else { return false }

        // Intel uses "Device Utilization %", Apple Silicon uses "GPU Activity(%)"
        let pct = perf["Device Utilization %"] as? Double
               ?? perf["GPU Activity(%)"] as? Double
               ?? 0
        total = pct / 100.0
        render = (perf["Renderer Utilization %"] as? Double ?? 0) / 100.0
        tiler = (perf["Tiler Utilization %"]   as? Double ?? 0) / 100.0

        history.append(total)
        renderHistory.append(render)
        tilerHistory.append(tiler)
        return true
    }

    private func detail(includeHistory: Bool = false) -> GPUUsageDetail {
        GPUUsageDetail(
            total: total,
            render: render,
            tiler: tiler,
            model: Self.modelName,
            history: includeHistory ? history.orderedValues : [],
            renderHistory: includeHistory ? renderHistory.orderedValues : [],
            tilerHistory: includeHistory ? tilerHistory.orderedValues : [],
            historyCapacity: history.capacity
        )
    }
}
