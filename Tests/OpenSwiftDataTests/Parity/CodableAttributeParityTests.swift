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
        // Reading `fetched.kind` currently traps ("read before assignment"), so only the stored name is checked
        // until materialization of `.codable` attributes from SQL rows is fixed.
        withKnownIssue("Fetched .codable attributes are not materialized from SQL rows.") {
            Issue.record("Reading a fetched codable enum attribute traps.")
        }
        #expect(fetched.name == "a")
    }
}
