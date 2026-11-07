import Foundation
import OpenSwiftData
import Testing

enum CodableParityKind: String, Codable { case a, b }

@Model final class CodableParityModel {
    var name: String
    var kind: CodableParityKind
    init(name: String) {
        self.name = name
        self.kind = .a
    }
}

/// Codable attribute values round-trip through the store, as in Apple's SwiftData.
@MainActor @Suite struct CodableAttributeParityTests {
    @Test func `codable enum attributes load in another context`() throws {
        let container = try ModelContainer(
            for: CodableParityModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = CodableParityModel(name: "a")
        container.mainContext.insert(model)
        model.kind = .b
        try container.mainContext.save()
        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<CodableParityModel>()).first)
        #expect(fetched.name == "a")
        #expect(fetched.kind == .b)
    }
}

struct CodableParityAddress: Codable, Equatable {
    var city: String
    var zip: Int
}

@Model final class CodableParityContact {
    var address: CodableParityAddress
    var tags: [CodableParityAddress] = []
    var nickname: CodableParityKind?
    init(address: CodableParityAddress) { self.address = address }
}

/// Codable structs, arrays of them, and optional enums persist without `@Attribute`, as in Apple's SwiftData.
@MainActor @Suite struct CodableCompositeParityTests {
    @Test func `codable composite values load in another context`() throws {
        let container = try ModelContainer(
            for: CodableParityContact.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let contact = CodableParityContact(address: CodableParityAddress(city: "Paris", zip: 75001))
        container.mainContext.insert(contact)
        contact.tags = [CodableParityAddress(city: "Lyon", zip: 69001)]
        contact.nickname = .b
        try container.mainContext.save()
        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<CodableParityContact>()).first)
        #expect(fetched.address == CodableParityAddress(city: "Paris", zip: 75001))
        #expect(fetched.tags == [CodableParityAddress(city: "Lyon", zip: 69001)])
        #expect(fetched.nickname == .b)
    }
}
