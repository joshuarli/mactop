import Darwin
import Foundation

public struct PlatformNetworkProcessCounter: Sendable {
  public let pid: Int32
  public let name: String
  public let inputBytes: UInt64
  public let outputBytes: UInt64
}

public final class PlatformNetworkProcessReader: @unchecked Sendable {
  private typealias CreateFn =
    @convention(c) (
      CFAllocator?, DispatchQueue,
      @escaping @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    ) -> UnsafeMutableRawPointer?
  private typealias SetFlagsFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
  private typealias AddFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
  private typealias QueryFn =
    @convention(c) (UnsafeMutableRawPointer?, @escaping @convention(block) () -> Void) -> Void
  private typealias DictionaryBlockFn =
    @convention(c) (UnsafeMutableRawPointer?, @escaping @convention(block) (CFDictionary?) -> Void)
    -> Void
  private typealias RemovedBlockFn =
    @convention(c) (UnsafeMutableRawPointer?, @escaping @convention(block) () -> Void) -> Void
  private typealias QueryDescriptionFn =
    @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

  private struct Source {
    var pid: Int32
    var name: String
    var input: UInt64
    var output: UInt64
  }
  private let queue = DispatchQueue(label: "mactop.network-statistics")
  private let handle: UnsafeMutableRawPointer
  private let manager: UnsafeMutableRawPointer
  private let setDescription: DictionaryBlockFn
  private let setCounts: DictionaryBlockFn
  private let setRemoved: RemovedBlockFn
  private let queryDescription: QueryDescriptionFn
  private let queryUpdates: QueryFn
  private let pidKey: CFString
  private let nameKey: CFString
  private let inputKey: CFString
  private let outputKey: CFString
  private var sources: [UInt: Source] = [:]
  private var sourceBlock:
    (@convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)!
  private var descriptionBlocks: [UInt: @convention(block) (CFDictionary?) -> Void] = [:]
  private var countBlocks: [UInt: @convention(block) (CFDictionary?) -> Void] = [:]
  private var removedBlocks: [UInt: @convention(block) () -> Void] = [:]

  public init?() {
    let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
    guard let handle = unsafe dlopen(path, RTLD_NOW) else { return nil }
    self.handle = handle
    guard let create: CreateFn = Self.load(handle, "NStatManagerCreate"),
      let setFlags: SetFlagsFn = Self.load(handle, "NStatManagerSetFlags"),
      let addTCP: AddFn = Self.load(handle, "NStatManagerAddAllTCPWithFilter"),
      let addUDP: AddFn = Self.load(handle, "NStatManagerAddAllUDPWithFilter"),
      let setDescription: DictionaryBlockFn = Self.load(handle, "NStatSourceSetDescriptionBlock"),
      let setCounts: DictionaryBlockFn = Self.load(handle, "NStatSourceSetCountsBlock"),
      let setRemoved: RemovedBlockFn = Self.load(handle, "NStatSourceSetRemovedBlock"),
      let queryDescription: QueryDescriptionFn = Self.load(handle, "NStatSourceQueryDescription"),
      let queryUpdates: QueryFn = Self.load(handle, "NStatManagerQueryAllSourcesUpdate"),
      let pidKey = Self.loadString(handle, "kNStatSrcKeyPID"),
      let nameKey = Self.loadString(handle, "kNStatSrcKeyProcessName"),
      let inputKey = Self.loadString(handle, "kNStatSrcKeyRxBytes"),
      let outputKey = Self.loadString(handle, "kNStatSrcKeyTxBytes")
    else {
      unsafe dlclose(handle)
      return nil
    }
    self.setDescription = setDescription
    self.setCounts = setCounts
    self.setRemoved = setRemoved
    self.queryDescription = queryDescription
    self.queryUpdates = queryUpdates
    self.pidKey = pidKey
    self.nameKey = nameKey
    self.inputKey = inputKey
    self.outputKey = outputKey
    var onSource: ((UnsafeMutableRawPointer?) -> Void)?
    sourceBlock = { source, _ in onSource?(source) }
    guard let manager = create(kCFAllocatorDefault, queue, sourceBlock) else {
      unsafe dlclose(handle)
      return nil
    }
    self.manager = manager
    onSource = { [weak self] source in
      guard let self, let source else { return }
      let key = UInt(bitPattern: source)
      let description: @convention(block) (CFDictionary?) -> Void = { [weak self] dictionary in
        self?.update(key: key, dictionary: dictionary)
      }
      let counts: @convention(block) (CFDictionary?) -> Void = { [weak self] dictionary in
        self?.update(key: key, dictionary: dictionary)
      }
      let removed: @convention(block) () -> Void = { [weak self] in self?.removeSource(key: key) }
      self.descriptionBlocks[key] = description
      self.countBlocks[key] = counts
      self.removedBlocks[key] = removed
      setDescription(source, description)
      setCounts(source, counts)
      setRemoved(source, removed)
      _ = queryDescription(source)
    }
    _ = setFlags(manager, 0)
    guard addTCP(manager, 0, 0) >= 0, addUDP(manager, 0, 0) >= 0 else {
      unsafe dlclose(handle)
      return nil
    }
  }

  deinit { unsafe dlclose(handle) }

  public func refresh(timeout: DispatchTime = .now() + .milliseconds(750)) {
    let done = DispatchSemaphore(value: 0)
    queryUpdates(manager) { done.signal() }
    _ = done.wait(timeout: timeout)
  }

  public func counters() -> [PlatformNetworkProcessCounter] {
    queue.sync {
      sources.values.filter { $0.pid > 0 }.map {
        PlatformNetworkProcessCounter(
          pid: $0.pid, name: $0.name, inputBytes: $0.input, outputBytes: $0.output)
      }
    }
  }

  private func update(key: UInt, dictionary: CFDictionary?) {
    guard let dictionary else { return }
    let values = dictionary as NSDictionary
    let old = sources[key]
    let pid = (values[pidKey] as? NSNumber)?.int32Value ?? old?.pid ?? 0
    guard pid > 0 else { return }
    sources[key] = Source(
      pid: pid, name: (values[nameKey] as? String) ?? old?.name ?? "",
      input: (values[inputKey] as? NSNumber)?.uint64Value ?? old?.input ?? 0,
      output: (values[outputKey] as? NSNumber)?.uint64Value ?? old?.output ?? 0)
  }

  private func removeSource(key: UInt) {
    queue.async { [weak self] in
      self?.sources.removeValue(forKey: key)
      self?.descriptionBlocks.removeValue(forKey: key)
      self?.countBlocks.removeValue(forKey: key)
      self?.removedBlocks.removeValue(forKey: key)
    }
  }

  private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
    guard let symbol = unsafe dlsym(handle, name) else { return nil }
    return unsafe unsafeBitCast(symbol, to: T.self)
  }
  private static func loadString(_ handle: UnsafeMutableRawPointer, _ name: String) -> CFString? {
    guard let symbol = unsafe dlsym(handle, name) else { return nil }
    return unsafe symbol.assumingMemoryBound(to: CFString.self).pointee
  }
}
