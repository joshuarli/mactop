import Darwin
import Foundation

// MARK: - Process data

struct TopProcess {
    var pid: Int32
    var name: String
    var value: Double   // CPU: percent (0–100); RAM: bytes

    init(pid: Int32 = 0, name: String, value: Double) {
        self.pid = pid
        self.name = name
        self.value = value
    }
}

// MARK: - CPU process reader
// Two paths selected once at init by probing proc_pid_rusage on PID 1 (root-owned launchd):
//
// Native path (com.apple.system-task-ports.read or setuid root):
//   Same-user procs → proc_pid_rusage ns delta (true instantaneous %).
//   Cross-user procs → sysctl p_pctcpu decay average (best available natively).
//
// PS path (no entitlement — the common case):
//   Runs /bin/ps -Aceo pid,pcpu,comm -r (setuid root, so sees all processes).
//   Returns p_pctcpu-based values for every process, consistent across users.

// FSCALE on Darwin/macOS: 1 << FSHIFT where FSHIFT=11, so FSCALE=2048.
private let kFScale: Double = 2048.0

private func allKinfoPctcpu() -> [Int32: UInt32] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    let stride = MemoryLayout<kinfo_proc>.stride
    let capacity = size / stride + 4
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    var actualSize = capacity * stride
    guard sysctl(&mib, 4, &buf, &actualSize, nil, 0) == 0 else { return [:] }
    let found = actualSize / stride
    var result = [Int32: UInt32]()
    result.reserveCapacity(found)
    for p in buf.prefix(found) {
        let pid = p.kp_proc.p_pid
        guard pid > 0 else { continue }
        result[pid] = UInt32(p.kp_proc.p_pctcpu)
    }
    return result
}

final class CPUProcessReader {
    // Probe cross-user rusage access once. proc_pid_rusage on PID 1 (launchd, always
    // root-owned) succeeds only with com.apple.system-task-ports.read or setuid root.
    private let nativeCrossUser: Bool = {
        var ru = RusageInfoV2()
        return withUnsafeMutablePointer(to: &ru) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { riPtr in
                proc_pid_rusage(1, 2, riPtr) == 0
            }
        }
    }()

    private var previous: [Int32: (time: UInt64, start: UInt64)] = [:]
    private var previousTime: TimeInterval?
    private var nameCache: [Int32: String] = [:]

    func read(count n: Int = 8) -> [TopProcess] {
        nativeCrossUser ? readNative(count: n) : readPS(count: n)
    }

    private func readNative(count n: Int) -> [TopProcess] {
        let now = ProcessInfo.processInfo.systemUptime
        let kinfo = allKinfoPctcpu()
        guard !kinfo.isEmpty else { return [] }

        var current: [Int32: (time: UInt64, start: UInt64)] = [:]
        current.reserveCapacity(kinfo.count)
        var top: [TopProcess] = []
        let elapsed = previousTime.map { now - $0 } ?? 0

        for pid in kinfo.keys {
            if let rusage = processRusage(pid: pid) {
                let totalTime = rusage.ri_user_time + rusage.ri_system_time
                current[pid] = (time: totalTime, start: rusage.ri_proc_start_abstime)

                guard let old = previous[pid],
                      let pct = cpuDelta(
                          current: (time: totalTime, start: rusage.ri_proc_start_abstime),
                          previous: old,
                          elapsed: elapsed
                      ) else { continue }
                insertTop(TopProcess(pid: pid, name: processName(pid: pid), value: pct), into: &top, count: n) {
                    $0.value > $1.value
                }
            } else if let pctcpu = kinfo[pid], pctcpu > 0 {
                let pct = Double(pctcpu) / kFScale * 100.0
                insertTop(TopProcess(pid: pid, name: processName(pid: pid), value: pct), into: &top, count: n) {
                    $0.value > $1.value
                }
            }
        }

        previous = current
        nameCache = nameCache.filter { kinfo[$0.key] != nil }
        previousTime = now
        return top
    }

    private func readPS(count n: Int) -> [TopProcess] {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-Aceo", "pid,pcpu,comm", "-r"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        defer {
            outPipe.fileHandleForReading.closeFile()
            (task.standardError as? Pipe)?.fileHandleForReading.closeFile()
        }
        do { try task.run() } catch { return [] }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return parsePSOutput(output, count: n).map { entry in
            TopProcess(pid: entry.pid, name: processName(pid: entry.pid, fallback: entry.comm), value: entry.pct)
        }
    }

    private func processName(pid: Int32, fallback: String = "") -> String {
        if let cached = nameCache[pid] { return cached }
        let name = displayName(pid: pid)
        // displayName returns "pid NNN" when proc_name yields nothing; prefer ps comm in that case
        let resolved = name == "pid \(pid)" && !fallback.isEmpty ? fallback : name
        nameCache[pid] = resolved
        return resolved
    }
}

