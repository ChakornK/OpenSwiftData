import Foundation
import Testing
@testable import OSDCore

/// Behaviors observed from Apple's SwiftData `PersistentIdentifier`.
@Suite struct PersistentIdentifierParityTests {
    private let uuid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

    @Test func `identifier is its own Identifiable id and equal ids mean equal identifiers`() {
        let first = PersistentIdentifier(storeIdentifier: "s", entityName: "Trip", primaryKey: 1)
        let same = PersistentIdentifier(storeIdentifier: "s", entityName: "Trip", primaryKey: 1)
        let other = PersistentIdentifier(storeIdentifier: "s", entityName: "Trip", primaryKey: 2)
        #expect(first.id == same.id)
        #expect(first.id != other.id)
    }

    @Test func `permanent identity includes the store`() {
        let first = PersistentIdentifier(storeIdentifier: "a", entityName: "Trip", primaryKey: 1)
        let otherStore = PersistentIdentifier(storeIdentifier: "b", entityName: "Trip", primaryKey: 1)
        #expect(first != otherStore)
        #expect(first.storeIdentifier == "a")
    }

    @Test func `ordering is total and consistent with equality`() {
        let ids = [
            PersistentIdentifier(storeIdentifier: "b", entityName: "Trip", primaryKey: 1),
            PersistentIdentifier(storeIdentifier: "a", entityName: "Trip", primaryKey: 10),
            PersistentIdentifier(storeIdentifier: "a", entityName: "Trip", primaryKey: 2),
            PersistentIdentifier(storeIdentifier: "a", entityName: "Stop", primaryKey: 3),
            PersistentIdentifier(storeIdentifier: "a", entityName: "Trip", temporaryIdentifier: uuid),
        ]
        for lhs in ids {
            #expect(!(lhs < lhs))
            for rhs in ids where lhs != rhs {
                #expect((lhs < rhs) != (rhs < lhs))
            }
        }
        let rows = ids.filter { $0.storeIdentifier == "a" && $0.entityName == "Trip" }.sorted()
        #expect(rows.map(\.primaryKey) == [2, 10])
    }

    @Test func `temporary identifiers round trip without a store`() throws {
        let temporary = PersistentIdentifier(storeIdentifier: "s", entityName: "Trip", temporaryIdentifier: uuid)
        let decoded = try JSONDecoder().decode(PersistentIdentifier.self, from: JSONEncoder().encode(temporary))
        #expect(decoded == temporary)
        #expect(decoded.isTemporary)
        #expect(decoded.storeIdentifier == nil)
    }

    @Test func `developer provided keys build permanent identifiers`() throws {
        let made = try PersistentIdentifier.identifier(for: "store", entityName: "Thing", primaryKey: "abc")
        let same = try PersistentIdentifier.identifier(for: "store", entityName: "Thing", primaryKey: "abc")
        let numeric = try PersistentIdentifier.identifier(for: "store", entityName: "Thing", primaryKey: 5)
        #expect(made.entityName == "Thing")
        #expect(made.storeIdentifier == "store")
        #expect(!made.isTemporary)
        #expect(made.primaryKey == nil)
        #expect(made == same)
        #expect(made.hashValue == same.hashValue)
        #expect(made != numeric)
        #expect(made.developerPrimaryKey(as: String.self) == "abc")
        #expect(numeric.developerPrimaryKey(as: Int.self) == 5)
        #expect(numeric.developerPrimaryKey(as: String.self) == nil)
    }

    @Test func `developer provided keys use the SwiftData coding format and round trip`() throws {
        let made = try PersistentIdentifier.identifier(for: "store", entityName: "Thing", primaryKey: "abc")
        let data = try JSONEncoder().encode(made)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let implementation = try #require(object["implementation"] as? [String: Any])
        #expect(Array(object.keys) == ["implementation"])
        #expect(implementation["primaryKey"] as? String == "abc")
        #expect(implementation["typedPrimaryKey"] as? String == "abc")
        #expect(implementation["storeIdentifier"] as? String == "store")
        #expect(implementation["isTemporary"] as? Bool == false)
        #expect(implementation["uriRepresentation"] as? String == "developer-provided://store/Thing/abc")
        #expect(try JSONDecoder().decode(PersistentIdentifier.self, from: data) == made)

        let numeric = try PersistentIdentifier.identifier(for: "store", entityName: "Thing", primaryKey: 5)
        #expect(try JSONDecoder().decode(PersistentIdentifier.self, from: JSONEncoder().encode(numeric)) == numeric)
    }

    @Test func `decodes identifiers encoded by SwiftData`() throws {
        let permanent = """
            {"implementation":{"entityName":"Thing","isTemporary":false,"primaryKey":"p1",\
            "storeIdentifier":"CC259F7B-10A2-4132-A41A-2AAB83D11A0D",\
            "uriRepresentation":"x-coredata:\\/\\/CC259F7B-10A2-4132-A41A-2AAB83D11A0D\\/Thing\\/p1"}}
            """
        let decoded = try JSONDecoder().decode(PersistentIdentifier.self, from: Data(permanent.utf8))
        #expect(
            decoded
                == PersistentIdentifier(
                    storeIdentifier: "CC259F7B-10A2-4132-A41A-2AAB83D11A0D", entityName: "Thing", primaryKey: 1))

        let temporary = """
            {"implementation":{"entityName":"Thing","isTemporary":true,\
            "primaryKey":"312DE7FD-1241-49AA-B170-AA6C8853D480",\
            "uriRepresentation":"x-swiftdata:\\/\\/Thing\\/312DE7FD-1241-49AA-B170-AA6C8853D480"}}
            """
        let decodedTemporary = try JSONDecoder().decode(PersistentIdentifier.self, from: Data(temporary.utf8))
        #expect(decodedTemporary.temporaryIdentifier?.uuidString == "312DE7FD-1241-49AA-B170-AA6C8853D480")
        #expect(decodedTemporary.storeIdentifier == nil)

        let developer = """
            {"implementation":{"entityName":"Thing","isTemporary":false,"primaryKey":"abc",\
            "storeIdentifier":"store","typedPrimaryKey":"abc",\
            "uriRepresentation":"developer-provided:\\/\\/store\\/Thing\\/abc"}}
            """
        let decodedDeveloper = try JSONDecoder().decode(PersistentIdentifier.self, from: Data(developer.utf8))
        #expect(
            decodedDeveloper
                == (try PersistentIdentifier.identifier(
                    for: "store", entityName: "Thing", primaryKey: "abc")))
    }

    @Test func `decodes the legacy tagged format`() throws {
        let legacy = """
            {"entityName":"Trip","kind":"primaryKey","payload":{"primaryKey":{"value":17}},"storeIdentifier":"store-A"}
            """
        let decoded = try JSONDecoder().decode(PersistentIdentifier.self, from: Data(legacy.utf8))
        #expect(decoded == PersistentIdentifier(storeIdentifier: "store-A", entityName: "Trip", primaryKey: 17))
    }

    @Test(arguments: [
        #"{"implementation":{"entityName":"T","isTemporary":true,"primaryKey":"not-a-uuid"}}"#,
        #"{"implementation":{"entityName":"T","isTemporary":false,"primaryKey":"x1","storeIdentifier":"s"}}"#,
        #"{"implementation":{"entityName":"T","primaryKey":"p1"}}"#,
    ])
    func `rejects malformed SwiftData payloads`(payload: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PersistentIdentifier.self, from: Data(payload.utf8))
        }
    }
}
