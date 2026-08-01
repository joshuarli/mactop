import Darwin
import Foundation
import mactopCore

private struct BenchConfiguration {
    let duration: TimeInterval
    let interval: TimeInterval
    let warmupTicks: Int

    init(environment: [String: String]) {
        duration = max(0.1, Double(environment["BENCH_SECONDS"] ?? "5") ?? 5)
        interval = max(0.01, Double(environment["BENCH_INTERVAL"] ?? "1") ?? 1)
        warmupTicks = max(0, Int(environment["BENCH_WARMUP_TICKS"] ?? "2") ?? 2)
    }
}

private struct AllocationSnapshot {
    let liveBlocks: Int
    let liveBytes: Int
    let reservedBytes: Int
    let physicalFootprint: UInt64
}

private struct BenchPhaseResult: Codable {
    let name: String
    let count: Int
    let wallNanoseconds: UInt64
}

private struct BenchResult: Codable {
    let name: String
    let ticks: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let peakLiveBlocks: Int
    let peakLiveBytes: Int
    let peakReservedBytes: Int
    let peakPhysicalFootprint: UInt64
    let phases: [BenchPhaseResult]

    init(
        name: String,
        ticks: Int,
        wallNanoseconds: UInt64,
        cpuNanoseconds: UInt64,
        peakLiveBlocks: Int,
        peakLiveBytes: Int,
        peakReservedBytes: Int,
        peakPhysicalFootprint: UInt64,
        phases: [BenchPhaseResult]
    ) {
        self.name = name
        self.ticks = ticks
        self.wallNanoseconds = wallNanoseconds
        self.cpuNanoseconds = cpuNanoseconds
        self.peakLiveBlocks = peakLiveBlocks
        self.peakLiveBytes = peakLiveBytes
        self.peakReservedBytes = peakReservedBytes
        self.peakPhysicalFootprint = peakPhysicalFootprint
        self.phases = phases
    }
}

@main
private struct MactopBench {
    private static let subsystemNames = ["cpu", "ram", "gpu", "power", "net"]

    static func main() {
        let configuration = BenchConfiguration(environment: ProcessInfo.processInfo.environment)
        if let subsystem = subsystemArgument() {
            let result = measureSubsystem(named: subsystem, configuration: configuration)
            do {
                let data = try JSONEncoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                writeError("failed to encode \(subsystem) benchmark: \(error)", status: 1)
            }
            return
        }

        let start = DispatchTime.now().uptimeNanoseconds
        var children: [(process: Process, output: Pipe)] = []
        for subsystem in subsystemNames {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--subsystem", subsystem]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            do {
                try process.run()
            } catch {
                writeError("failed to launch \(subsystem) benchmark: \(error)", status: 1)
            }
            children.append((process, output))
        }

        var results: [BenchResult] = []
        for child in children {
            child.process.waitUntilExit()
            guard child.process.terminationStatus == 0,
                  let output = String(
                      data: child.output.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8
                  )?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let data = output.data(using: .utf8),
                  let result = try? JSONDecoder().decode(BenchResult.self, from: data) else {
                writeError("benchmark child failed with status \(child.process.terminationStatus)", status: 1)
            }
            results.append(result)
        }