// MARK: - RAM process reader
// Uses proc_pid_rusage → ri_phys_footprint, which matches Activity Monitor / top "MEM".
// Falls back to pti_resident_size for root-owned processes that deny access.

// Mirrors rusage_info_v2 from <sys/resource.h> exactly (160 bytes).
private struct RusageInfoV2 {
    var ri_uuid: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                  UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var ri_user_time:             UInt64 = 0
    var ri_system_time:           UInt64 = 0
    var ri_pkg_idle_wkups:        UInt64 = 0
    var ri_interrupt_wkups:       UInt64 = 0
    var ri_pageins:               UInt64 = 0
    var ri_wired_size:            UInt64 = 0
    var ri_resident_size:         UInt64 = 0
    var ri_phys_footprint:        UInt64 = 0
    var ri_proc_start_abstime:    UInt64 = 0
    var ri_proc_exit_abstime:     UInt64 = 0
    var ri_child_user_time:       UInt64 = 0
    var ri_child_system_time:     UInt64 = 0
    var ri_child_pkg_idle_wkups:  UInt64 = 0
    var ri_child_interrupt_wkups: UInt64 = 0
    var ri_child_pageins:         UInt64 = 0
    var ri_child_elapsed_abstime: UInt64 = 0
    var ri_diskio_bytesread:      UInt64 = 0
    var ri_diskio_byteswritten:   UInt64 = 0
}

private struct ProcTaskInfo {
    var pti_virtual_size: UInt64   = 0
    var pti_resident_size: UInt64  = 0
    var pti_total_user: UInt64     = 0
    var pti_total_system: UInt64   = 0
    var pti_threads_user: UInt64   = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32          = 0
    var pti_faults: Int32          = 0
    var pti_pageins: Int32         = 0
    var pti_cow_faults: Int32      = 0
    var pti_messages_sent: Int32   = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32   = 0
    var pti_syscalls_unix: Int32   = 0
    var pti_csw: Int32             = 0
    var pti_threadnum: Int32       = 0
    var pti_numrunning: Int32      = 0
    var pti_priority: Int32        = 0
}

private let PROC_PIDTASKINFO: Int32 = 4

private func processRusage(pid: Int32) -> RusageInfoV2? {
    var ru = RusageInfoV2()
    let ret = withUnsafeMutablePointer(to: &ru) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 20) { riPtr in
            proc_pid_rusage(pid, 2, riPtr)
        }
    }
    return ret == 0 ? ru : nil
}

func insertTop<T>(_ value: T, into top: inout [T], count: Int, by areInDescendingOrder: (T, T) -> Bool) {
    guard count > 0 else { return }
    top.append(value)
    top.sort(by: areInDescendingOrder)
    if top.count > count { top.removeLast() }
}

// Returns CPU% for one process given two rusage snapshots, or nil if the delta is unusable
// (elapsed zero, PID reused since last sample, or time went backwards).
func cpuDelta(
    current: (time: UInt64, start: UInt64),
    previous: (time: UInt64, start: UInt64),
    elapsed: TimeInterval
) -> Double? {
    guard elapsed > 0,
          current.start == previous.start,
          current.time > previous.time else { return nil }
    return Double(current.time - previous.time) / 1_000_000_000.0 / elapsed * 100.0
}

