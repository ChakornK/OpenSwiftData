import Foundation

/// A committed group of changes recorded in a store's history.
public protocol HistoryTransaction: Hashable, Identifiable, Sendable {
    associatedtype TokenType: Comparable & Hashable & Identifiable & Sendable
    associatedtype TransactionIdentifier: Comparable & Hashable & Sendable
    /// When the transaction committed.
    var timestamp: Date { get }
    /// The model changes in commit order.
    var changes: [HistoryChange] { get }
    /// A token marking this transaction's position in history.
    var token: TokenType { get }
    /// The store-assigned transaction identifier.
    var transactionIdentifier: TransactionIdentifier { get }
    /// The store that recorded the transaction.
    var storeIdentifier: String { get }
    /// The author of the context that saved the transaction.
    var author: String? { get }
}

/// A position in a store's history.
public protocol HistoryToken: Comparable, Codable, Hashable, Identifiable, Sendable {
    associatedtype TokenType: Codable & Hashable & Sendable
    /// The token's underlying value.
    var tokenValue: TokenType? { get }
}

/// One model change in a history transaction.
public enum HistoryChange: Sendable {
    case insert(any HistoryInsert)
    case update(any HistoryUpdate)
    case delete(any HistoryDelete)

    /// The identifier of the changed model.
    public var changedPersistentIdentifier: PersistentIdentifier {
        switch self {
        case .insert(let change): change.changedPersistentIdentifier
        case .update(let change): change.changedPersistentIdentifier
        case .delete(let change): change.changedPersistentIdentifier
        }
    }
}

/// A recorded insertion.
public protocol HistoryInsert<Model>: Sendable {
    associatedtype Model: PersistentModel
    associatedtype TransactionIdentifier: Comparable & Hashable & Sendable
    associatedtype ChangeIdentifier: Comparable & Hashable & Sendable
    var changeIdentifier: ChangeIdentifier { get }
    var transactionIdentifier: TransactionIdentifier { get }
    var changedPersistentIdentifier: PersistentIdentifier { get }
}

/// A recorded update.
public protocol HistoryUpdate<Model>: Sendable {
    associatedtype Model: PersistentModel
    associatedtype TransactionIdentifier: Comparable & Hashable & Sendable
    associatedtype ChangeIdentifier: Comparable & Hashable & Sendable
    typealias PropertyUpdate = PartialKeyPath<Model> & Sendable
    var changeIdentifier: ChangeIdentifier { get }
    var transactionIdentifier: TransactionIdentifier { get }
    var changedPersistentIdentifier: PersistentIdentifier { get }
    /// Key paths of the properties whose values changed.
    var updatedAttributes: [any PartialKeyPath<Model> & Sendable] { get }
}

/// A recorded deletion.
public protocol HistoryDelete<Model>: Sendable {
    associatedtype Model: PersistentModel
    associatedtype TransactionIdentifier: Comparable & Hashable & Sendable
    associatedtype ChangeIdentifier: Comparable & Hashable & Sendable
    var changeIdentifier: ChangeIdentifier { get }
    var transactionIdentifier: TransactionIdentifier { get }
    var changedPersistentIdentifier: PersistentIdentifier { get }
    /// The deleted model's values for properties marked `.preserveValueOnDeletion`.
    var tombstone: HistoryTombstone<Model> { get }
}

/// The values a deleted model preserved for history.
///
/// Iterating yields the preserved values; subscripting by key path returns one, or `nil` for properties that
/// were not preserved.
public struct HistoryTombstone<Model: PersistentModel>: Sequence, @unchecked Sendable {
    private let entries: [(keyPath: AnyKeyPath, value: any Sendable)]

    package init(entries: [(keyPath: AnyKeyPath, value: any Sendable)]) {
        self.entries = entries
    }

    /// Iterates the preserved values.
    public struct Iterator: IteratorProtocol {
        fileprivate var base: IndexingIterator<[Any]>
        /// Returns the next preserved value, or `nil` after the last one.
        public mutating func next() -> Any? { base.next() }
    }

    /// Returns the preserved value for a property, or `nil` when it was not preserved.
    public subscript(keyPath: PartialKeyPath<Model>) -> (any Sendable)? {
        entries.first(where: { $0.keyPath == keyPath })?.value
    }

    /// Returns an iterator over the preserved values.
    public func makeIterator() -> Iterator { Iterator(base: entries.map(\.value).makeIterator()) }
}

