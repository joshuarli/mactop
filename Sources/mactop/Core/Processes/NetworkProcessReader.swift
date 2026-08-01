import Darwin
import Foundation

// Reads per-process network byte counters from Apple's private NetworkStatistics ABI;
// the reader stays dormant until the network popup requests a visible process list.
final class NetworkProcessReader {
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
                    self?.updateNetworkSourceStatistics(key: key, dict)
                }
                let countsBlock: @convention(block) (CFDictionary?) -> Void = { [weak self] dict in
                    self?.updateNetworkSourceStatistics(key: key, dict)
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

        func readNetworkProcessByteCounters() -> [Int32: (name: String, in: UInt64, out: UInt64)] {
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

        func refreshNetworkStatistics(timeout: DispatchTime = .now() + .milliseconds(750)) {
            let done = DispatchSemaphore(value: 0)
            queryUpdates(manager) {
                done.signal()
            }
            _ = done.wait(timeout: timeout)
        }

        private func updateNetworkSourceStatistics(key: UInt, _ dictionary: CFDictionary?) {
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

    func readTopNetworkProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
        guard let nativeReader else { return [] }
        let now = Date()
        let dt  = now.timeIntervalSince(prevTime)
        nativeReader.refreshNetworkStatistics()
        let current = nativeReader.readNetworkProcessByteCounters()

        defer { prev = current; prevTime = now }
        guard dt > 0, !prev.isEmpty else { return [] }

        var top: [(pid: Int32, rate: Double)] = []
        for (pid, cur) in current {
            guard let p = prev[pid] else { continue }
            let deltaIn  = cur.in  >= p.in  ? cur.in  - p.in  : 0
            let deltaOut = cur.out >= p.out ? cur.out - p.out : 0
            let rate = Double(deltaIn + deltaOut) / dt
            guard rate > 0 else { continue }
            insertRankedMetric((pid: pid, rate: rate), into: &top, count: limit) {
                $0.rate > $1.rate
            }
        }

        return top.compactMap { item in
            let name = current[item.pid]?.name ?? ""
            return name.isEmpty ? nil : RankedProcessMetric(pid: item.pid, name: name, value: item.rate)
        }
    }
}
