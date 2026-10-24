import Foundation
import XCTest
@testable import OSDCore

final class StoredValueTests: XCTestCase {
    func testCodableRoundTripsEveryCase() throws {
        let values: [StoredValue] = [
            .null,
            .int(-9_223_372_036_854_775_000),
            .double(12.5),
            .text("portable 🧭"),
            .blob([0, 1, 127, 255]),
        ]

        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(StoredValue.self, from: data), value)
        }
    }

    func testCodableUsesStableTaggedRepresentation() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(
            String(decoding: try encoder.encode(StoredValue.int(42)), as: UTF8.self),
            "{\"kind\":\"int\",\"payload\":{\"int\":{\"value\":42}}}"
        )
        XCTAssertEqual(
            String(decoding: try encoder.encode(StoredValue.null), as: UTF8.self),
            "{\"kind\":\"null\"}"
        )
    }

    func testDecodingRejectsMissingPayload() throws {
        let data = Data(#"{"kind":"blob"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(StoredValue.self, from: data))
    }

    func testDecodingRejectsUnknownCase() throws {
        let data = Data(#"{"kind":"date"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(StoredValue.self, from: data))
    }

    func testDecodingRejectsWrongPayloadType() {
        let invalidValues = [
            #"{"kind":"int","payload":42}"#,
            #"{"kind":"int","payload":{"int":{"value":"not an integer"}}}"#,
            #"{"kind":"text","payload":{"text":{"value":42}}}"#,
        ]

        for value in invalidValues {
            XCTAssertThrowsError(try JSONDecoder().decode(StoredValue.self, from: Data(value.utf8)))
        }
    }
}
