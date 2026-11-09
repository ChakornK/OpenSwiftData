import Foundation
import ParityContracts
import SwiftData

enum CodableParityKind: String, Codable {
    case a
    case b
}

struct CodableParityAddress: Codable, Equatable {
    var city: String
    var zip: Int
}

struct CodableParityGeo: Codable, Equatable {
    var latitude: Double
    var verified: Bool
}

struct MemberParityAddress: Codable, Equatable {
    var city: String
    var zip: Int
    var unit: String?
    var geo: CodableParityGeo
}

@available(macOS 15, *)
@Model
final class CodableParityModel {
    var name: String
    var kind: CodableParityKind
    init(name: String) { self.name = name; self.kind = .a }
}

@available(macOS 15, *)
@Model
final class CodableParityContact {
    var address: CodableParityAddress
    var tags: [CodableParityAddress] = []
    var nickname: CodableParityKind?
    init(address: CodableParityAddress) { self.address = address }
}

@available(macOS 15, *)
@Model
final class MemberParityPlace {
    var name: String
    var address: MemberParityAddress

    init(name: String, address: MemberParityAddress) {
        self.name = name
        self.address = address
    }
}

@MainActor
@available(macOS 15, *)
enum AppleCodableParityAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try CodableParityScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: CodableParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard CodableParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: specification.id, observations: result.observations)
        }
        return result
    }

    static func run(_ specification: CodableParitySpecification) throws -> ScenarioResult {
        let observations: [ParityObservation]
        switch specification.query {
        case .enumRoundTrip:
            let container = try ModelContainer(
                for: CodableParityModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let model = CodableParityModel(name: "a")
            container.mainContext.insert(model)
            model.kind = .b
            try container.mainContext.save()
            let fetched = try require(try ModelContext(container).fetch(FetchDescriptor<CodableParityModel>()).first)
            observations = [
                .init(step: 0, field: "enum.name", value: .string(fetched.name)),
                .init(step: 0, field: "enum.kind", value: .string(fetched.kind.rawValue)),
            ]
        case .compositeRoundTrip:
            let container = try ModelContainer(
                for: CodableParityContact.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let contact = CodableParityContact(address: CodableParityAddress(city: "Paris", zip: 75001))
            contact.tags = [CodableParityAddress(city: "Lyon", zip: 69001)]
            contact.nickname = .b
            container.mainContext.insert(contact)
            try container.mainContext.save()
            let fetched = try require(try ModelContext(container).fetch(FetchDescriptor<CodableParityContact>()).first)
            observations = [
                .init(step: 0, field: "composite.address", value: .object([
                    "city": .string(fetched.address.city), "zip": .integer(Int64(fetched.address.zip)),
                ])),
                .init(step: 0, field: "composite.tags", value: .array(fetched.tags.map {
                    .object(["city": .string($0.city), "zip": .integer(Int64($0.zip))])
                })),
                .init(step: 0, field: "composite.nickname", value: fetched.nickname.map { .string($0.rawValue) } ?? .null),
            ]
        case .cityEqualsParis, .zipGreaterThan, .nestedMemberPredicates, .optionalUnitComparisons, .memberAndScalarCombined:
            let container = try ModelContainer(
                for: MemberParityPlace.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            for place in specification.places {
                context.insert(MemberParityPlace(name: place.name, address: MemberParityAddress(
                    city: place.city,
                    zip: Int(place.zip),
                    unit: place.unit,
                    geo: CodableParityGeo(latitude: place.latitude, verified: place.verified))))
            }
            if specification.saveBeforeFetch { try context.save() }
            observations = try observe(specification.query, in: context)
        }
        return ScenarioResult(id: specification.id, observations: observations)
    }

    private static func observe(_ query: CodableParitySpecification.Query, in context: ModelContext) throws -> [ParityObservation] {
        let values: [String: ObservedValue]
        switch query {
        case .cityEqualsParis:
            values = ["names": .array(try context.fetch(FetchDescriptor(
                predicate: #Predicate<MemberParityPlace> { $0.address.city == "Paris" },
                sortBy: [SortDescriptor(\.name)])).map { .string($0.name) })]
        case let .zipGreaterThan(zip):
            let threshold = Int(zip)
            values = ["names": .array(try context.fetch(FetchDescriptor(
                predicate: #Predicate<MemberParityPlace> { $0.address.zip > threshold },
                sortBy: [SortDescriptor(\.name)])).map { .string($0.name) })]
        case .nestedMemberPredicates:
            values = ["nested": .object([
                "verified": .array(try context.fetch(FetchDescriptor(
                    predicate: #Predicate<MemberParityPlace> { $0.address.geo.verified },
                    sortBy: [SortDescriptor(\.name)])).map { .string($0.name) }),
                "latitudeBelow46": .array(try context.fetch(FetchDescriptor(
                    predicate: #Predicate<MemberParityPlace> { $0.address.geo.latitude < 46 },
                    sortBy: [SortDescriptor(\.name)])).map { .string($0.name) }),
            ])]
        case .optionalUnitComparisons:
            let nilUnitNames: [String] = try context.fetch(FetchDescriptor<MemberParityPlace>(
                predicate: #Predicate { $0.address.unit == nil }, sortBy: [SortDescriptor(\.name)]))
                .map(\.name)
            let fourBNames: [String] = try context.fetch(FetchDescriptor<MemberParityPlace>(
                predicate: #Predicate { $0.address.unit == "4B" }, sortBy: [SortDescriptor(\.name)]))
                .map(\.name)
            let optionalUnitValue: ObservedValue = .object([
                "nil": .array(nilUnitNames.map(ObservedValue.string)),
                "fourB": .array(fourBNames.map(ObservedValue.string)),
            ])
            values = ["optionalUnit": optionalUnitValue]
        case .memberAndScalarCombined:
            values = ["names": .array(try context.fetch(FetchDescriptor(
                predicate: #Predicate<MemberParityPlace> { $0.address.city == "Paris" && $0.name.starts(with: "l") },
                sortBy: [SortDescriptor(\.name)])).map { .string($0.name) })]
        case .enumRoundTrip, .compositeRoundTrip:
            throw ScenarioExpectationError(id: ScenarioID(suite: "CodableParity", test: "invalid adapter dispatch"), observations: [])
        }
        return values.map { ParityObservation(step: 0, field: $0.key, value: $0.value) }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw ScenarioExpectationError(id: ScenarioID(suite: "CodableParity", test: "missing fetched row"), observations: [])
        }
        return value
    }
}