/// Selects history transactions to fetch or delete.
public struct HistoryDescriptor<TransactionType: HistoryTransaction> {
    /// The condition transactions must satisfy, or `nil` for all transactions.
    public var predicate: Predicate<TransactionType>?
    /// The maximum number of transactions to fetch; zero means no limit.
    public var fetchLimit: UInt64 = 0
    /// The order of fetched transactions; empty means commit order.
    public var sortBy: [SortDescriptor<TransactionType>] = []

    /// Creates a descriptor matching transactions that satisfy a predicate.
    public init(predicate: Predicate<TransactionType>? = nil) {
        self.predicate = predicate
    }

    /// Creates a descriptor matching transactions that satisfy a predicate, in the given order.
    public init(predicate: Predicate<TransactionType>? = nil, sortBy: [SortDescriptor<TransactionType>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

/// A position in the default store's history.
///
/// Encodes as `{"storeTokens": {"<store identifier>": <transaction identifier>}}`.
public struct DefaultHistoryToken: HistoryToken, Codable {
    /// The token value: each store identifier mapped to its transaction identifier.
    public typealias TokenType = [String: Int64]
    private let storeTokens: [String: Int64]

    package init(storeTokens: [String: Int64]) {
        self.storeTokens = storeTokens
    }

    /// An identifier derived from the token value.
    public var id: Int { storeTokens.hashValue }
    /// The transaction identifier reached in each store.
    public var tokenValue: TokenType? { storeTokens }

    /// Orders tokens by their transaction identifiers, comparing stores in identifier order.
    public static func < (lhs: DefaultHistoryToken, rhs: DefaultHistoryToken) -> Bool {
        for store in Set(lhs.storeTokens.keys).union(rhs.storeTokens.keys).sorted() {
            let left = lhs.storeTokens[store] ?? 0
            let right = rhs.storeTokens[store] ?? 0
            if left != right { return left < right }
        }
        return false
    }

    private enum CodingKeys: String, CodingKey { case storeTokens }
}

/// A transaction recorded in the default store's history.
public struct DefaultHistoryTransaction: HistoryTransaction {
    /// Transaction identifiers are store-assigned integers.
    public typealias TransactionIdentifier = Int64
    /// The token type that marks this transaction's position.
    public typealias TokenType = DefaultHistoryToken
    /// The transaction identifier.
    public var id: Int64 { transactionIdentifier }
    /// When the transaction was saved.
    public let timestamp: Date
    /// The inserts, updates, and deletes the transaction recorded, in order.
    public let changes: [HistoryChange]
    /// The history position just after this transaction.
    public let token: DefaultHistoryToken
    /// The store-assigned identifier of the transaction.
    public let transactionIdentifier: Int64
    /// The identifier of the store that recorded the transaction.
    public let storeIdentifier: String
    /// The bundle identifier of the app that saved the transaction, or its process name.
    public let bundleIdentifier: String
    /// The identifier of the process that saved the transaction.
    public let processIdentifier: String
    /// The saving context's author, if it set one.
    public let author: String?

    /// Returns whether both values have the same identifiers.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transactionIdentifier == rhs.transactionIdentifier && lhs.storeIdentifier == rhs.storeIdentifier
    }

    /// Hashes the identifiers that `==` compares.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(transactionIdentifier)
        hasher.combine(storeIdentifier)
    }
}

/// An insertion recorded in the default store's history.
public struct DefaultHistoryInsert<Model: PersistentModel>: HistoryInsert, Hashable {
    /// Transaction identifiers are store-assigned integers.
    public typealias TransactionIdentifier = Int64
    /// Change identifiers are store-assigned integers.
    public typealias ChangeIdentifier = Int64
    /// The store-assigned identifier of the change.
    public let changeIdentifier: Int64
    /// The store-assigned identifier of the transaction.
    public let transactionIdentifier: Int64
    /// The identifier of the changed model.
    public let changedPersistentIdentifier: PersistentIdentifier
}

/// An update recorded in the default store's history.
public struct DefaultHistoryUpdate<Model: PersistentModel>: HistoryUpdate, Hashable {
    /// Transaction identifiers are store-assigned integers.
    public typealias TransactionIdentifier = Int64
    /// Change identifiers are store-assigned integers.
    public typealias ChangeIdentifier = Int64
    /// Updated properties are identified by key path.
    public typealias PropertyUpdate = PartialKeyPath<Model> & Sendable
    /// The store-assigned identifier of the change.
    public let changeIdentifier: Int64
    /// The store-assigned identifier of the transaction.
    public let transactionIdentifier: Int64
    /// The identifier of the changed model.
    public let changedPersistentIdentifier: PersistentIdentifier
    /// The attributes the update changed.
    public let updatedAttributes: [any PartialKeyPath<Model> & Sendable]

