import Darwin
import Foundation
import IOKit

// Reads GPU, renderer, and tiler utilization from IOKit IOAccelerator statistics.

public struct GPUUsageDetail: Sendable {
    public var total: Double
    public var render: Double
    public var tiler: Double
    public var model: String
    public var history: [MetricHistoryPoint<Double>]
    public var renderHistory: [MetricHistoryPoint<Double>]
    public var tilerHistory: [MetricHistoryPoint<Double>]
    public var historyCapacity: Int
    public var hasRenderTilerSplit: Bool
}

public final class GPUUsageReader: @unchecked Sendable {
    private var history: ScalarHistory
    private var renderHistory: ScalarHistory
    private var tilerHistory: ScalarHistory
    private var total: Double = 0
    private var render: Double = 0
    private var tiler: Double = 0
    private var acceleratorService: io_object_t = 0
    private let phaseRecorder: CoreReadPhaseRecorder?
    // Whether the driver reports independent renderer/tiler utilization. Some
    // chips (e.g. M1/M2) mirror the device value into all three keys; newer
    // chips (e.g. M3) report genuine splits. Detected at runtime because the
    // behavior varies by chip and macOS version.
    private var renderTilerSplit = false

    public init(updateInterval: Double = 3, phaseRecorder: CoreReadPhaseRecorder? = nil) {
        self.phaseRecorder = phaseRecorder
        let capacity = metricGraphSampleCapacity(updateInterval: updateInterval)
        history = ScalarHistory(capacity: capacity)
        renderHistory = ScalarHistory(capacity: capacity)
        tilerHistory = ScalarHistory(capacity: capacity)
    }

    public func clearGPUUsageHistory() {
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
        let brand = decodeNullTerminatedCString(buf)
        return brand.isEmpty ? "GPU" : brand + " GPU"
    }()

    public func readGPUUsageDetail(includeHistory: Bool = false) -> GPUUsageDetail {
        if readCachedService() {
            return detail(includeHistory: includeHistory)
        }

        if acceleratorService != 0 {
            IOObjectRelease(acceleratorService)
            acceleratorService = 0
        }

        var iterator: io_iterator_t = 0
        let servicesResult = phaseRecorder?.measure("ioaccelerator.service_lookup") {
            IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("IOAccelerator"),
                &iterator
            )
        } ?? IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard servicesResult == KERN_SUCCESS else { return detail() }
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
        measureCoreReadPhase(phaseRecorder, name: "ioaccelerator.properties") {
            readGPUPerformanceStatisticsUnmeasured(service: service)
        }
    }

    private func readGPUPerformanceStatisticsUnmeasured(service: io_object_t) -> Bool {
        // Fast path: read only the PerformanceStatistics property (~24 µs)
        // instead of the full property tree (~2.3 ms). Same live values at the
        // one-second cadence, and more robust than the full read when other
        // tools (Activity Monitor, Stats) poll the same service. Falls back to
        // the full property tree if the single-key read misses.
        if let values = Self.readSingleKeyPerformanceStatistics(service) {
            total = values.total
            render = values.render
            tiler = values.tiler
        } else if let values = Self.readFullPerformanceStatistics(service) {
            total = values.total
            render = values.render
            tiler = values.tiler
        } else {
            return false
        }
        if abs(render - tiler) > 0.005 {
            renderTilerSplit = true
        }

        if let phaseRecorder {
            phaseRecorder.measure("history.append") {
                history.append(total)
                renderHistory.append(render)
                tilerHistory.append(tiler)
            }
        } else {
            history.append(total)
            renderHistory.append(render)
            tilerHistory.append(tiler)
        }
        return true
    }

    private static func readSingleKeyPerformanceStatistics(_ service: io_object_t) -> (total: Double, render: Double, tiler: Double)? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else { return nil }
        let value = unmanaged.takeRetainedValue()
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        let perf = unsafeDowncast(value, to: CFDictionary.self)
        return utilizationValues(perf)
    }

    private static func readFullPerformanceStatistics(_ service: io_object_t) -> (total: Double, render: Double, tiler: Double)? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any] else { return nil }
        // "Device Utilization %" and "GPU Activity(%)" both appear across Macs
        let pct = perf["Device Utilization %"] as? Double
               ?? perf["GPU Activity(%)"] as? Double
               ?? 0
        let render = perf["Renderer Utilization %"] as? Double ?? 0
        let tiler = perf["Tiler Utilization %"] as? Double ?? 0
        return (pct / 100.0, render / 100.0, tiler / 100.0)
    }

    private static func utilizationValues(_ perf: CFDictionary) -> (total: Double, render: Double, tiler: Double)? {
        // "Device Utilization %" and "GPU Activity(%)" both appear across Macs
        let pct = cfNumber(perf, "Device Utilization %") ?? cfNumber(perf, "GPU Activity(%)") ?? 0
        let render = cfNumber(perf, "Renderer Utilization %") ?? 0
        let tiler = cfNumber(perf, "Tiler Utilization %") ?? 0
        return (pct / 100.0, render / 100.0, tiler / 100.0)
    }

    private static func cfNumber(_ dict: CFDictionary, _ key: String) -> Double? {
        let cfKey = key as CFString
        guard let ptr = CFDictionaryGetValue(dict, Unmanaged.passUnretained(cfKey).toOpaque()) else { return nil }
        let number = unsafeBitCast(ptr, to: CFNumber.self)
        var value: Double = 0
        guard CFNumberGetValue(number, CFNumberType.doubleType, &value) else { return nil }
        return value
    }

    private func detail(includeHistory: Bool = false) -> GPUUsageDetail {
        let histories = includeHistory
            ? phaseRecorder?.measure("history.snapshot") {
                (
                    history.orderedValues,
                    renderHistory.orderedValues,
                    tilerHistory.orderedValues
                )
            } ?? (history.orderedValues, renderHistory.orderedValues, tilerHistory.orderedValues)
            : ([], [], [])
        return GPUUsageDetail(
            total: total,
            render: render,
            tiler: tiler,
            model: Self.modelName,
            history: histories.0,
            renderHistory: histories.1,
            tilerHistory: histories.2,
            historyCapacity: history.capacity,
            hasRenderTilerSplit: renderTilerSplit
        )
    }
}