// Parses /bin/ps -Aceo pid,pcpu,comm -r output into raw (pid, pct, comm) tuples.
// Skips the header line, stops at the first 0% entry (output is sorted descending),
// and handles comma decimal separators for non-English locales.
func parsePSOutput(_ output: String, count: Int) -> [(pid: Int32, pct: Double, comm: String)] {
    var results: [(pid: Int32, pct: Double, comm: String)] = []
    var skipHeader = true
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        if skipHeader { skipHeader = false; continue }
        let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
        guard parts.count >= 3,
              let pid = Int32(parts[0]),
              let pct = Double(parts[1].replacingOccurrences(of: ",", with: "."))
        else { continue }
        guard pct > 0 else { break }
        results.append((pid: pid, pct: pct, comm: parts[2...].joined(separator: " ")))
        if results.count >= count { break }
    }
    return results
}

final class RAMProcessReader {
    private var nameCache: [Int32: String] = [:]

    func read(count n: Int = 8) -> [TopProcess] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(pidCount) + 16)
        let bytes = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        let found = max(0, Int(bytes) / MemoryLayout<Int32>.size)
        var top: [TopProcess] = []
        var activePIDs = Set<Int32>()

        for pid in pids.prefix(found) where pid > 0 {
            activePIDs.insert(pid)
            // Try phys_footprint first (matches Activity Monitor); falls back for root procs
            // proc_pid_rusage writes the struct AT buffer (not to *buffer), so we rebind
            // our struct pointer to rusage_info_t? to match the Swift import signature.
            let mem: UInt64
            if let ru = processRusage(pid: pid), ru.ri_phys_footprint > 0 {
                mem = ru.ri_phys_footprint
            } else {
                var info = ProcTaskInfo()
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                   Int32(MemoryLayout<ProcTaskInfo>.size)) > 0,
                      info.pti_resident_size > 0 else { continue }
                mem = info.pti_resident_size
            }

            insertTop(TopProcess(pid: pid, name: processName(pid: pid), value: Double(mem)), into: &top, count: n) {
                $0.value > $1.value
            }
        }

        nameCache = nameCache.filter { activePIDs.contains($0.key) }
        return top
    }

    private func processName(pid: Int32) -> String {
        if let cached = nameCache[pid] { return cached }

        let name = displayName(pid: pid)
        nameCache[pid] = name
        return name
    }
}

private func displayName(pid: Int32) -> String {
    var nameBuf = [CChar](repeating: 0, count: 1024)
    proc_name(pid, &nameBuf, UInt32(nameBuf.count))
    let rawName = String(cString: nameBuf)

    if rawName == "plugin-container" {
        return bundleDisplayName(pid: pid) ?? rawName
    }

    if rawName.isVersionNumber, let ownerName = versionedExecutableOwnerName(pid: pid, rawName: rawName) {
        return ownerName
    }

    return rawName.isEmpty ? "pid \(pid)" : rawName
}

private func bundleDisplayName(pid: Int32) -> String? {
    var pathBuf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }

    var url = URL(fileURLWithPath: String(cString: pathBuf))
    while url.path != "/" {
        if url.pathExtension == "app" {
            if let bundle = Bundle(url: url),
               let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
            let fallback = url.deletingPathExtension().lastPathComponent
            return fallback.isEmpty ? nil : fallback
        }
        url.deleteLastPathComponent()
    }

    return nil
}

private func versionedExecutableOwnerName(pid: Int32, rawName: String) -> String? {
    var pathBuf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }

    let url = URL(fileURLWithPath: String(cString: pathBuf))
    let components = url.pathComponents
    guard components.last == rawName,
          components.count >= 3,
          components[components.count - 2] == "versions" else { return nil }

    let owner = components[components.count - 3]
    guard !owner.isEmpty else { return nil }
    return owner.prefix(1).uppercased() + owner.dropFirst()
}

private extension String {
    var isVersionNumber: Bool {
        range(of: #"^[0-9]+(\.[0-9]+)+$"#, options: .regularExpression) != nil
    }
}

// MARK: - Net process reader
// Uses macOS' private NetworkStatistics framework, the same data source behind
// nettop, but keeps it in-process instead of parsing a subprocess' output.

final class NetProcessReader {
    private final class NativeReader {
        private typealias NStatManagerCreateFn = @convention(c) (
            CFAllocator?,
            DispatchQueue,
            @escaping @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        ) -> UnsafeMutableRawPointer?
        private typealias NStatManagerSetFlagsFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        private typealias NStatManagerAddAllWithFilterFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
        private typealias NStatManagerQueryAllSourcesUpdateFn = @convention(c) (
            UnsafeMutableRawPointer?,
            @escaping @convention(block) () -> Void
        ) -> Void
        private typealias NStatSourceSetDictionaryBlockFn = @convention(c) (
            UnsafeMutableRawPointer?,
            @escaping @convention(block) (CFDictionary?) -> Void
        ) -> Void
        private typealias NStatSourceSetRemovedBlockFn = @convention(c) (
            UnsafeMutableRawPointer?,
            @escaping @convention(block) () -> Void
        ) -> Void
        private typealias NStatSourceQueryDescriptionFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

