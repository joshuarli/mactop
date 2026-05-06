import AppKit
import Darwin
import Foundation

// MARK: - Process data

struct TopProcess {
    var name: String
    var value: Double   // CPU: percent (0–100); RAM: bytes
}

// MARK: - CPU process reader
// Matches Stats exactly: runs `ps -A -c -o pid,pcpu,comm -r` and parses pcpu,
// which is the kernel's own decaying-average CPU% — no delta math needed.

final class CPUProcessReader {
    func read(count n: Int = 8) -> [TopProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments     = ["-A", "-c", "-o", "pid,pcpu,comm", "-r"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = Pipe()
        guard (try? task.run()) != nil else { return [] }
        let data   = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [TopProcess] = []
        var headerSeen = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard headerSeen else { headerSeen = true; continue }
            let s = String(line).trimmingCharacters(in: .whitespaces)
            var rest = s[s.startIndex...]

            guard let pidEnd = rest.firstIndex(of: " "),
                  let pid = Int32(rest[..<pidEnd]) else { continue }
            rest = rest[pidEnd...].drop(while: { $0 == " " })

            guard let pctEnd = rest.firstIndex(of: " ") else { continue }
            let pctStr = String(rest[..<pctEnd]).replacingOccurrences(of: ",", with: ".")
            guard let pct = Double(pctStr) else { continue }
            rest = rest[pctEnd...].drop(while: { $0 == " " })

            let comm = String(rest)
            var name = comm
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               let n = app.localizedName {
                name = n
            }

            results.append(TopProcess(name: name, value: pct))
            if results.count >= n { break }
        }

        return results
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

final class RAMProcessReader {
    func read(count n: Int = 8) -> [TopProcess] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(pidCount) + 16)
        proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))

        return pids.filter { $0 > 0 }.compactMap { pid -> (name: String, bytes: UInt64)? in
            // Try phys_footprint first (matches Activity Monitor); falls back for root procs
            // proc_pid_rusage writes the struct AT buffer (not to *buffer), so we rebind
            // our struct pointer to rusage_info_t? to match the Swift import signature.
            var ru = RusageInfoV2()
            let rusageRet = withUnsafeMutablePointer(to: &ru) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 20) { riPtr in
                    proc_pid_rusage(pid, 2, riPtr)
                }
            }
            let mem: UInt64
            if rusageRet == 0, ru.ri_phys_footprint > 0 {
                mem = ru.ri_phys_footprint
            } else {
                var info = ProcTaskInfo()
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                   Int32(MemoryLayout<ProcTaskInfo>.size)) > 0,
                      info.pti_resident_size > 0 else { return nil }
                mem = info.pti_resident_size
            }
            var nameBuf = [CChar](repeating: 0, count: 1024)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let rawName = String(cString: nameBuf)
            let name = rawName.isEmpty ? "pid \(pid)" : rawName
            return (name: name, bytes: mem)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(n)
        .map { TopProcess(name: $0.name, value: Double($0.bytes)) }
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

    private let nativeReader = NativeReader()
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

        return current
            .compactMap { pid, cur -> (pid: Int32, rate: Double)? in
                guard let p = prev[pid] else { return nil }
                let deltaIn  = cur.in  >= p.in  ? cur.in  - p.in  : 0
                let deltaOut = cur.out >= p.out ? cur.out - p.out : 0
                let rate = Double(deltaIn + deltaOut) / dt
                return rate > 0 ? (pid: pid, rate: rate) : nil
            }
            .sorted { $0.rate > $1.rate }
            .prefix(n)
            .compactMap { item in
                let name = current[item.pid]?.name ?? ""
                return name.isEmpty ? nil : TopProcess(name: name, value: item.rate)
            }
    }
}
