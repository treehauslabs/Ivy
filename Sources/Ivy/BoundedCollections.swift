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
    private var insertionOrder: [Key]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Dictionary(minimumCapacity: min(capacity, 1024))
        self.insertionOrder = []
        self.insertionOrder.reserveCapacity(min(capacity, 1024))
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
                        let evictCount = Swift.max(capacity / 4, 1)
                        let toRemove = insertionOrder.prefix(evictCount)
                        for k in toRemove {
                            storage.removeValue(forKey: k)
                        }
                        insertionOrder.removeFirst(min(evictCount, insertionOrder.count))
                    }
                    insertionOrder.append(key)
                }
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
                insertionOrder.removeAll { $0 == key }
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        insertionOrder.removeAll { $0 == key }
        return storage.removeValue(forKey: key)
    }

    mutating func removeAll() {
        storage.removeAll()
        insertionOrder.removeAll()
    }

    mutating func removeAll(where predicate: (Key, Value) -> Bool) {
        let toRemove = storage.filter(predicate).map(\.key)
        for key in toRemove {
            storage.removeValue(forKey: key)
            insertionOrder.removeAll { $0 == key }
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
}
