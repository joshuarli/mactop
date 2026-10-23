import Foundation

struct NetworkSourceStore {
  private struct Source {
    let id: UUID
    var pid: Int32?
    var name: String?
    var input: UInt64?
    var output: UInt64?

    var counter: PlatformNetworkProcessCounter? {
      guard let pid, pid > 0, let input, let output else { return nil }
      return PlatformNetworkProcessCounter(
        sourceID: id, pid: pid, name: name ?? "", inputBytes: input, outputBytes: output)
    }
  }

  private var active: [UInt: Source] = [:]
  private var published: Set<UUID> = []
  private var removed: [PlatformNetworkProcessCounter] = []

  mutating func register(key: UInt) -> UUID {
    if let source = active[key] { retire(source) }
    let id = UUID()
    active[key] = Source(id: id)
    return id
  }

  mutating func update(
    key: UInt, sourceID: UUID, pid: Int32? = nil, name: String? = nil,
    input: UInt64? = nil, output: UInt64? = nil
  ) {
    guard var source = active[key], source.id == sourceID else { return }
    source.pid = pid ?? source.pid
    source.name = name ?? source.name
    source.input = input ?? source.input
    source.output = output ?? source.output
    active[key] = source
  }

  @discardableResult
  mutating func remove(key: UInt, sourceID: UUID) -> Bool {
    guard let source = active[key], source.id == sourceID else { return false }
    retire(source)
    active.removeValue(forKey: key)
    return true
  }

  mutating func takeSnapshot() -> [PlatformNetworkProcessCounter] {
    defer { removed.removeAll(keepingCapacity: true) }
    let current = active.values.compactMap(\.counter)
    published = Set(current.map(\.sourceID))
    return current + removed
  }

  private mutating func retire(_ source: Source) {
    if published.remove(source.id) != nil, let counter = source.counter {
      removed.append(counter)
    }
  }
}
