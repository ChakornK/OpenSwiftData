import XCTest
@testable import OSDCore

final class DecimalTextTests: XCTestCase {
    func testComparesDecimalStringsNumericallyWithoutDoubleConversion() {
        XCTAssertEqual(DecimalText.compare("9", "10"), .orderedAscending)
        XCTAssertEqual(DecimalText.compare("10", "9"), .orderedDescending)
        XCTAssertEqual(DecimalText.compare("-10", "-9"), .orderedAscending)
        XCTAssertEqual(DecimalText.compare("-1", "-0.5"), .orderedAscending)
        XCTAssertEqual(DecimalText.compare("1e3", "999"), .orderedDescending)
        XCTAssertEqual(DecimalText.compare("1e128", "9e127"), .orderedDescending)
        XCTAssertEqual(DecimalText.compare("-1e128", "-9e127"), .orderedAscending)
        XCTAssertEqual(DecimalText.compare("1e-400", "9e-401"), .orderedDescending)
        XCTAssertEqual(DecimalText.compare(".5", "0.50"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("5.", "+5"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("10", "1e1"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("1.20", "1.19"), .orderedDescending)
        XCTAssertEqual(DecimalText.compare("120.20", "2.10e+10"), .orderedAscending)
        XCTAssertEqual(DecimalText.compare("2.10e+10", "120.20"), .orderedDescending)
        XCTAssertEqual(DecimalText.compare("0.00100", "1e-3"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("1000", "1e3"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("0012.300", "12.3"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("-0", "0e99999999999999999999"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("0.0100", "0.01"), .orderedSame)
        XCTAssertEqual(
            DecimalText.compare("123456789012345678901234567890", "123456789012345678901234567891"),
            .orderedAscending)
    }

    func testLargeExponentComparisonDoesNotOverflow() {
        XCTAssertEqual(
            DecimalText.compare("1e99999999999999999999", "9e99999999999999999998"),
            .orderedDescending)
        XCTAssertEqual(
            DecimalText.compare("1e-99999999999999999999", "9e-99999999999999999998"),
            .orderedAscending)
    }

    func testMalformedDecimalTextUsesDeterministicTotalOrdering() {
        XCTAssertEqual(DecimalText.compare("1x", "2x"), .orderedAscending)
        XCTAssertEqual(DecimalText.compare("1x", "1x"), .orderedSame)
        XCTAssertEqual(DecimalText.compare("2", "1x"), .orderedAscending)

        let values = ["-10", "-1", "0", "1", "2", "10", "bad"]
        for first in values {
            for second in values {
                for third in values
                where DecimalText.compare(first, second) != .orderedDescending
                    && DecimalText.compare(second, third) != .orderedDescending
                {
                    XCTAssertNotEqual(DecimalText.compare(first, third), .orderedDescending)
                }
            }
        }
    }
}
