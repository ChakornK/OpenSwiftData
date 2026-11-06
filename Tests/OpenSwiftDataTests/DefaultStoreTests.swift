import XCTest
@testable import OpenSwiftData
import OpenSwiftDataSQLite

@Model
final class DefaultStoreFixture {
    var title: String
    init(title: String) { self.title = title }
}

final class DefaultStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osd-default-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private var defaultStoreURL: URL {
        directory.appendingPathComponent("default.store")
    }

    /// Runs `body` with the implicit default store redirected into this test's directory.
    private func withIsolatedDefaultStore<T>(_ body: () throws -> T) throws -> T {
        try ModelConfiguration.$defaultStoreDirectoryOverride.withValue(directory, operation: body)
    }

    @MainActor
    func testDefaultTypedContainerSavesAndFetches() throws {
        try withIsolatedDefaultStore {
            let container = try ModelContainer(for: DefaultStoreFixture.self)
            defer { try? container.store?.close() }
            XCTAssertNotNil(container.store)
            XCTAssertEqual(container.configurations.count, 1)
            XCTAssertEqual(
                container.configurations.first?.url?.standardizedFileURL, defaultStoreURL.standardizedFileURL)
            XCTAssertEqual(container.configurations.first?.isStoredInMemoryOnly, false)

            let context = container.mainContext
            context.insert(DefaultStoreFixture(title: "first"))
            try context.save()

            let fetched = try context.fetch(FetchDescriptor<DefaultStoreFixture>())
            XCTAssertEqual(fetched.map(\.title), ["first"])
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DefaultStoreFixture>()), 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultStoreURL.path))
    }

    @MainActor
    func testDefaultTypedContainerPersistsAcrossReopen() throws {
        try withIsolatedDefaultStore {
            let writer = try ModelContainer(for: DefaultStoreFixture.self)
            writer.mainContext.insert(DefaultStoreFixture(title: "durable"))
            try writer.mainContext.save()
            try writer.store?.close()

            let reader = try ModelContainer(for: DefaultStoreFixture.self)
            defer { try? reader.store?.close() }
            let fetched = try reader.mainContext.fetch(FetchDescriptor<DefaultStoreFixture>())
            XCTAssertEqual(fetched.map(\.title), ["durable"])
        }
    }

    @MainActor
    func testArrayInitializerWithoutConfigurationsUsesDefaultStore() throws {
        try withIsolatedDefaultStore {
            let writer = try ModelContainer(for: [DefaultStoreFixture.self])
            writer.mainContext.insert(DefaultStoreFixture(title: "array"))
            try writer.mainContext.save()
            try writer.store?.close()

            let reader = try ModelContainer(for: DefaultStoreFixture.self)
            defer { try? reader.store?.close() }
            XCTAssertEqual(
                try reader.mainContext.fetch(FetchDescriptor<DefaultStoreFixture>()).map(\.title), ["array"])
        }
    }

    @MainActor
    func testSchemaInitializerWithoutConfigurationsOpensDefaultStore() throws {
        try withIsolatedDefaultStore {
            let typed = try ModelContainer(for: DefaultStoreFixture.self)
            typed.mainContext.insert(DefaultStoreFixture(title: "schema"))
            try typed.mainContext.save()
            let schema = typed.schema
            try typed.store?.close()

            let container = try ModelContainer(for: schema)
            defer { try? container.store?.close() }
            let store = try XCTUnwrap(container.store)
            XCTAssertEqual(
                container.configurations.first?.url?.standardizedFileURL, defaultStoreURL.standardizedFileURL)
            let rows = try store.read { connection in
                try connection.rows("SELECT ZTITLE FROM ZDEFAULTSTOREFIXTURE", arguments: [])
            }
            XCTAssertEqual(rows, [[.text("schema")]])
        }
    }

    @MainActor
    func testExplicitEmptyConfigurationsRemainSchemaOnly() throws {
        try withIsolatedDefaultStore {
            let container = try ModelContainer(for: [DefaultStoreFixture.self], configurations: [])
            XCTAssertNil(container.store)
            XCTAssertTrue(container.configurations.isEmpty)
            XCTAssertThrowsError(try container.mainContext.fetch(FetchDescriptor<DefaultStoreFixture>())) { error in
                guard case SwiftDataError.unsupportedStore(let message) = error else {
                    return XCTFail("Expected unsupportedStore, got \(error)")
                }
                XCTAssertEqual(message, "Fetch is unavailable without a persistent store.")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testExplicitMemoryConfigurationDoesNotPersistOrTouchDefaultStore() throws {
        let name = "default-store-memory-\(UUID().uuidString)"
        try withIsolatedDefaultStore {
            let writer = try ModelContainer(for: DefaultStoreFixture.self, configurations: .sqliteMemory(name))
            writer.mainContext.insert(DefaultStoreFixture(title: "volatile"))
            try writer.mainContext.save()
            XCTAssertEqual(try writer.mainContext.fetchCount(FetchDescriptor<DefaultStoreFixture>()), 1)
            try writer.store?.close()

            let reader = try ModelContainer(for: DefaultStoreFixture.self, configurations: .sqliteMemory(name))
            defer { try? reader.store?.close() }
            XCTAssertEqual(try reader.mainContext.fetchCount(FetchDescriptor<DefaultStoreFixture>()), 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultStoreURL.path))
    }

    @MainActor
    func testExplicitFileConfigurationPersistsAtRequestedURL() throws {
        let url = directory.appendingPathComponent("explicit.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try withIsolatedDefaultStore {
            let writer = try ModelContainer(for: DefaultStoreFixture.self, configurations: .sqliteFile(url: url))
            writer.mainContext.insert(DefaultStoreFixture(title: "explicit"))
            try writer.mainContext.save()
            try writer.store?.close()

            let reader = try ModelContainer(for: DefaultStoreFixture.self, configurations: .sqliteFile(url: url))
            defer { try? reader.store?.close() }
            XCTAssertEqual(
                try reader.mainContext.fetch(FetchDescriptor<DefaultStoreFixture>()).map(\.title), ["explicit"])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultStoreURL.path))
    }

    func testExplicitConfigurationWithoutProviderStillThrows() throws {
        try withIsolatedDefaultStore {
            XCTAssertThrowsError(
                try ModelContainer(
                    for: DefaultStoreFixture.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            ) { error in
                guard case SwiftDataError.unsupportedStore(let message) = error else {
                    return XCTFail("Expected unsupportedStore, got \(error)")
                }
                XCTAssertEqual(message, "The configured store backend/provider is unavailable.")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultStoreURL.path))
    }

    func testDefaultStoreLocationFailureSurfacesInsteadOfFallingBack() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))

        try ModelConfiguration.$defaultStoreDirectoryOverride.withValue(blocker) {
            XCTAssertThrowsError(try ModelContainer(for: DefaultStoreFixture.self))
        }
    }

    func testContextWithoutContainerStillRejectsPersistentOperations() {
        let context = ModelContext()
        XCTAssertThrowsError(try context.fetch(FetchDescriptor<DefaultStoreFixture>())) { error in
            guard case SwiftDataError.unsupportedStore = error else {
                return XCTFail("Expected unsupportedStore, got \(error)")
            }
        }
    }
}