    /// Returns whether both values have the same identifiers.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.changeIdentifier == rhs.changeIdentifier && lhs.transactionIdentifier == rhs.transactionIdentifier
    }

    /// Hashes the identifiers that `==` compares.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(changeIdentifier)
        hasher.combine(transactionIdentifier)
    }
}

/// A deletion recorded in the default store's history.
public struct DefaultHistoryDelete<Model: PersistentModel>: HistoryDelete, Hashable {
    /// Transaction identifiers are store-assigned integers.
    public typealias TransactionIdentifier = Int64
    /// Change identifiers are store-assigned integers.
    public typealias ChangeIdentifier = Int64
    /// The store-assigned identifier of the change.
    public let changeIdentifier: Int64
    /// The store-assigned identifier of the transaction.
    public let transactionIdentifier: Int64
    /// The identifier of the changed model.
    public let changedPersistentIdentifier: PersistentIdentifier
    /// The values preserved from the deleted model.
    public let tombstone: HistoryTombstone<Model>

    /// Returns whether both values have the same identifiers.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.changeIdentifier == rhs.changeIdentifier && lhs.transactionIdentifier == rhs.transactionIdentifier
    }

    /// Hashes the identifiers that `==` compares.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(changeIdentifier)
        hasher.combine(transactionIdentifier)
    }
}

extension HistoryChange {
    /// Builds a typed change for a stored change of the given model type.
    package static func make<Model: PersistentModel>(
        _ stored: StoredHistoryChange, modelType: Model.Type, transactionIdentifier: Int64, ordinal: Int,
        storeIdentifier: String
    ) -> HistoryChange {
        let identifier = PersistentIdentifier(
            storeIdentifier: storeIdentifier, entityName: stored.entityName, primaryKey: stored.primaryKey)
        // Change identifiers are unique across the store: the transaction in the high bits, the ordinal below.
        let changeIdentifier = transactionIdentifier << 20 | Int64(ordinal)
        let descriptors = Dictionary(
            Model.propertyDescriptors.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        switch stored.type {
        case .insert:
            return .insert(
                DefaultHistoryInsert<Model>(
                    changeIdentifier: changeIdentifier, transactionIdentifier: transactionIdentifier,
                    changedPersistentIdentifier: identifier))
        case .update:
            let keyPaths = stored.updatedAttributes.compactMap { name -> (any PartialKeyPath<Model> & Sendable)? in
                guard let keyPath = descriptors[name]?.keyPath as? PartialKeyPath<Model> else { return nil }
                // Key paths are immutable, so treating one as `Sendable` is safe.
                let sendable = (keyPath as Any) as! any PartialKeyPath<Model> & Sendable
                return sendable
            }
            return .update(
                DefaultHistoryUpdate<Model>(
                    changeIdentifier: changeIdentifier, transactionIdentifier: transactionIdentifier,
                    changedPersistentIdentifier: identifier, updatedAttributes: keyPaths))
        case .delete:
            let entries = stored.tombstone.keys.sorted().compactMap {
                name -> (keyPath: AnyKeyPath, value: any Sendable)? in
                guard let descriptor = descriptors[name], let stored = stored.tombstone[name],
                    let value = Self.decode(stored, as: descriptor.codec)
                else { return nil }
                return (descriptor.keyPath, value)
            }
            return .delete(
                DefaultHistoryDelete<Model>(
                    changeIdentifier: changeIdentifier, transactionIdentifier: transactionIdentifier,
                    changedPersistentIdentifier: identifier, tombstone: HistoryTombstone(entries: entries)))
        }
    }

    /// Decodes a preserved value; persisted property values are value types, so treating one as `Sendable` is safe.
    private static func decode(_ value: StoredValue, as type: Any.Type) -> (any Sendable)? {
        guard let decodable = type as? any Decodable.Type else { return nil }
        func open<T: Decodable>(_: T.Type) -> (any Sendable)? {
            guard let decoded = try? PersistentValue.decode(T.self, from: value) else { return nil }
            return (decoded as Any) as! any Decodable & Sendable
        }
        return open(decodable)
    }
}