        print("mactop core benchmark")
        let totalWall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        print("duration=\(formatSeconds(configuration.duration))s interval=\(formatSeconds(configuration.interval))s warmup_ticks=\(configuration.warmupTicks) concurrent_subsystems=\(subsystemNames.count) total_wall=\(formatSeconds(totalWall))s public_ip=disabled")
        print("Each subsystem runs in an isolated headless child process concurrently. Memory columns are allocator/task high-water deltas.")
        print("")
        print("subsystem  ticks  wall_ms  cpu_ms  cpu_ms/tick  peak_live_allocs  peak_live_bytes  peak_reserved  peak_footprint")
        for name in subsystemNames {
            guard let result = results.first(where: { $0.name == name }) else { continue }
            print(format(result))
        }
        print("")
        print("phase                         count  wall_ms  wall_ms/tick")
        for subsystem in ["power", "gpu"] {
            guard let result = results.first(where: { $0.name == subsystem }) else { continue }
            print("\(subsystem):")
            for phase in result.phases {
                let wallMilliseconds = Double(phase.wallNanoseconds) / 1_000_000
                let perTick = result.ticks > 0 ? wallMilliseconds / Double(result.ticks) : 0
                print("  \(phase.name.padding(toLength: 27, withPad: " ", startingAt: 0)) \(String(format: "%5d", phase.count)) \(String(format: "%8.2f", wallMilliseconds)) \(String(format: "%12.3f", perTick))")
            }
        }
    }

    private static func subsystemArgument() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--subsystem"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let subsystem = CommandLine.arguments[index + 1]
        guard subsystemNames.contains(subsystem) else {
            writeError("unknown benchmark subsystem: \(subsystem)", status: 2)
        }
        return subsystem
    }

    private static func writeError(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }

    private static func measureSubsystem(named name: String, configuration: BenchConfiguration) -> BenchResult {
        switch name {
        case "cpu":
            let reader = CPUUsageReader(updateInterval: configuration.interval)
            return measure(name: name, configuration: configuration) {
                _ = reader.readCPUUsageDetail(includeHistory: true)
            }
        case "ram":
            let reader = RAMUsageReader(updateInterval: configuration.interval)
            return measure(name: name, configuration: configuration) {
                _ = reader.readRAMUsageDetail(includeHistory: true)
            }
        case "gpu":
            let phaseRecorder = CoreReadPhaseRecorder()
            let reader = GPUUsageReader(updateInterval: configuration.interval, phaseRecorder: phaseRecorder)
            return measure(name: name, configuration: configuration, sample: {
                _ = reader.readGPUUsageDetail(includeHistory: true)
            }, phaseRecorder: phaseRecorder)
        case "power":
            let phaseRecorder = CoreReadPhaseRecorder()
            let reader = PowerTelemetryReader(updateInterval: configuration.interval, phaseRecorder: phaseRecorder)
            return measure(name: name, configuration: configuration, sample: {
                _ = reader.readPowerUsageDetail(includeHistory: true)
            }, phaseRecorder: phaseRecorder)
        case "net":
            let reader = NetworkInterfaceReader(updateInterval: configuration.interval, fetchPublicIP: false)
            return measure(name: name, configuration: configuration) {
                _ = reader.readNetworkUsageDetail(includeHistory: true)
            }
        default:
            fatalError("unsupported benchmark subsystem: \(name)")
        }
    }

    private static func measure(
        name: String,
        configuration: BenchConfiguration,
        sample: () -> Void,
        phaseRecorder: CoreReadPhaseRecorder? = nil
    ) -> BenchResult {
        for _ in 0..<configuration.warmupTicks {
            autoreleasepool(invoking: sample)
        }
        phaseRecorder?.reset()

        let baseline = allocationSnapshot()
        let startWall = DispatchTime.now().uptimeNanoseconds
        let intervalNanoseconds = UInt64(configuration.interval * 1_000_000_000)
        let deadline = startWall + UInt64(configuration.duration * 1_000_000_000)
        var nextTick = startWall
        var ticks = 0
        var cpuNanoseconds: UInt64 = 0
        var peak = baseline

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let sampleStartCPU = threadCPUTimeNanoseconds()
            autoreleasepool(invoking: sample)
            let sampleEndCPU = threadCPUTimeNanoseconds()
            ticks += 1
            if sampleEndCPU >= sampleStartCPU {
                cpuNanoseconds += sampleEndCPU - sampleStartCPU
            }
            peak = higherAllocationSnapshot(peak, allocationSnapshot())

            nextTick += intervalNanoseconds
            let now = DispatchTime.now().uptimeNanoseconds
            if nextTick > now {
                let sleepMicroseconds = min((nextTick - now) / 1_000, UInt64(UInt32.max))
                usleep(UInt32(sleepMicroseconds))
            } else {
                nextTick = now
            }
        }

        let endWall = DispatchTime.now().uptimeNanoseconds
        return BenchResult(
            name: name,
            ticks: ticks,
            wallNanoseconds: endWall - startWall,
            cpuNanoseconds: cpuNanoseconds,
            peakLiveBlocks: Swift.max(0, peak.liveBlocks - baseline.liveBlocks),
            peakLiveBytes: Swift.max(0, peak.liveBytes - baseline.liveBytes),
            peakReservedBytes: Swift.max(0, peak.reservedBytes - baseline.reservedBytes),
            peakPhysicalFootprint: peak.physicalFootprint >= baseline.physicalFootprint
                ? peak.physicalFootprint - baseline.physicalFootprint
                : 0,
            phases: phaseRecorder?.snapshot().map {
                BenchPhaseResult(name: $0.name, count: $0.count, wallNanoseconds: $0.wallNanoseconds)
            } ?? []
        )
    }

    private static func allocationSnapshot() -> AllocationSnapshot {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return AllocationSnapshot(
            liveBlocks: Int(statistics.blocks_in_use),
            liveBytes: Int(statistics.size_in_use),
            reservedBytes: Int(statistics.size_allocated),
            physicalFootprint: taskPhysicalFootprint()
        )
    }

    private static func taskPhysicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func threadCPUTimeNanoseconds() -> UInt64 {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(THREAD_INFO_MAX)
        let thread = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.user_time.seconds) * 1_000_000_000
            + UInt64(info.user_time.microseconds) * 1_000
            + UInt64(info.system_time.seconds) * 1_000_000_000
            + UInt64(info.system_time.microseconds) * 1_000
    }

    private static func higherAllocationSnapshot(
        _ current: AllocationSnapshot,
        _ candidate: AllocationSnapshot
    ) -> AllocationSnapshot {
        AllocationSnapshot(
            liveBlocks: Swift.max(current.liveBlocks, candidate.liveBlocks),
            liveBytes: Swift.max(current.liveBytes, candidate.liveBytes),
            reservedBytes: Swift.max(current.reservedBytes, candidate.reservedBytes),
            physicalFootprint: Swift.max(current.physicalFootprint, candidate.physicalFootprint)
        )
    }

    private static func format(_ result: BenchResult) -> String {
        let wallMilliseconds = Double(result.wallNanoseconds) / 1_000_000
        let cpuMilliseconds = Double(result.cpuNanoseconds) / 1_000_000
        let perTick = result.ticks > 0 ? cpuMilliseconds / Double(result.ticks) : 0
        return [
            result.name.padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%5d", result.ticks),
            String(format: "%8.1f", wallMilliseconds),
            String(format: "%7.2f", cpuMilliseconds),
            String(format: "%11.3f", perTick),
            String(format: "%17d", result.peakLiveBlocks),
            formatBytes(result.peakLiveBytes, width: 16),
            formatBytes(result.peakReservedBytes, width: 14),
            formatBytes(Int(result.peakPhysicalFootprint), width: 15),
        ].joined(separator: " ")
    }

    private static func formatBytes(_ bytes: Int, width: Int) -> String {
        let value: String
        switch bytes {
        case 1_000_000_000...:
            value = String(format: "%.1fG", Double(bytes) / 1_000_000_000)
        case 1_000_000...:
            value = String(format: "%.1fM", Double(bytes) / 1_000_000)
        case 1_000...:
            value = String(format: "%.1fK", Double(bytes) / 1_000)
        default:
            value = "\(bytes)"
        }
        return value.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }
}