        private struct SourceStats {
            var pid: Int32
            var name: String
            var rx: UInt64
            var tx: UInt64
        }

        private let queue = DispatchQueue(label: "mactop.network-statistics")
        private let handle: UnsafeMutableRawPointer
        private let manager: UnsafeMutableRawPointer
        private let setDescriptionBlock: NStatSourceSetDictionaryBlockFn
        private let setCountsBlock: NStatSourceSetDictionaryBlockFn
        private let setRemovedBlock: NStatSourceSetRemovedBlockFn
        private let queryDescription: NStatSourceQueryDescriptionFn
        private let queryUpdates: NStatManagerQueryAllSourcesUpdateFn
        private let pidKey: CFString
        private let processNameKey: CFString
        private let rxBytesKey: CFString
        private let txBytesKey: CFString
        private var sources: [UInt: SourceStats] = [:]
        private var sourceBlock: (@convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)!
        private var descriptionBlocks: [UInt: @convention(block) (CFDictionary?) -> Void] = [:]
        private var countsBlocks: [UInt: @convention(block) (CFDictionary?) -> Void] = [:]
        private var removedBlocks: [UInt: @convention(block) () -> Void] = [:]

        init?() {
            let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
            guard let handle = dlopen(path, RTLD_NOW) else { return nil }
            self.handle = handle

            guard let create: NStatManagerCreateFn = Self.load(handle, "NStatManagerCreate"),
                  let setFlags: NStatManagerSetFlagsFn = Self.load(handle, "NStatManagerSetFlags"),
                  let addTCP: NStatManagerAddAllWithFilterFn = Self.load(handle, "NStatManagerAddAllTCPWithFilter"),
                  let addUDP: NStatManagerAddAllWithFilterFn = Self.load(handle, "NStatManagerAddAllUDPWithFilter"),
                  let setDescriptionBlock: NStatSourceSetDictionaryBlockFn = Self.load(handle, "NStatSourceSetDescriptionBlock"),
                  let setCountsBlock: NStatSourceSetDictionaryBlockFn = Self.load(handle, "NStatSourceSetCountsBlock"),
                  let setRemovedBlock: NStatSourceSetRemovedBlockFn = Self.load(handle, "NStatSourceSetRemovedBlock"),
                  let queryDescription: NStatSourceQueryDescriptionFn = Self.load(handle, "NStatSourceQueryDescription"),
                  let queryUpdates: NStatManagerQueryAllSourcesUpdateFn = Self.load(handle, "NStatManagerQueryAllSourcesUpdate"),
                  let pidKey = Self.loadString(handle, "kNStatSrcKeyPID"),
                  let processNameKey = Self.loadString(handle, "kNStatSrcKeyProcessName"),
                  let rxBytesKey = Self.loadString(handle, "kNStatSrcKeyRxBytes"),
                  let txBytesKey = Self.loadString(handle, "kNStatSrcKeyTxBytes") else {
                dlclose(handle)
                return nil
            }

            self.setDescriptionBlock = setDescriptionBlock
            self.setCountsBlock = setCountsBlock
            self.setRemovedBlock = setRemovedBlock
            self.queryDescription = queryDescription
            self.queryUpdates = queryUpdates
            self.pidKey = pidKey
            self.processNameKey = processNameKey
            self.rxBytesKey = rxBytesKey
            self.txBytesKey = txBytesKey

            var onSource: ((UnsafeMutableRawPointer?) -> Void)?
            sourceBlock = { source, _ in onSource?(source) }
            guard let manager = create(kCFAllocatorDefault, queue, sourceBlock) else {
                dlclose(handle)
                return nil
            }
            self.manager = manager

            onSource = { [weak self] source in
                guard let self, let source else { return }
                let key = UInt(bitPattern: source)
                let descriptionBlock: @convention(block) (CFDictionary?) -> Void = { [weak self] dict in
                    self?.update(key: key, dict)
                }
                let countsBlock: @convention(block) (CFDictionary?) -> Void = { [weak self] dict in
                    self?.update(key: key, dict)
                }
                let removedBlock: @convention(block) () -> Void = { [weak self] in
                    self?.queue.async {
                        self?.sources.removeValue(forKey: key)
                        self?.descriptionBlocks.removeValue(forKey: key)
                        self?.countsBlocks.removeValue(forKey: key)
                        self?.removedBlocks.removeValue(forKey: key)
                    }
                }
                self.descriptionBlocks[key] = descriptionBlock
                self.countsBlocks[key] = countsBlock
                self.removedBlocks[key] = removedBlock
                setDescriptionBlock(source, descriptionBlock)
                setCountsBlock(source, countsBlock)
                setRemovedBlock(source, removedBlock)
                _ = queryDescription(source)
            }

            _ = setFlags(manager, 0)
            guard addTCP(manager, 0, 0) >= 0,
                  addUDP(manager, 0, 0) >= 0 else {
                dlclose(handle)
                return nil
            }
        }

