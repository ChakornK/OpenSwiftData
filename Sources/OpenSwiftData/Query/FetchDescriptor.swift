import Foundation

/// Describes a typed model fetch request.
///
/// Descriptors compare equal when every option matches and the predicates share the same
/// construction identity. SwiftData's `#Predicate` literals draw their variable identifiers from a
/// process-wide counter, so two independently constructed predicates with identical bodies carry
/// different variable identifiers and therefore compare unequal, while a copy of a descriptor
/// compares equal to its original (the variable identifiers match) until an option diverges. This
/// matches Apple's SwiftData, which compares predicates by reference rather than by structure.
public struct FetchDescriptor<Model: PersistentModel>: Equatable {
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
    /// The properties to load when fetching; empty loads every property.
    public var propertiesToFetch: [PartialKeyPath<Model>]

    /// The selected properties, or `nil` when the fetch loads every property.
    var selectedProperties: [PartialKeyPath<Model>]? { propertiesToFetch.isEmpty ? nil : propertiesToFetch }
    /// The relationship properties to materialize with fetched models.
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<Model>]

    /// Creates a fetch descriptor with default options.
    public init(
        predicate: Predicate<Model>? = nil,
        sortBy: [SortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int? = 0,
        includePendingChanges: Bool = true,
        propertiesToFetch: [PartialKeyPath<Model>] = [],
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

extension FetchDescriptor {
    /// Returns whether both descriptors have equal predicates, sorting, paging, and fetch options.
    ///
    /// Predicates compare by their `dump()` reflection, which includes the variable identifiers
    /// assigned at construction. Two independently constructed `#Predicate` literals carry different
    /// variable identifiers and compare unequal, matching Apple's reference-based equality; a copied
    /// descriptor shares its predicate's identifiers and compares equal until an option diverges.
    public static func == (lhs: FetchDescriptor, rhs: FetchDescriptor) -> Bool {
        lhs.sortBy == rhs.sortBy && lhs.fetchLimit == rhs.fetchLimit && lhs.fetchOffset == rhs.fetchOffset
            && lhs.includePendingChanges == rhs.includePendingChanges
            && lhs.propertiesToFetch == rhs.propertiesToFetch
            && lhs.relationshipKeyPathsForPrefetching == rhs.relationshipKeyPathsForPrefetching
            && dumped(lhs.predicate?.expression) == dumped(rhs.predicate?.expression)
    }

    /// Renders a value's full reflection tree, including captured constants and variable identifiers.
    ///
    /// Variable identifiers come from a process-wide counter, so they identify a predicate's
    /// construction rather than its structure; this is what makes independently constructed predicates
    /// compare unequal while copies compare equal, matching Apple's SwiftData.
    private static func dumped(_ value: Any?) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }
}

extension SortDescriptor where Compared: PersistentModel {
    /// Whether the descriptor orders values from lower to higher.
    var isAscending: Bool { order == .forward }

    /// The string ordering requested by the descriptor's comparator, defaulting to localized standard order.
    var stringCollation: StringSortCollation {
        #if canImport(Darwin)
            switch stringComparator {
            case String.StandardComparator.lexical?: .lexical
            case String.StandardComparator.localized?: .localized
            default: .localizedStandard
            }
        #else
            // Linux Foundation has no `String.StandardComparator.localized`.
            stringComparator == String.StandardComparator.lexical ? .lexical : .localizedStandard
        #endif
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
