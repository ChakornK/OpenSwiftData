import Foundation

/// Describes a typed model fetch request.
public struct FetchDescriptor<Model: PersistentModel> {
    /// The predicate applied to fetched models.
    public var predicate: Predicate<Model>?
    /// The sort descriptors applied in declaration order.
    public var sortBy: [SortDescriptor<Model>]
    /// The maximum number of matching models returned.
    public var fetchLimit: Int?
    /// The number of matching models skipped before returning results.
    public var fetchOffset: Int?
    /// Whether unsaved context changes are included in the result.
    public var includePendingChanges: Bool
    /// The model properties selected by this fetch, when specified.
    public var propertiesToFetch: [PartialKeyPath<Model>]?
    /// The relationship properties to materialize with fetched models.
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<Model>]

    /// Creates a fetch descriptor with default options.
    public init(
        predicate: Predicate<Model>? = nil,
        sortBy: [SortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int? = nil,
        includePendingChanges: Bool = true,
        propertiesToFetch: [PartialKeyPath<Model>]? = nil,
        relationshipKeyPathsForPrefetching: [PartialKeyPath<Model>] = []
    ) {
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
        self.includePendingChanges = includePendingChanges
        self.propertiesToFetch = propertiesToFetch
        self.relationshipKeyPathsForPrefetching = relationshipKeyPathsForPrefetching
    }
}

/// Describes a model property used to order fetched results.
public struct SortDescriptor<Model: PersistentModel> {
    /// The property used to compare models.
    public let keyPath: PartialKeyPath<Model>
    private let propertyDescription: String
    /// Whether the ordering is ascending.
    public let isAscending: Bool
    private let compareValues: (Model, Model) -> ComparisonResult

    /// Creates an ascending or descending ordering for a model property.
    public init<Value: Comparable>(_ keyPath: KeyPath<Model, Value>, order: SortOrder = .forward) {
        self.keyPath = keyPath
        isAscending = order == .forward
        propertyDescription = String(describing: keyPath)
        compareValues = { lhs, rhs in
            let lhsValue = lhs[keyPath: keyPath]
            let rhsValue = rhs[keyPath: keyPath]
            if lhsValue == rhsValue { return .orderedSame }
            return lhsValue < rhsValue ? .orderedAscending : .orderedDescending
        }
    }

    func compare(_ lhs: Model, _ rhs: Model) -> ComparisonResult {
        let result = compareValues(lhs, rhs)
        return isAscending ? result : result.reversed
    }

    var propertyName: String? {
        let components = propertyDescription.split(separator: ".")
        guard let member = components.last else { return nil }
        return String(member).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedSame: .orderedSame
        case .orderedDescending: .orderedAscending
        @unknown default: .orderedSame
        }
    }
}

/// The direction of a model sort descriptor.
public enum SortOrder: Sendable {
    /// Sort from lower to higher values.
    case forward
    /// Sort from higher to lower values.
    case reverse
}
