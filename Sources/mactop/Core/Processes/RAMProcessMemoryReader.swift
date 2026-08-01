import Darwin
import Foundation

final class RAMProcessMemoryReader {
    private var nameCache: [Int32: String] = [:]

    func readTopRAMProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(pidCount) + 16)
        let bytes = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        let found = max(0, Int(bytes) / MemoryLayout<Int32>.size)
        var top: [RankedProcessMetric] = []
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

            insertRankedMetric(RankedProcessMetric(pid: pid, name: processName(pid: pid), value: Double(mem)), into: &top, count: limit) {
                $0.value > $1.value
            }
        }
        nameCache = nameCache.filter { activePIDs.contains($0.key) }
        return top
    }

    private func processName(pid: Int32) -> String {
        if let cached = nameCache[pid] { return cached }

        let name = processDisplayName(pid: pid)
        nameCache[pid] = name
        return name
    }
}
