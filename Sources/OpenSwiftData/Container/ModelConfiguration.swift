import Foundation

/// Describes a model container's store configuration.
public struct ModelConfiguration: Sendable {
    /// The configuration name.
    public let name: String
    /// The location of the store, if file-backed.
    public let url: URL?
    /// Whether the store is held only in memory.
    public let isStoredInMemoryOnly: Bool
    /// Whether the container permits saving.
    public let allowsSave: Bool
    /// The app-group container selection.
    public let groupContainer: GroupContainer
    /// The CloudKit database selection, retained for API compatibility.
    public let cloudKitDatabase: CloudKitDatabase
    package let storeFactory: RuntimeStoreFactory?

    /// Creates a store configuration.
    public init(
        _ name: String = "default",
        schema: Schema? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none
    ) {
        self.name = name
        url = nil
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        storeFactory = nil
        _ = schema
    }

    package init(
        _ name: String = "default",
        schema: Schema? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none,
        storeFactory: RuntimeStoreFactory?
    ) {
        self.name = name
        url = nil
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        self.storeFactory = storeFactory
        _ = schema
    }

    /// Creates a store configuration with an explicit URL.
    public init(
        _ name: String = "default",
        schema: Schema? = nil,
        url: URL,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none
    ) {
        self.name = name
        self.url = url
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        storeFactory = nil
        _ = schema
    }

    package init(
        _ name: String = "default",
        schema: Schema? = nil,
        url: URL,
        allowsSave: Bool = true,
        groupContainer: GroupContainer = .none,
        cloudKitDatabase: CloudKitDatabase = .none,
        storeFactory: RuntimeStoreFactory?
    ) {
        self.name = name
        self.url = url
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
        self.groupContainer = groupContainer
        self.cloudKitDatabase = cloudKitDatabase
        self.storeFactory = storeFactory
        _ = schema
    }

    /// Selects an app-group container.
    public enum GroupContainer: Sendable {
        /// Uses no app-group container.
        case none
        /// Uses the named app-group container.
        case identifier(String)
    }

    /// Selects a CloudKit database.
    public enum CloudKitDatabase: Sendable {
        /// Does not use CloudKit.
        case none
        /// Uses the private CloudKit database.
        case `private`
        /// Uses the public CloudKit database.
        case `public`
        /// Uses the named CloudKit database.
        case automatic
    }
}
