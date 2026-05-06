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
// Uses proc_pidinfo(PROC_PIDTASKINFO) to get resident size, sorted descending.

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
            var info = ProcTaskInfo()
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<ProcTaskInfo>.size))
            guard ret > 0, info.pti_resident_size > 0 else { return nil }
            var nameBuf = [CChar](repeating: 0, count: 1024)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = String(cString: nameBuf)
            return (name: name.isEmpty ? "pid \(pid)" : name, bytes: info.pti_resident_size)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(n)
        .map { TopProcess(name: $0.name, value: Double($0.bytes)) }
    }
}
