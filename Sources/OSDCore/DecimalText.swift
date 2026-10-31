import Foundation

package enum DecimalText {
    private struct ParsedDecimal {
        let isNegative: Bool
        let digits: [UInt8]
        let exponent: SignedDecimalInteger
    }

    private struct SignedDecimalInteger {
        let isNegative: Bool
        let digits: [UInt8]

        init(isNegative: Bool, digits: [UInt8]) {
            let normalized = digits.drop(while: { $0 == 48 })
            self.digits = normalized.isEmpty ? [48] : Array(normalized)
            self.isNegative = isNegative && self.digits != [48]
        }

        func compare(to other: Self) -> ComparisonResult {
            if isNegative != other.isNegative { return isNegative ? .orderedAscending : .orderedDescending }
            let magnitude = compareMagnitude(digits, other.digits)
            return isNegative ? reversed(magnitude) : magnitude
        }
    }

    package static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (parse(lhs), parse(rhs)) {
        case let (left?, right?): compare(left, right)
        case (.some, .none): .orderedAscending
        case (.none, .some): .orderedDescending
        case (.none, .none): compareBytes(lhs, rhs)
        }
    }

    private static func parse(_ value: String) -> ParsedDecimal? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return nil }
        var index = 0
        var isNegative = false
        if bytes[index] == 43 || bytes[index] == 45 {
            isNegative = bytes[index] == 45
            index += 1
        }

        let integerStart = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        let integerDigits = Array(bytes[integerStart..<index])
        var fractionalDigits: [UInt8] = []
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            let fractionStart = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            fractionalDigits = Array(bytes[fractionStart..<index])
        }
        guard !integerDigits.isEmpty || !fractionalDigits.isEmpty else { return nil }

        var explicitExponent = SignedDecimalInteger(isNegative: false, digits: [48])
        if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
            index += 1
            var exponentIsNegative = false
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
                exponentIsNegative = bytes[index] == 45
                index += 1
            }
            let exponentStart = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > exponentStart else { return nil }
            explicitExponent = SignedDecimalInteger(
                isNegative: exponentIsNegative,
                digits: Array(bytes[exponentStart..<index]))
        }
        guard index == bytes.count else { return nil }

        let allDigits = integerDigits + fractionalDigits
        let leadingTrimmed = Array(allDigits.drop(while: { $0 == 48 }))
        if leadingTrimmed.isEmpty {
            return ParsedDecimal(
                isNegative: false,
                digits: [48],
                exponent: SignedDecimalInteger(isNegative: false, digits: [48]))
        }
        let trailingZeros = allDigits.reversed().prefix(while: { $0 == 48 }).count
        let significantDigits = Array(leadingTrimmed.dropLast(trailingZeros))
        let integerDigitsBeforePoint = integerDigits.count
        let leadingZeros = allDigits.count - leadingTrimmed.count
        let pointOffset = integerDigitsBeforePoint - leadingZeros
        let decimalExponent = SignedDecimalInteger(
            isNegative: pointOffset < 0,
            digits: decimalDigits(abs(pointOffset)))
        let normalizedExponent = add(decimalExponent, explicitExponent)
        return ParsedDecimal(
            isNegative: isNegative,
            digits: significantDigits,
            exponent: normalizedExponent)
    }

    private static func compare(_ lhs: ParsedDecimal, _ rhs: ParsedDecimal) -> ComparisonResult {
        if lhs.digits == [48], rhs.digits == [48] { return .orderedSame }
        if lhs.isNegative != rhs.isNegative { return lhs.isNegative ? .orderedAscending : .orderedDescending }
        let magnitude = compareMagnitude(lhs, rhs)
        return lhs.isNegative ? reversed(magnitude) : magnitude
    }

    private static func compareMagnitude(_ lhs: ParsedDecimal, _ rhs: ParsedDecimal) -> ComparisonResult {
        let exponentComparison = lhs.exponent.compare(to: rhs.exponent)
        guard exponentComparison == .orderedSame else { return exponentComparison }
        let count = max(lhs.digits.count, rhs.digits.count)
        for index in 0..<count {
            let left = index < lhs.digits.count ? lhs.digits[index] : 48
            let right = index < rhs.digits.count ? rhs.digits[index] : 48
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func compareMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func add(_ lhs: SignedDecimalInteger, _ rhs: SignedDecimalInteger) -> SignedDecimalInteger {
        if lhs.isNegative == rhs.isNegative {
            return SignedDecimalInteger(isNegative: lhs.isNegative, digits: addMagnitude(lhs.digits, rhs.digits))
        }
        let magnitudeComparison = compareMagnitude(lhs.digits, rhs.digits)
        if magnitudeComparison == .orderedSame { return SignedDecimalInteger(isNegative: false, digits: [48]) }
        if magnitudeComparison == .orderedDescending {
            return SignedDecimalInteger(
                isNegative: lhs.isNegative, digits: subtractMagnitude(lhs.digits, rhs.digits))
        }
        return SignedDecimalInteger(
            isNegative: rhs.isNegative, digits: subtractMagnitude(rhs.digits, lhs.digits))
    }

    private static func addMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var leftIndex = lhs.count
        var rightIndex = rhs.count
        var carry: UInt16 = 0
        while leftIndex > 0 || rightIndex > 0 || carry > 0 {
            let left = leftIndex > 0 ? UInt16(lhs[leftIndex - 1] - 48) : 0
            let right = rightIndex > 0 ? UInt16(rhs[rightIndex - 1] - 48) : 0
            let sum = left + right + carry
            result.append(UInt8(sum % 10) + 48)
            carry = sum / 10
            if leftIndex > 0 { leftIndex -= 1 }
            if rightIndex > 0 { rightIndex -= 1 }
        }
        return result.reversed()
    }

    private static func subtractMagnitude(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var leftIndex = lhs.count
        var rightIndex = rhs.count
        var borrow: Int16 = 0
        while leftIndex > 0 {
            var digit = Int16(lhs[leftIndex - 1] - 48) - borrow
            let right = rightIndex > 0 ? Int16(rhs[rightIndex - 1] - 48) : 0
            if digit < right {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt8(digit - right) + 48)
            leftIndex -= 1
            if rightIndex > 0 { rightIndex -= 1 }
        }
        return Array(result.reversed().drop(while: { $0 == 48 }))
    }

    private static func decimalDigits(_ value: Int) -> [UInt8] {
        Array(String(value).utf8)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    private static func compareBytes(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    private static func reversed(_ comparison: ComparisonResult) -> ComparisonResult {
        switch comparison {
        case .orderedAscending: .orderedDescending
        case .orderedSame: .orderedSame
        case .orderedDescending: .orderedAscending
        @unknown default: .orderedSame
        }
    }
}
