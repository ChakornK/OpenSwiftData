import Foundation
import OpenSwiftData
import Testing

struct MemberParityGeo: Codable, Equatable {
    var latitude: Double
    var verified: Bool
}

struct MemberParityAddress: Codable, Equatable {
    var city: String
    var zip: Int
    var unit: String?
    var geo: MemberParityGeo
}

@Model final class MemberParityPlace {
    var name: String
    var address: MemberParityAddress
    init(name: String, city: String, zip: Int, unit: String? = nil, latitude: Double = 0, verified: Bool = false) {
        self.name = name
        address = MemberParityAddress(
            city: city, zip: zip, unit: unit, geo: MemberParityGeo(latitude: latitude, verified: verified))
    }
}

/// Predicates can compare members of Codable struct attributes, as in Apple's SwiftData.
@MainActor @Suite struct CodableMemberPredicateParityTests {
    private func names(
        _ predicate: Predicate<MemberParityPlace>, save: Bool
    ) throws -> [String] {
        let container = try ModelContainer(
            for: MemberParityPlace.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(MemberParityPlace(name: "louvre", city: "Paris", zip: 75001, latitude: 48.86, verified: true))
        context.insert(MemberParityPlace(name: "flat", city: "Paris", zip: 75011, unit: "4B", latitude: 48.85))
        context.insert(MemberParityPlace(name: "bouchon", city: "Lyon", zip: 69002, latitude: 45.76))
        if save { try context.save() }
        let descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.name)])
        return try context.fetch(descriptor).map(\.name)
    }

    @Test(arguments: [false, true])
    func `string member equality`(save: Bool) throws {
        #expect(try names(#Predicate { $0.address.city == "Paris" }, save: save) == ["flat", "louvre"])
    }

    @Test(arguments: [false, true])
    func `integer member ordering`(save: Bool) throws {
        #expect(try names(#Predicate { $0.address.zip > 70000 }, save: save) == ["flat", "louvre"])
    }

    @Test(arguments: [false, true])
    func `nested members`(save: Bool) throws {
        #expect(try names(#Predicate { $0.address.geo.verified }, save: save) == ["louvre"])
        #expect(try names(#Predicate { $0.address.geo.latitude < 46 }, save: save) == ["bouchon"])
    }

    @Test(arguments: [false, true])
    func `optional member comparisons`(save: Bool) throws {
        #expect(try names(#Predicate { $0.address.unit == nil }, save: save) == ["bouchon", "louvre"])
        #expect(try names(#Predicate { $0.address.unit == "4B" }, save: save) == ["flat"])
    }

    @Test(arguments: [false, true])
    func `members combine with scalar attributes`(save: Bool) throws {
        #expect(
            try names(#Predicate { $0.address.city == "Paris" && $0.name.starts(with: "l") }, save: save)
                == ["louvre"])
    }
}
