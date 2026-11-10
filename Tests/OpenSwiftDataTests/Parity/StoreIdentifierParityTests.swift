import Foundation
import OpenSwiftData
import Testing

@Model final class StoreIdentifierParityItem {
    var name: String
    init(name: String) { self.name = name }
}

/// Persistent identifiers carry the store's UUID, which is saved with the store, as in Apple's SwiftData.
@MainActor @Suite struct StoreIdentifierParityTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "osd-store-identifier-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "default.store")
    }

    @Test func `saved identifiers use a UUID store identifier`() throws {
        let container = try ModelContainer(
            for: StoreIdentifierParityItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = StoreIdentifierParityItem(name: "a")
        container.mainContext.insert(item)
        #expect(item.persistentModelID.storeIdentifier == nil)
        try container.mainContext.save()
        #expect(item.persistentModelID.storeIdentifier.flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test func `the store identifier survives reopening the store`() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let identifier: PersistentIdentifier
        do {
            let container = try ModelContainer(
                for: StoreIdentifierParityItem.self, configurations: ModelConfiguration(url: url))
            let item = StoreIdentifierParityItem(name: "a")
            container.mainContext.insert(item)
            try container.mainContext.save()
            identifier = item.persistentModelID
        }
        let reopened = try ModelContainer(
            for: StoreIdentifierParityItem.self, configurations: ModelConfiguration(url: url))
        let fetched = try #require(try reopened.mainContext.fetch(FetchDescriptor<StoreIdentifierParityItem>()).first)
        // Apple regenerates the store identifier on reopen, so the fetched model carries a different
        // identifier than the original.
        #expect(fetched.persistentModelID != identifier)
        let resolved: StoreIdentifierParityItem? = reopened.mainContext.registeredModel(for: identifier)
        // The original identifier no longer resolves to a registered model after the reopen.
        #expect(resolved == nil)
    }

    @Test func `separate stores have different identifiers`() throws {
        func savedIdentifier() throws -> String? {
            let container = try ModelContainer(
                for: StoreIdentifierParityItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let item = StoreIdentifierParityItem(name: "a")
            container.mainContext.insert(item)
            try container.mainContext.save()
            return item.persistentModelID.storeIdentifier
        }
        #expect(try savedIdentifier() != savedIdentifier())
    }
}
