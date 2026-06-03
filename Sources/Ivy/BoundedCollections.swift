import Foundation

struct BoundedSet<Element: Hashable & Sendable>: Sendable {
    private var storage: Set<Element>
    private var insertionOrder: [Element]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Set(minimumCapacity: min(capacity, 1024))
        self.insertionOrder = []
        self.insertionOrder.reserveCapacity(min(capacity, 1024))
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    func contains(_ element: Element) -> Bool {
        storage.contains(element)
    }

    @discardableResult
    mutating func insert(_ element: Element) -> Bool {
        if storage.contains(element) { return false }

        if storage.count >= capacity {
            let evictCount = capacity / 4
            let toRemove = insertionOrder.prefix(evictCount)
            for item in toRemove {
                storage.remove(item)
            }
            insertionOrder.removeFirst(min(evictCount, insertionOrder.count))
        }

        storage.insert(element)
        insertionOrder.append(element)
        return true
    }

    mutating func removeAll() {
        storage.removeAll()
        insertionOrder.removeAll()
    }

    @discardableResult
    mutating func remove(_ element: Element) -> Bool {
        guard storage.remove(element) != nil else { return false }
        insertionOrder.removeAll { $0 == element }
        return true
    }
}

struct BoundedDictionary<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var storage: [Key: Value]
    // Parallel insertion-order array of keys for O(1) random sampling and
    // bounded oldest-first overflow eviction.
    private var keys_: ContiguousArray<Key>
    private var keyIndex: [Key: Int]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Dictionary(minimumCapacity: min(capacity, 1024))
        self.keys_ = []
        self.keys_.reserveCapacity(min(capacity, 1024))
        self.keyIndex = Dictionary(minimumCapacity: min(capacity, 1024))
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var keys: Dictionary<Key, Value>.Keys { storage.keys }
    var values: Dictionary<Key, Value>.Values { storage.values }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let value = newValue {
                if storage[key] == nil {
                    if storage.count >= capacity {
                        // Fallback eviction: shed oldest entries to make room.
                        // Callers (e.g. ProfitWeightedStore) should make explicit
                        // room via `removeValue` before inserting; this path is a
                        // safety valve.
                        let evictCount = Swift.max(capacity / 4, 1)
                        for _ in 0..<Swift.min(evictCount, keys_.count) {
                            removeOldestKeyTracking()
                        }
                    }
                    keyIndex[key] = keys_.count
                    keys_.append(key)
                }
                storage[key] = value
            } else {
                removeKeyTracking(key)
                storage.removeValue(forKey: key)
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        removeKeyTracking(key)
        return storage.removeValue(forKey: key)
    }

    mutating func removeAll() {
        storage.removeAll()
        keys_.removeAll()
        keyIndex.removeAll()
    }

    mutating func removeAll(where predicate: (Key, Value) -> Bool) {
        let toRemove = storage.filter(predicate).map(\.key)
        for key in toRemove {
            removeKeyTracking(key)
            storage.removeValue(forKey: key)
        }
    }

    func filter(_ isIncluded: (Key, Value) -> Bool) -> [(Key, Value)] {
        storage.filter { isIncluded($0.key, $0.value) }.map { ($0.key, $0.value) }
    }

    func max(by areInIncreasingOrder: ((key: Key, value: Value), (key: Key, value: Value)) -> Bool) -> (key: Key, value: Value)? {
        storage.max(by: areInIncreasingOrder)
    }

    func contains(key: Key) -> Bool {
        storage[key] != nil
    }

    private mutating func removeKeyTracking(_ key: Key) {
        guard let idx = keyIndex.removeValue(forKey: key) else { return }
        keys_.remove(at: idx)
        if idx < keys_.count {
            for shiftedIdx in idx..<keys_.count {
                keyIndex[keys_[shiftedIdx]] = shiftedIdx
            }
        }
    }

    private mutating func removeOldestKeyTracking() {
        guard !keys_.isEmpty else { return }
        let evicted = keys_.removeFirst()
        storage.removeValue(forKey: evicted)
        keyIndex.removeValue(forKey: evicted)
        for idx in keys_.indices {
            keyIndex[keys_[idx]] = idx
        }
    }
}

/// Lazy-refill token bucket for per-peer rate limiting.
/// `tryConsume` returns false when starved; state is updated on every call
/// so idle peers retain their full capacity until the next message.
struct TokenBucket: Sendable {
    var tokens: Double
    var lastRefill: ContinuousClock.Instant
    let capacity: Double
    let refillPerSec: Double

    init(capacity: Double, refillPerSec: Double) {
        self.tokens = capacity
        self.lastRefill = .now
        self.capacity = capacity
        self.refillPerSec = refillPerSec
    }

    mutating func tryConsume(_ cost: Double = 1) -> Bool {
        let now = ContinuousClock.Instant.now
        let elapsed = Double((now - lastRefill).components.seconds)
            + Double((now - lastRefill).components.attoseconds) / 1e18
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed * refillPerSec)
            lastRefill = now
        }
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}
