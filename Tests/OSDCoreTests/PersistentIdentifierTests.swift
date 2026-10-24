import Foundation
import XCTest
@testable import OSDCore

final class PersistentIdentifierTests: XCTestCase {
    func testTemporaryIdentifierFieldsAndStatus() {
        let identifier = PersistentIdentifier(
            storeIdentifier: "store-A",
            entityName: "Trip",
            temporaryIdentifier: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )

        XCTAssertEqual(identifier.storeIdentifier, "store-A")
        XCTAssertEqual(identifier.entityName, "Trip")
        XCTAssertNil(identifier.primaryKey)
        XCTAssertEqual(identifier.temporaryIdentifier?.uuidString, "00112233-4455-6677-8899-AABBCCDDEEFF")
        XCTAssertTrue(identifier.isTemporary)
    }

    func testPermanentIdentifierFieldsAndStatus() {
        let identifier = PersistentIdentifier(storeIdentifier: "store-A", entityName: "Trip", primaryKey: 17)

        XCTAssertEqual(identifier.storeIdentifier, "store-A")
        XCTAssertEqual(identifier.entityName, "Trip")
        XCTAssertEqual(identifier.primaryKey, 17)
        XCTAssertNil(identifier.temporaryIdentifier)
        XCTAssertFalse(identifier.isTemporary)
    }

    func testIdentityIncludesStoreEntityAndKind() {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let firstTemporary = PersistentIdentifier(
            storeIdentifier: "store-A",
            entityName: "Trip",
            temporaryIdentifier: uuid
        )
        let sameTemporary = PersistentIdentifier(
            storeIdentifier: "store-A",
            entityName: "Trip",
            temporaryIdentifier: uuid
        )
        let otherStore = PersistentIdentifier(
            storeIdentifier: "store-B",
            entityName: "Trip",
            temporaryIdentifier: uuid
        )
        let otherEntity = PersistentIdentifier(
            storeIdentifier: "store-A",
            entityName: "Stop",
            temporaryIdentifier: uuid
        )
        let permanent = PersistentIdentifier(storeIdentifier: "store-A", entityName: "Trip", primaryKey: 1)

        XCTAssertEqual(firstTemporary, sameTemporary)
        XCTAssertEqual(Set([firstTemporary, sameTemporary]).count, 1)
        XCTAssertNotEqual(firstTemporary, otherStore)
        XCTAssertNotEqual(firstTemporary, otherEntity)
        XCTAssertNotEqual(firstTemporary, permanent)
    }

    func testCodableRoundTripsTemporaryAndPermanentIdentifiers() throws {
        let values = [
            PersistentIdentifier(
                storeIdentifier: "store-A",
                entityName: "Trip",
                temporaryIdentifier: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
            ),
            PersistentIdentifier(storeIdentifier: "store-A", entityName: "Trip", primaryKey: 17),
        ]

        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(PersistentIdentifier.self, from: data), value)
        }
    }

    func testCodableRepresentationIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let permanent = PersistentIdentifier(storeIdentifier: "store-A", entityName: "Trip", primaryKey: 17)
        XCTAssertEqual(
            String(decoding: try encoder.encode(permanent), as: UTF8.self),
            "{\"entityName\":\"Trip\",\"kind\":\"primaryKey\",\"payload\":{\"primaryKey\":{\"value\":17}},\"storeIdentifier\":\"store-A\"}"
        )

        let temporary = PersistentIdentifier(
            storeIdentifier: "store-A",
            entityName: "Trip",
            temporaryIdentifier: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )
        XCTAssertEqual(
            String(decoding: try encoder.encode(temporary), as: UTF8.self),
            "{\"entityName\":\"Trip\",\"kind\":\"temporary\",\"payload\":{\"temporaryIdentifier\":{\"value\":\"00112233-4455-6677-8899-AABBCCDDEEFF\"}},\"storeIdentifier\":\"store-A\"}"
        )
    }

    func testCodableRejectsMissingOrInvalidIdentifierPayload() {
        let invalidPayloads = [
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"primaryKey\"}",
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"temporary\"}",
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"unknown\",\"payload\":{\"primaryKey\":{\"value\":17}}}",
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"primaryKey\",\"payload\":17}",
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"primaryKey\",\"payload\":{\"primaryKey\":17}}",
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"temporary\",\"payload\":{\"temporaryIdentifier\":{\"value\":17}}}",
            "{\"storeIdentifier\":\"store-A\",\"entityName\":\"Trip\",\"kind\":\"primaryKey\",\"payload\":{\"temporaryIdentifier\":{\"value\":\"00112233-4455-6677-8899-AABBCCDDEEFF\"}}}",
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(try JSONDecoder().decode(PersistentIdentifier.self, from: Data(payload.utf8)))
        }
    }
}
