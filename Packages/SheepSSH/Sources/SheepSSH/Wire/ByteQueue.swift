// A byte FIFO consumed from the front by offset and compacted lazily.
// Shifting an array per read (removeFirst) is quadratic on big pastes and
// floods; SheepSSH and SSHWorker had grown five hand-written variants of this
// before it was pulled into one type.

public struct ByteQueue: Sendable {
    private var bytes: [UInt8] = []
    private var start = 0
    /// Compact once this much has been consumed and something remains.
    static let compactAfter = 64 * 1024

    public init() {}

    public var count: Int { bytes.count - start }
    public var isEmpty: Bool { count == 0 }

    public mutating func append<C: Collection>(contentsOf more: C) where C.Element == UInt8 {
        bytes.append(contentsOf: more)
    }

    /// The unread bytes, without copying.
    public var unread: ArraySlice<UInt8> { bytes[start...] }

    /// Drops `n` bytes from the front.
    public mutating func consume(_ n: Int) {
        precondition(n >= 0 && n <= count, "ByteQueue.consume past the end")
        start += n
        if start == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            start = 0
        } else if start >= Self.compactAfter {
            bytes.removeFirst(start)
            start = 0
        }
    }

    /// Removes and returns up to `limit` bytes from the front.
    public mutating func take(_ limit: Int) -> [UInt8] {
        let n = min(limit, count)
        let out = Array(bytes[start..<(start + n)])
        consume(n)
        return out
    }

    /// Empties the queue. `keepingCapacity: false` gives the memory back —
    /// what a dead session should do with a multi-megabyte paste buffer.
    public mutating func removeAll(keepingCapacity: Bool = true) {
        bytes.removeAll(keepingCapacity: keepingCapacity)
        start = 0
    }
}
