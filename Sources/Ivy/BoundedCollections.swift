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
}

struct BoundedDictionary<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var storage: [Key: Value]
    // Parallel array of keys — O(1) random access for sampling, O(1) swap-remove
    // by consulting `keyIndex` below. Order is NOT insertion order after
    // swap-removes; callers that need oldest-first semantics should not use this.
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
                        // Fallback eviction: evict one pseudo-random entry to make
                        // room. Callers (e.g. ProfitWeightedStore) should make
                        // explicit room via `removeValue` before inserting; this
                        // path is a safety valve.
                        let evictCount = Swift.max(capacity / 4, 1)
                        for _ in 0..<Swift.min(evictCount, keys_.count) {
                            let evicted = keys_[keys_.count - 1]
                            storage.removeValue(forKey: evicted)
                            keyIndex.removeValue(forKey: evicted)
                            keys_.removeLast()
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

    /// Return up to `count` random keys in O(count) — never allocates the full
    /// key set. Samples with replacement when count >= storage.count.
    func randomSampleKeys(count sampleCount: Int) -> [Key] {
        let n = keys_.count
        guard n > 0, sampleCount > 0 else { return [] }
        if sampleCount >= n {
            return Array(keys_)
        }
        var result: [Key] = []
        result.reserveCapacity(sampleCount)
        var seen: Set<Int> = []
        seen.reserveCapacity(sampleCount)
        // Reservoir-free rejection sampling: n is always > sampleCount here,
        // so collisions are rare.
        while result.count < sampleCount {
            let idx = Int.random(in: 0..<n)
            if seen.insert(idx).inserted {
                result.append(keys_[idx])
            }
        }
        return result
    }

    private mutating func removeKeyTracking(_ key: Key) {
        guard let idx = keyIndex.removeValue(forKey: key) else { return }
        let lastIdx = keys_.count - 1
        if idx != lastIdx {
            let lastKey = keys_[lastIdx]
            keys_[idx] = lastKey
            keyIndex[lastKey] = idx
        }
        keys_.removeLast()
    }
}
