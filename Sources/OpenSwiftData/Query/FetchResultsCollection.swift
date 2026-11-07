/// The results of a batched fetch.
///
/// The collection captures the matching identifiers when the fetch runs and loads elements in batches as
/// they are accessed. Repeated access returns the same model instances.
public struct FetchResultsCollection<Element>: RandomAccessCollection {
    private final class Storage {
        let count: Int
        let batchSize: Int
        let loadBatch: (Range<Int>) -> [Element]
        var loaded: [Int: Element] = [:]

        init(count: Int, batchSize: Int, loadBatch: @escaping (Range<Int>) -> [Element]) {
            self.count = count
            self.batchSize = batchSize
            self.loadBatch = loadBatch
        }

        func element(at position: Int) -> Element {
            if let element = loaded[position] { return element }
            let start = position - position % batchSize
            let range = start..<Swift.min(start + batchSize, count)
            for (offset, element) in loadBatch(range).enumerated() {
                loaded[range.lowerBound + offset] = element
            }
            guard let element = loaded[position] else {
                preconditionFailure("The batch containing index \(position) did not load.")
            }
            return element
        }
    }

    private let storage: Storage

    /// Creates a collection of `count` elements loaded `batchSize` at a time; a non-positive batch size loads
    /// every element in one batch.
    package init(count: Int, batchSize: Int, loadBatch: @escaping (Range<Int>) -> [Element]) {
        storage = Storage(
            count: count, batchSize: batchSize > 0 ? batchSize : Swift.max(count, 1), loadBatch: loadBatch)
    }

    /// The position of the first result.
    public var startIndex: Int { 0 }
    /// The position one past the last result.
    public var endIndex: Int { storage.count }

    /// Returns the result at a position, fetching its batch if needed.
    public subscript(position: Int) -> Element {
        precondition(indices.contains(position), "Index out of range")
        return storage.element(at: position)
    }
}
