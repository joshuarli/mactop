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
// Shells out to nettop (the only user-space tool that reports per-process
// network bytes without root or a kernel extension). Tracks cumulative-byte
// deltas between calls to produce bytes/sec rates.

final class NetProcessReader {
    private var prev:     [Int32: (in: UInt64, out: UInt64)] = [:]
    private var prevTime: Date = .distantPast

    func read(count n: Int = 8) -> [TopProcess] {
        let now = Date()
        let dt  = now.timeIntervalSince(prevTime)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments     = ["-l", "1", "-P", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var current: [Int32: (in: UInt64, out: UInt64)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3 else { continue }
            // nettop process names may contain spaces, so parse byte columns
            // from the right and treat everything before them as the key.
            let key = cols.dropLast(2).joined(separator: " ")
            guard let dotIdx = key.lastIndex(of: "."),
                  let pid    = Int32(key[key.index(after: dotIdx)...]),
                  let inB    = UInt64(cols[cols.count - 2]),
                  let outB   = UInt64(cols[cols.count - 1]) else { continue }
            let prev = current[pid] ?? (in: 0, out: 0)
            current[pid] = (in: prev.in + inB, out: prev.out + outB)
        }

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
                var buf = [CChar](repeating: 0, count: 1024)
                proc_name(item.pid, &buf, UInt32(buf.count))
                let name = String(cString: buf)
                return name.isEmpty ? nil : TopProcess(name: name, value: item.rate)
            }
    }
}
