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

extension SortDescriptor where Compared: PersistentModel {
    /// Whether the descriptor orders values from lower to higher.
    var isAscending: Bool { order == .forward }

    /// The string ordering requested by the descriptor's comparator, defaulting to localized standard order.
    var stringCollation: StringSortCollation {
        switch stringComparator {
        case String.StandardComparator.lexical?: .lexical
        case String.StandardComparator.localized?: .localized
        default: .localizedStandard
        }
    }

    /// The persisted property the descriptor sorts by, or `nil` when it does not sort by a key path.
    var propertyName: String? {
        guard let keyPath else { return nil }
        if let name = Compared.propertyName(forKeyPath: keyPath) { return name }
        let components = String(describing: keyPath).split(separator: ".")
        guard let member = components.last else { return nil }
        return String(member).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}

/// How sorting compares string values.
package enum StringSortCollation: Sendable {
    /// Finder-style ordering: case-insensitive, diacritic-aware, and numeric-aware.
    case localizedStandard
    /// Locale-aware ordering without numeric awareness.
    case localized
    /// Ordering by UTF-8 bytes.
    case lexical

    /// The SQLite collation implementing this ordering.
    package var sqlCollation: String {
        switch self {
        case .localizedStandard: "swiftLocalizedStandardCompare"
        case .localized: "swiftLocalizedCompare"
        case .lexical: "BINARY"
        }
    }

    package func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch self {
        case .localizedStandard: return lhs.localizedStandardCompare(rhs)
        case .localized: return lhs.localizedCompare(rhs)
        case .lexical:
            if lhs == rhs { return .orderedSame }
            return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
        }
    }
}
