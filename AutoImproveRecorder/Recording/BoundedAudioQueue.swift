import Foundation

struct BoundedAudioQueue<Element> {
    private var elements: [Element] = []
    private let byteCount: (Element) -> Int
    private let maxBytes: Int

    private(set) var pendingBytes = 0
    private(set) var maxObservedPendingBytes = 0
    private(set) var droppedElements = 0
    private(set) var droppedBytes = 0

    init(maxBytes: Int, byteCount: @escaping (Element) -> Int) {
        precondition(maxBytes > 0, "maxBytes must be positive")
        self.maxBytes = maxBytes
        self.byteCount = byteCount
    }

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }

    mutating func append(_ element: Element) {
        let bytes = max(0, byteCount(element))
        elements.append(element)
        pendingBytes += bytes
        maxObservedPendingBytes = max(maxObservedPendingBytes, pendingBytes)

        while pendingBytes > maxBytes, !elements.isEmpty {
            let removed = elements.removeFirst()
            let removedBytes = max(0, byteCount(removed))
            pendingBytes = max(0, pendingBytes - removedBytes)
            droppedElements += 1
            droppedBytes += removedBytes
        }
    }

    mutating func popFirst() -> Element? {
        guard !elements.isEmpty else { return nil }
        let removed = elements.removeFirst()
        pendingBytes = max(0, pendingBytes - max(0, byteCount(removed)))
        return removed
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        elements.removeAll(keepingCapacity: keepingCapacity)
        pendingBytes = 0
    }

    mutating func reset(keepingCapacity: Bool = false) {
        elements.removeAll(keepingCapacity: keepingCapacity)
        pendingBytes = 0
        maxObservedPendingBytes = 0
        droppedElements = 0
        droppedBytes = 0
    }

    func snapshot() -> [Element] {
        elements
    }
}
