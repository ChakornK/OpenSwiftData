import Foundation
import XCTest
@testable import OSDCore

final class CodecTests: XCTestCase {
    func testUUIDUsesExactSixteenBytesAndRoundTrips() throws {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        let expected: [UInt8] = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        ]

        let stored = try PersistentValue.encode(uuid)
        XCTAssertEqual(stored, .blob(expected))
        XCTAssertEqual(try PersistentValue.decode(UUID.self, from: stored), uuid)
        XCTAssertThrowsError(try PersistentValue.decode(UUID.self, from: .blob(Array(repeating: 0, count: 15))))
    }

    func testDateReferenceIntervalAndIntegerDecoding() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1234.5)
        XCTAssertEqual(try PersistentValue.encode(date), .double(1234.5))
        XCTAssertEqual(try PersistentValue.decode(Date.self, from: .double(1234.5)), date)
        XCTAssertEqual(
            try PersistentValue.decode(Date.self, from: .int(1234)), Date(timeIntervalSinceReferenceDate: 1234))
    }

    func testBoolDecodesZeroAndNonzeroIntegers() throws {
        XCTAssertFalse(try PersistentValue.decode(Bool.self, from: .int(0)))
        XCTAssertTrue(try PersistentValue.decode(Bool.self, from: .int(-7)))
        XCTAssertEqual(try PersistentValue.encode(true), .int(1))
    }

    func testFloatUsesDoubleStorage() throws {
        XCTAssertEqual(try PersistentValue.encode(Float(1.25)), .double(1.25))
        XCTAssertEqual(try PersistentValue.decode(Float.self, from: .double(1.25)), Float(1.25))
    }

    func testDecimalUsesPOSIXText() throws {
        let decimal = Decimal(string: "1234.50", locale: Locale(identifier: "en_US_POSIX"))!
        let stored = try PersistentValue.encode(decimal)
        XCTAssertEqual(stored, .text(decimal.description))
        XCTAssertEqual(try PersistentValue.decode(Decimal.self, from: stored), decimal)
    }

    func testURLUsesAbsoluteString() throws {
        let url = URL(string: "https://example.com/a?b=c")!
        let stored = try PersistentValue.encode(url)
        XCTAssertEqual(stored, .text(url.absoluteString))
        XCTAssertEqual(try PersistentValue.decode(URL.self, from: stored), url)
    }

    func testCodableUsesSortedJSON() throws {
        struct Payload: Codable, Equatable {
            let z: Int
            let a: String
        }

        let payload = Payload(z: 2, a: "first")
        let stored = try PersistentValue.encode(payload)
        XCTAssertEqual(stored, .blob(Array(#"{"a":"first","z":2}"#.utf8)))
        XCTAssertEqual(try PersistentValue.decode(Payload.self, from: stored), payload)
    }

    func testSignedAndUnsignedIntegerRoundTrips() throws {
        XCTAssertEqual(try PersistentValue.encode(Int.min), .int(Int64(Int.min)))
        XCTAssertEqual(try PersistentValue.encode(Int8.min), .int(Int64(Int8.min)))
        XCTAssertEqual(try PersistentValue.encode(Int16.max), .int(Int64(Int16.max)))
        XCTAssertEqual(try PersistentValue.encode(Int32.min), .int(Int64(Int32.min)))
        XCTAssertEqual(try PersistentValue.encode(Int64.max), .int(Int64.max))
        XCTAssertEqual(try PersistentValue.encode(UInt8.max), .int(Int64(UInt8.max)))
        XCTAssertEqual(try PersistentValue.encode(UInt16.max), .int(Int64(UInt16.max)))
        XCTAssertEqual(try PersistentValue.encode(UInt32.max), .int(Int64(UInt32.max)))
        XCTAssertEqual(try PersistentValue.encode(UInt64(Int64.max)), .int(Int64.max))

        XCTAssertEqual(try PersistentValue.decode(Int8.self, from: .int(-128)), Int8.min)
        XCTAssertEqual(try PersistentValue.decode(UInt8.self, from: .int(255)), UInt8.max)
        XCTAssertEqual(try PersistentValue.decode(Int64.self, from: .int(Int64.min)), Int64.min)
        XCTAssertEqual(try PersistentValue.decode(UInt64.self, from: .int(Int64.max)), UInt64(Int64.max))
    }

    func testIntegerOutOfRangeThrows() {
        XCTAssertThrowsError(try PersistentValue.encode(UInt64.max))
        XCTAssertThrowsError(try PersistentValue.decode(UInt8.self, from: .int(256)))
        XCTAssertThrowsError(try PersistentValue.decode(UInt8.self, from: .int(-1)))
    }

    func testRawRepresentableEnumsRoundTripThroughRawValue() throws {
        enum State: String, Codable {
            case ready
            case done
        }
        enum Code: Int, Codable {
            case first = 1
            case second = 2
        }

        XCTAssertEqual(try PersistentValue.encode(State.ready), .text("ready"))
        XCTAssertEqual(try PersistentValue.decode(State.self, from: .text("done")), .done)
        XCTAssertEqual(try PersistentValue.encode(Code.second), .int(2))
        XCTAssertEqual(try PersistentValue.decode(Code.self, from: .int(1)), .first)
        XCTAssertThrowsError(try PersistentValue.decode(State.self, from: .text("unknown")))
    }
}
