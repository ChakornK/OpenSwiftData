import Foundation
import CoreFoundation
import GRDB
import OSDCore

package enum StoreLocation: Sendable {
    case file(URL)
    case memory(name: String)
}

package protocol SQLiteDriver: Sendable {
    func read<T>(_ body: (SQLConnection) throws -> T) throws -> T
    func write<T>(_ body: (SQLConnection) throws -> T) throws -> T
    func close() throws
    func writeWithExternalData<T>(_ body: (SQLConnection, ExternalDataWriteSession) throws -> T) throws -> T
}

package final class GRDBSQLiteDriver: SQLiteDriver, Sendable {
    private enum DatabaseStorage: Sendable {
        case queue(DatabaseQueue)
        case pool(DatabasePool)
    }

    private let storage: DatabaseStorage
    private let externalStorage: ExternalStorage?
    private let externalColumns: Set<String>

    package init(
        location: StoreLocation,
        externalColumns: Set<String> = [],
        externalStorageOperations: ExternalStorageFileOperations = .live
    ) throws {
        self.externalColumns = externalColumns
        let externalStorage: ExternalStorage?
        switch location {
        case let .memory(name):
            externalStorage = nil
            var configuration = Self.configuration(name: name)
            configuration.journalMode = .default
            storage = .queue(try DatabaseQueue(path: ":memory:", configuration: configuration))
        case let .file(url):
            externalStorage = try ExternalStorage(databaseURL: url, operations: externalStorageOperations)
            var configuration = Self.configuration(name: nil)
            configuration.maximumReaderCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4))
            configuration.journalMode = .wal
            storage = .pool(try DatabasePool(path: url.path, configuration: configuration))
        }
        self.externalStorage = externalStorage
    }

    package func read<T>(_ body: (SQLConnection) throws -> T) throws -> T {
        switch storage {
        case let .queue(queue):
            try queue.read {
                try body(
                    SQLConnection(database: $0, externalStorage: externalStorage, externalColumns: externalColumns))
            }
        case let .pool(pool):
            try pool.read {
                try body(
                    SQLConnection(database: $0, externalStorage: externalStorage, externalColumns: externalColumns))
            }
        }
    }

    package func write<T>(_ body: (SQLConnection) throws -> T) throws -> T {
        try writeTransaction { connection, _ in try body(connection) }
    }

    package func close() throws {
        switch storage {
        case let .queue(queue):
            try queue.close()
        case let .pool(pool):
            try pool.close()
        }
    }

    package func writeWithExternalData<T>(
        _ body: (SQLConnection, ExternalDataWriteSession) throws -> T
    ) throws -> T {
        try writeTransaction(body)
    }

    private func writeTransaction<T>(
        _ body: (SQLConnection, ExternalDataWriteSession) throws -> T
    ) throws -> T {
        switch storage {
        case let .queue(queue):
            return try queue.write { database in
                try write(database, body: body)
            }
        case let .pool(pool):
            var result: T?
            try pool.writeInTransaction { database in
                result = try write(database, body: body)
                return .commit
            }
            guard let result else { throw SwiftDataError.unsupportedStore("SQLite write returned no result.") }
            return result
        }
    }

    private func write<T>(
        _ database: Database,
        body: (SQLConnection, ExternalDataWriteSession) throws -> T
    ) throws -> T {
        let pending = PendingExternalFiles()
        let actions = AfterCommitActions()
        let connection = SQLConnection(
            database: database, externalStorage: externalStorage,
            pendingExternalFiles: pending, externalColumns: externalColumns,
            afterCommitActions: actions)
        let session = ExternalDataWriteSession { bytes in
            try connection.externalizedData(bytes)
        }
        do {
            let result = try body(connection, session)
            if let externalStorage {
                actions.append {
                    do {
                        try connection.reconcileExternalFiles()
                        pending.clear()
                    } catch {
                        OSDLog.debug("External Data orphan cleanup failed: \(error)")
                    }
                }
                database.afterNextTransaction(
                    onCommit: { _ in actions.run() },
                    onRollback: { _ in externalStorage.rollback(pending) })
            }
            return result
        } catch {
            externalStorage?.rollback(pending)
            throw error
        }
    }

    private static func configuration(name: String?) -> Configuration {
        var configuration = Configuration()
        configuration.label = name.map { "OpenSwiftData.\($0)" } ?? "OpenSwiftData.SQLiteDriver"
        configuration.prepareDatabase { database in
            database.add(collation: .localizedStandardCompare)
            database.add(collation: DatabaseCollation("OSD_DECIMAL", function: DecimalText.compare))
            database.add(
                function: DatabaseFunction("osd_localized_standard_contains", argumentCount: 2, pure: true) { values in
                    guard let haystack = String.fromDatabaseValue(values[0]),
                        let needle = String.fromDatabaseValue(values[1])
                    else { return nil }
                    return OSDStringMatch.localizedStandardContains(haystack, needle) ? 1 : 0
                })
            database.add(
                function: DatabaseFunction("osd_string_contains", argumentCount: 2, pure: true) { values in
                    guard let haystack = String.fromDatabaseValue(values[0]),
                        let needle = String.fromDatabaseValue(values[1])
                    else { return nil }
                    return OSDStringMatch.contains(haystack, needle) ? 1 : 0
                })
            database.add(
                function: DatabaseFunction("osd_string_starts_with", argumentCount: 2, pure: true) { values in
                    guard let value = String.fromDatabaseValue(values[0]),
                        let prefix = String.fromDatabaseValue(values[1])
                    else { return nil }
                    return OSDStringMatch.startsWith(value, prefix) ? 1 : 0
                })
            database.add(
                function: DatabaseFunction("osd_json_array_contains", argumentCount: 3, pure: true) { values in
                    Self.jsonArrayMembership(values, all: false)
                })
            database.add(
                function: DatabaseFunction("osd_json_array_all_equal", argumentCount: 3, pure: true) { values in
                    Self.jsonArrayMembership(values, all: true)
                })
            database.add(
                function: DatabaseFunction("osd_json_array_all_compare", argumentCount: 4, pure: true) { values in
                    Self.jsonArrayAllCompare(values)
                })
            database.add(
                function: DatabaseFunction("osd_json_array_is_empty", argumentCount: 1, pure: true) { values in
                    guard values.count == 1, let data = Data.fromDatabaseValue(values[0]),
                        let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
                    else { return nil }
                    return array.isEmpty ? 1 : 0
                })
            database.add(
                function: DatabaseFunction("osd_json_array_count", argumentCount: 1, pure: true) { values in
                    guard values.count == 1, let data = Data.fromDatabaseValue(values[0]),
                        let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
                    else { return nil }
                    return array.count
                })
            for (name, operation) in [
                ("osd_int_add", IntegerOperation.add),
                ("osd_int_subtract", IntegerOperation.subtract),
                ("osd_int_multiply", IntegerOperation.multiply),
                ("osd_int_divide", IntegerOperation.divide),
                ("osd_int_remainder", IntegerOperation.remainder),
            ] {
                database.add(
                    function: DatabaseFunction(name, argumentCount: 2, pure: true) { values in
                        checkedIntegerArithmetic(values, operation: operation)
                    })
            }
            for (name, operation) in [
                ("osd_int_bounded_add", IntegerOperation.add),
                ("osd_int_bounded_subtract", IntegerOperation.subtract),
                ("osd_int_bounded_multiply", IntegerOperation.multiply),
                ("osd_int_bounded_divide", IntegerOperation.divide),
                ("osd_int_bounded_remainder", IntegerOperation.remainder),
            ] {
                database.add(
                    function: DatabaseFunction(name, argumentCount: 3, pure: true) { values in
                        checkedBoundedIntegerArithmetic(values, operation: operation)
                    })
            }
            database.add(
                function: DatabaseFunction("osd_int_negate", argumentCount: 2, pure: true) { values in
                    checkedIntegerNegation(values)
                })
            for (name, operation) in [
                ("osd_real_add", RealOperation.add),
                ("osd_real_subtract", RealOperation.subtract),
                ("osd_real_multiply", RealOperation.multiply),
                ("osd_real_divide", RealOperation.divide),
            ] {
                database.add(
                    function: DatabaseFunction(name, argumentCount: 2, pure: true) { values in
                        checkedRealArithmetic(values, operation: operation)
                    })
            }
            database.add(
                function: DatabaseFunction("osd_real_negate", argumentCount: 1, pure: true) { values in
                    guard values.count == 1, let value = Double.fromDatabaseValue(values[0]), value.isFinite else {
                        return nil
                    }
                    return -value
                })
            for (name, operation) in [
                ("osd_f32_add", RealOperation.add),
                ("osd_f32_subtract", RealOperation.subtract),
                ("osd_f32_multiply", RealOperation.multiply),
                ("osd_f32_divide", RealOperation.divide),
            ] {
                database.add(
                    function: DatabaseFunction(name, argumentCount: 2, pure: true) { values in
                        checkedFloatArithmetic(values, operation: operation)
                    })
            }
            database.add(
                function: DatabaseFunction("osd_f32_negate", argumentCount: 1, pure: true) { values in
                    guard let value = floatOperand(values, index: 0) else { return nil }
                    let result = -value
                    return result.isFinite ? Double(result) : nil
                })
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(sql: "PRAGMA busy_timeout = 5000")
            try database.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        return configuration
    }

    private enum IntegerOperation {
        case add, subtract, multiply, divide, remainder
    }

    private enum RealOperation {
        case add, subtract, multiply, divide
    }

    private static func checkedIntegerArithmetic(
        _ values: [DatabaseValue], operation: IntegerOperation
    ) -> Int64? {
        guard values.count == 2,
            let lhs = Int64.fromDatabaseValue(values[0]),
            let rhs = Int64.fromDatabaseValue(values[1])
        else { return nil }
        let result: Int64?
        switch operation {
        case .add:
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            result = overflow ? nil : value
        case .subtract:
            let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
            result = overflow ? nil : value
        case .multiply:
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            result = overflow ? nil : value
        case .divide:
            result = rhs == 0 || (lhs == .min && rhs == -1) ? nil : lhs / rhs
        case .remainder:
            result = rhs == 0 || (lhs == .min && rhs == -1) ? nil : lhs % rhs
        }
        return result
    }

    private static func checkedBoundedIntegerArithmetic(
        _ values: [DatabaseValue], operation: IntegerOperation
    ) -> Int64? {
        guard values.count == 3,
            let lhs = Int64.fromDatabaseValue(values[0]),
            let rhs = Int64.fromDatabaseValue(values[1]),
            let widthValue = Int64.fromDatabaseValue(values[2]),
            let width = PredicateIntegerWidth(rawValue: Int(widthValue))
        else { return nil }
        if !width.isSigned,
            lhs < width.minimumValue || lhs > width.maximumValue
                || rhs < width.minimumValue || rhs > width.maximumValue
        {
            return nil
        }
        if width.isSigned, (operation == .divide || operation == .remainder), lhs == width.minimumValue, rhs == -1 {
            return nil
        }
        guard let result = checkedIntegerArithmetic([values[0], values[1]], operation: operation),
            result >= width.minimumValue, result <= width.maximumValue
        else { return nil }
        return result
    }

    private static func checkedIntegerNegation(_ values: [DatabaseValue]) -> Int64? {
        guard values.count == 2,
            let value = Int64.fromDatabaseValue(values[0]),
            let widthValue = Int64.fromDatabaseValue(values[1]),
            let width = PredicateIntegerWidth(rawValue: Int(widthValue))
        else { return nil }
        guard width.isSigned else { return nil }
        guard
            value >= width.minimumValue, value <= width.maximumValue,
            value != width.minimumValue
        else { return nil }
        return -value
    }

    private static func checkedRealArithmetic(
        _ values: [DatabaseValue], operation: RealOperation
    ) -> Double? {
        guard values.count == 2,
            let lhs = Double.fromDatabaseValue(values[0]), lhs.isFinite,
            let rhs = Double.fromDatabaseValue(values[1]), rhs.isFinite
        else { return nil }
        let result: Double
        switch operation {
        case .add: result = lhs + rhs
        case .subtract: result = lhs - rhs
        case .multiply: result = lhs * rhs
        case .divide: result = lhs / rhs
        }
        return result.isFinite ? result : nil
    }

    private static func floatOperand(_ values: [DatabaseValue], index: Int) -> Float? {
        guard values.indices.contains(index),
            let value = Double.fromDatabaseValue(values[index]),
            value.isFinite
        else { return nil }
        let rounded = Float(value)
        guard rounded.isFinite, Double(rounded) == value else { return nil }
        return rounded
    }

    private static func checkedFloatArithmetic(_ values: [DatabaseValue], operation: RealOperation) -> Double? {
        guard values.count == 2,
            let lhs = floatOperand(values, index: 0),
            let rhs = floatOperand(values, index: 1)
        else { return nil }
        let result: Float
        switch operation {
        case .add: result = lhs + rhs
        case .subtract: result = lhs - rhs
        case .multiply: result = lhs * rhs
        case .divide: result = lhs / rhs
        }
        return result.isFinite ? Double(result) : nil
    }

    private static func jsonArrayMembership(_ values: [DatabaseValue], all: Bool) -> Int? {
        guard values.count == 3,
            let data = Data.fromDatabaseValue(values[0]),
            let elementType = String.fromDatabaseValue(values[2]),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        let normalizedElementType =
            elementType.hasPrefix("Swift.Optional<")
            ? String(elementType.dropFirst("Swift.".count))
            : elementType
        let scalarElementType: String
        if normalizedElementType.hasPrefix("Optional<"), normalizedElementType.hasSuffix(">") {
            guard !all else { return nil }
            guard normalizedElementType.dropFirst("Optional<".count).dropLast().contains("<") == false else {
                return nil
            }
            scalarElementType = String(normalizedElementType.dropFirst("Optional<".count).dropLast())
            if values[1].isNull {
                return array.contains(where: { $0 is NSNull }) ? 1 : 0
            }
        } else {
            scalarElementType = elementType
            guard !values[1].isNull else { return nil }
        }
        switch scalarElementType {
        case "String":
            guard let needle = String.fromDatabaseValue(values[1]) else { return nil }
            let matches = array.map { ($0 as? String) == needle }
            return (all ? matches.allSatisfy { $0 } : matches.contains(true)) ? 1 : 0
        case "Bool":
            guard let needle = Bool.fromDatabaseValue(values[1]) else { return nil }
            let matches = array.map { value -> Bool in
                guard let number = value as? NSNumber,
                    CFGetTypeID(number) == CFBooleanGetTypeID()
                else { return false }
                return number.boolValue == needle
            }
            return (all ? matches.allSatisfy { $0 } : matches.contains(true)) ? 1 : 0
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            guard let needle = Int64.fromDatabaseValue(values[1]) else { return nil }
            let matches = array.map { value -> Bool in
                guard let number = value as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID()
                else { return false }
                return Int64(number.stringValue) == needle
            }
            return (all ? matches.allSatisfy { $0 } : matches.contains(true)) ? 1 : 0
        default:
            return nil
        }
    }

    private static func jsonArrayAllCompare(_ values: [DatabaseValue]) -> Int? {
        guard values.count == 4,
            let data = Data.fromDatabaseValue(values[0]),
            let elementType = String.fromDatabaseValue(values[2]),
            let operation = String.fromDatabaseValue(values[3])
        else { return nil }
        func matches(_ lhs: Int64, _ rhs: Int64) -> Bool {
            switch operation {
            case "lessThan": lhs < rhs
            case "lessThanOrEqual": lhs <= rhs
            case "greaterThan": lhs > rhs
            case "greaterThanOrEqual": lhs >= rhs
            default: false
            }
        }
        switch elementType {
        case "Int", "Int8", "Int16", "Int32", "Int64":
            guard let bound = Int64.fromDatabaseValue(values[1]),
                let elements = try? JSONDecoder().decode([Int64].self, from: data)
            else { return nil }
            return elements.allSatisfy { matches($0, bound) } ? 1 : 0
        case "UInt", "UInt64":
            let bound: UInt64?
            if let signed = Int64.fromDatabaseValue(values[1]), signed >= 0 {
                bound = UInt64(signed)
            } else if let text = String.fromDatabaseValue(values[1]) {
                bound = UInt64(text)
            } else {
                bound = nil
            }
            guard let bound,
                let elements = try? JSONDecoder().decode([UInt64].self, from: data)
            else { return nil }
            func matchesUnsigned(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
                switch operation {
                case "lessThan": lhs < rhs
                case "lessThanOrEqual": lhs <= rhs
                case "greaterThan": lhs > rhs
                case "greaterThanOrEqual": lhs >= rhs
                default: false
                }
            }
            return elements.allSatisfy { matchesUnsigned($0, bound) } ? 1 : 0
        default:
            return nil
        }
    }
}