        deinit {
            dlclose(handle)
        }

        func read() -> [Int32: (name: String, in: UInt64, out: UInt64)] {
            queue.sync {
                sources.values.reduce(into: [:]) { result, source in
                    guard source.pid > 0 else { return }
                    let prev = result[source.pid] ?? (name: source.name, in: 0, out: 0)
                    result[source.pid] = (
                        name: prev.name.isEmpty ? source.name : prev.name,
                        in: prev.in + source.rx,
                        out: prev.out + source.tx
                    )
                }
            }
        }

        func refresh(timeout: DispatchTime = .now() + .milliseconds(750)) {
            let done = DispatchSemaphore(value: 0)
            queryUpdates(manager) {
                done.signal()
            }
            _ = done.wait(timeout: timeout)
        }

        private func update(key: UInt, _ dictionary: CFDictionary?) {
            guard let dictionary else { return }
            let dict = dictionary as NSDictionary
            let current = sources[key]
            let pid = (dict[pidKey] as? NSNumber)?.int32Value ?? current?.pid ?? 0
            guard pid > 0 else { return }
            let stats = current ?? SourceStats(pid: pid, name: "", rx: 0, tx: 0)
            let name = dict[processNameKey] as? String ?? stats.name
            let rx = (dict[rxBytesKey] as? NSNumber)?.uint64Value ?? stats.rx
            let tx = (dict[txBytesKey] as? NSNumber)?.uint64Value ?? stats.tx
            sources[key] = SourceStats(pid: pid, name: name, rx: rx, tx: tx)
        }

        private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func loadString(_ handle: UnsafeMutableRawPointer, _ name: String) -> CFString? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return symbol.assumingMemoryBound(to: CFString.self).pointee
        }
    }

    private lazy var nativeReader = NativeReader()
    private var prev:     [Int32: (name: String, in: UInt64, out: UInt64)] = [:]
    private var prevTime: Date = .distantPast

    func read(count n: Int = 8) -> [TopProcess] {
        guard let nativeReader else { return [] }
        let now = Date()
        let dt  = now.timeIntervalSince(prevTime)
        nativeReader.refresh()
        let current = nativeReader.read()

        defer { prev = current; prevTime = now }
        guard dt > 0, !prev.isEmpty else { return [] }

        var top: [(pid: Int32, rate: Double)] = []
        for (pid, cur) in current {
            guard let p = prev[pid] else { continue }
            let deltaIn  = cur.in  >= p.in  ? cur.in  - p.in  : 0
            let deltaOut = cur.out >= p.out ? cur.out - p.out : 0
            let rate = Double(deltaIn + deltaOut) / dt
            guard rate > 0 else { continue }
            insertTop((pid: pid, rate: rate), into: &top, count: n) {
                $0.rate > $1.rate
            }
        }

        return top.compactMap { item in
            let name = current[item.pid]?.name ?? ""
            return name.isEmpty ? nil : TopProcess(pid: item.pid, name: name, value: item.rate)
        }
    }
}
