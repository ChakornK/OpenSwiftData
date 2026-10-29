import Foundation
import XCTest
@testable import OSDCore

private struct PredicateScalarComposite: Codable {
    let value: Int
}

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

    func testPredicateScalarEncodingMatchesPersistedScalarEncoding() throws {
        XCTAssertEqual(try StoredValue(predicateScalar: true), try Codec.encode(true))
        XCTAssertEqual(try StoredValue(predicateScalar: Int8(-2)), try Codec.encode(Int8(-2)))
        XCTAssertEqual(try StoredValue(predicateScalar: Int64(5)), try Codec.encode(Int64(5)))
        XCTAssertEqual(try StoredValue(predicateScalar: UInt32(8)), try Codec.encode(UInt32(8)))
        XCTAssertEqual(try StoredValue(predicateScalar: Float(1.25)), try Codec.encode(Float(1.25)))
        XCTAssertEqual(try StoredValue(predicateScalar: Double(2.5)), try Codec.encode(Double(2.5)))
        XCTAssertEqual(try StoredValue(predicateScalar: "value"), try Codec.encode("value"))
        XCTAssertEqual(
            try StoredValue(predicateScalar: URL(string: "https://example.com")!),
            try Codec.encode(URL(string: "https://example.com")!))
        XCTAssertEqual(
            try StoredValue(predicateScalar: Date(timeIntervalSinceReferenceDate: 12.5)),
            try Codec.encode(Date(timeIntervalSinceReferenceDate: 12.5)))
        XCTAssertEqual(
            try StoredValue(predicateScalar: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            try Codec.encode(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        XCTAssertEqual(try StoredValue(predicateScalar: Data([1, 2, 3])), try Codec.encode(Data([1, 2, 3])))
        XCTAssertEqual(
            try StoredValue(predicateScalar: Decimal(string: "12.75")!), try Codec.encode(Decimal(string: "12.75")!))
        XCTAssertEqual(try StoredValue(predicateScalar: Optional<Int>.none), .null)
        XCTAssertEqual(try StoredValue(predicateScalar: Optional<Int>.some(7)), .int(7))
    }

    func testPredicateScalarEncodingRejectsCodableComposites() {
        XCTAssertThrowsError(try StoredValue(predicateScalar: PredicateScalarComposite(value: 3))) { error in
            XCTAssertEqual(
                error as? PredicateScalarEncodingError,
                .unsupportedType(String(reflecting: PredicateScalarComposite.self)))
        }
        let optionalComposite: PredicateScalarComposite? = PredicateScalarComposite(value: 4)
        XCTAssertEqual(try Codec.encode(optionalComposite), try Codec.encode(optionalComposite!))
        XCTAssertThrowsError(try StoredValue(predicateScalar: optionalComposite))
    }

    func testUnsignedOverflowThrowsWithoutTrapping() {
        XCTAssertThrowsError(try Codec.encode(UInt.max))
        XCTAssertThrowsError(try StoredValue(predicateScalar: UInt.max))
    }

    func testUInt64PredicateCaptureMatchesPersistedIntegerDomain() throws {
        XCTAssertEqual(try StoredValue(predicateScalar: UInt64(Int64.max)), .int(Int64.max))
        XCTAssertThrowsError(try StoredValue(predicateScalar: UInt64(Int64.max) + 1))
        XCTAssertThrowsError(try Codec.encode(UInt64(Int64.max) + 1))
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
