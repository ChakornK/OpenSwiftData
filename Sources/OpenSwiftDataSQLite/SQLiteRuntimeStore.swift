import Foundation
import OpenSwiftData
import OSDCore
import OSDStorage

private struct SQLiteRuntimeStore: RuntimeQueryStore, RuntimeHistoryStore {
    let driver: GRDBSQLiteDriver
    let externalDataColumns: Set<String>

    func read<T>(_ body: (any RuntimeConnection) throws -> T) throws -> T {
        try driver.read { connection in
            try body(SQLiteRuntimeConnection(connection: connection, externalDataColumns: externalDataColumns))
        }
    }

    func write<T>(_ body: (any RuntimeConnection) throws -> T) throws -> T {
        try driver.write { connection in
            try body(SQLiteRuntimeConnection(connection: connection, externalDataColumns: externalDataColumns))
        }
    }

    func writeWithExternalData<T>(
        _ body: (any RuntimeConnection, ExternalDataWriteSession) throws -> T
    ) throws -> T {
        try driver.writeWithExternalData { connection, session in
            return try body(
                SQLiteRuntimeConnection(connection: connection, externalDataColumns: externalDataColumns), session)
        }
    }

    func close() throws {
        try driver.close()
    }

    func dataVersion() throws -> Int64? {
        try driver.read { connection in
            guard let row = try connection.rows("PRAGMA data_version").first,
                case let .int(version)? = row.first
            else { return nil }
            return version
        }
    }

    func fetchHistory(_ descriptor: HistoryDescriptor) throws -> [HistoryTransaction] {
        if descriptor.fetchLimit == 0 { return [] }
        return try driver.read { connection in
            var sql = "SELECT id, timestamp, author FROM _osd_history_transactions"
            var arguments: [StoredValue] = []
            if let after = descriptor.after {
                sql += " WHERE id > ?"
                arguments.append(.int(after.rawValue))
            }
            sql += " ORDER BY id ASC"
            if let fetchLimit = descriptor.fetchLimit {
                sql += " LIMIT ?"
                arguments.append(.int(Int64(fetchLimit)))
            }
            let transactionRows = try connection.rows(sql, arguments)
            return try transactionRows.map { row in
                guard row.count >= 3, case let .int(id) = row[0], case let .double(timestamp) = row[1] else {
                    throw SwiftDataError.unsupportedStore("Malformed history transaction row.")
                }
                let author: String?
                if case let .text(value) = row[2] { author = value } else { author = nil }
                let changes = try connection.rows(
                    "SELECT ordinal, type, entity, primary_key FROM _osd_history_changes "
                        + "WHERE transaction_id = ? ORDER BY ordinal ASC",
                    [.int(id)]
                ).map { changeRow -> HistoryChange in
                    guard changeRow.count >= 4,
                        case let .int(ordinal) = changeRow[0],
                        case let .text(rawType) = changeRow[1],
                        let type = HistoryChangeType(rawValue: rawType),
                        case let .text(entityName) = changeRow[2],
                        case let .int(primaryKey) = changeRow[3]
                    else {
                        throw SwiftDataError.unsupportedStore("Malformed history change row.")
                    }
                    return HistoryChange(
                        type: type, entityName: entityName, primaryKey: primaryKey, ordinal: Int(ordinal))
                }
                return HistoryTransaction(
                    token: HistoryToken(rawValue: id), timestamp: Date(timeIntervalSince1970: timestamp),
                    author: author, changes: changes)
            }
        }
    }

    func deleteHistory(before token: HistoryToken) throws -> Int {
        try driver.write { connection in
            try connection.execute(
                "DELETE FROM _osd_history_changes WHERE transaction_id <= ?", [.int(token.rawValue)])
            try connection.execute(
                "DELETE FROM _osd_history_transactions WHERE id <= ?", [.int(token.rawValue)])
            return connection.changesCount()
        }
    }

    func compile(_ request: RuntimePredicateRequest) throws -> RuntimeCompiledPredicate {
        switch request.captureEncoding {
        case .typed:
            break
        case .legacyDescription:
            guard request.typedCaptures.isEmpty else {
                throw SwiftDataError.unsupportedPredicate("Typed captures require typed capture encoding")
            }
        default:
            throw SwiftDataError.unsupportedPredicate("Unsupported predicate capture encoding")
        }
        var consumedCaptures = Set<RuntimePredicatePath>()
        let node = try storageNode(
            request.root, path: [], captures: request.typedCaptures, attributeNames: request.attributeNames,
            usesTypedCaptures: request.captureEncoding == .typed, consumed: &consumedCaptures)
        guard consumedCaptures == Set(request.typedCaptures.keys) else {
            throw SwiftDataError.unsupportedPredicate("Predicate capture paths did not match the reflected tree")
        }
        let ir = try PredicateIRBuilder.build(node, attributeTypes: request.attributeTypes)
        let plan = PredicatePlanBuilder.build(ir)
        let compiled = try SQLCompiler.compile(
            ir, entity: request.entityName, ordering: request.ordering)
        return RuntimeCompiledPredicate(
            sql: compiled.sql, arguments: compiled.arguments.map(runtimeValue), evaluatorPlan: plan)
    }

    private func storageNode(
        _ node: RuntimePredicateNode,
        path: [String],
        captures: [RuntimePredicatePath: StoredValue],
        attributeNames: Set<String>,
        usesTypedCaptures: Bool,
        consumed: inout Set<RuntimePredicatePath>
    ) throws -> PredicateMirrorWalker.Node {
        switch node {
        case let .expression(name, children):
            guard let entry = PredicateNodeMetadata.entry(for: name) else {
                throw SwiftDataError.unsupportedPredicate(name)
            }
            let labels = children.map(\.0)
            guard Set(labels).count == labels.count, Set(labels) == entry.requiredChildren else {
                throw SwiftDataError.unsupportedPredicate("Malformed predicate node \(name)")
            }
            if (name == "KeyPath" || name == "Swift.KeyPath"),
                let property = children.first(where: { $0.0 == "keyPath" })?.1
            {
                let resolved = try storageNode(
                    property, path: path + ["keyPath"], captures: captures,
                    attributeNames: attributeNames, usesTypedCaptures: usesTypedCaptures, consumed: &consumed)
                guard case .propertyReference = resolved else {
                    throw SwiftDataError.unsupportedPredicate("Predicate KeyPath did not resolve to a model attribute")
                }
                return resolved
            }
            if name == "Value", usesTypedCaptures {
                guard children.count == 1, children[0].0 == "value" else {
                    throw SwiftDataError.unsupportedPredicate("Malformed typed Value predicate node")
                }
                let capturePath = RuntimePredicatePath(labels: path)
                guard let value = captures[capturePath] else {
                    throw SwiftDataError.unsupportedPredicate("Missing typed predicate capture at \(path)")
                }
                guard consumed.insert(capturePath).inserted else {
                    throw SwiftDataError.unsupportedPredicate("Duplicate typed predicate capture at \(path)")
                }
                return .expression(name: name, children: [("value", .typedValue(value))])
            }
            return .expression(
                name: name,
                children: try children.map { label, child in
                    (
                        label,
                        try storageNode(
                            child, path: path + [label], captures: captures,
                            attributeNames: attributeNames,
                            usesTypedCaptures: usesTypedCaptures, consumed: &consumed)
                    )
                })
        case let .property(reference):
            guard attributeNames.contains(reference.name) else {
                throw SwiftDataError.unsupportedPredicate(
                    "Predicate references unknown attribute '\(reference.name)'; allowed: \(attributeNames.sorted())")
            }
            return .propertyReference(reference.name)
        case let .capture(typeName, description):
            return .capture(typeName: typeName, description: description)
        }
    }

    private func runtimeValue(_ value: StoredValue) -> RuntimeValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

}

private struct SQLiteRuntimeConnection: RuntimeConnection {
    let connection: SQLConnection
    let externalDataColumns: Set<String>

    func execute(_ sql: String, arguments: [RuntimeValue]) throws {
        try connection.execute(sql, arguments.map(Self.storageValue))
    }

    func rows(_ sql: String, arguments: [RuntimeValue]) throws -> [[RuntimeValue]] {
        let selectedColumns = SQLiteExternalColumnBinding.selectedColumnNames(
            in: sql, externalDataColumns: externalDataColumns)
        return try connection.rows(sql, arguments.map(Self.storageValue)).map { row in
            try row.enumerated().map { index, value in
                let isExternal = selectedColumns.indices.contains(index) && selectedColumns[index]
                return try Self.runtimeValue(isExternal ? connection.resolved(value) : value)
            }
        }
    }

    func lastInsertRowID() -> Int64 { connection.lastInsertRowID() }
    func changesCount() -> Int { connection.changesCount() }

    func recordHistory(_ changes: [RuntimeHistoryChange], timestamp: Date, author: String?) throws {
        guard !changes.isEmpty else { return }
        try connection.execute(
            "INSERT INTO _osd_history_transactions (timestamp, author) VALUES (?, ?)",
            [.double(timestamp.timeIntervalSince1970), author.map(StoredValue.text) ?? .null])
        let transactionID = connection.lastInsertRowID()
        for (ordinal, change) in changes.enumerated() {
            try connection.execute(
                "INSERT INTO _osd_history_changes "
                    + "(transaction_id, ordinal, type, entity, primary_key) VALUES (?, ?, ?, ?, ?)",
                [
                    .int(transactionID), .int(Int64(ordinal)), .text(change.type.rawValue),
                    .text(change.entityName), .int(change.primaryKey),
                ])
        }
    }

    private static func storageValue(_ value: RuntimeValue) -> StoredValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

    private static func runtimeValue(_ value: StoredValue) throws -> RuntimeValue {
        switch value {
        case .null: .null
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .text(value): .text(value)
        case let .blob(value): .blob(value)
        }
    }

}

private enum SQLiteExternalColumnBinding {
    static func selectedColumnNames(in sql: String, externalDataColumns: Set<String>) -> [Bool] {
        guard let select = sql.range(of: "SELECT ", options: .caseInsensitive),
            let from = sql.range(of: " FROM ", options: .caseInsensitive),
            select.upperBound <= from.lowerBound
        else { return [] }
        let tableClause = sql[from.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let table = tableClause.uppercased()
        let projected = sql[select.upperBound..<from.lowerBound].split(separator: ",")
        return projected.map { raw in
            let expression = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let column = expression.split(separator: ".").last.map(String.init) ?? expression
            let normalizedColumn = column.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
            return externalDataColumns.contains("\(table).\(normalizedColumn)")
        }
    }

}

/// SQLite store composition for OpenSwiftData containers.
public enum OpenSwiftDataSQLite {
    static let sqliteVersionReader: RuntimeSchemaVersionReader = { location in
        let driverLocation: StoreLocation =
            switch location {
            case let .memory(name): .memory(name: name)
            case let .file(url): .file(url)
            }
        let driver = try GRDBSQLiteDriver(location: driverLocation)
        defer { try? driver.close() }
        return try driver.read { try LightweightMigration.storedSchemaVersion(connection: $0) }
    }

    static let sqliteFactory: RuntimeStoreFactory = { location, schema in
        let driverLocation: StoreLocation =
            switch location {
            case let .memory(name): .memory(name: name)
            case let .file(url): .file(url)
            }
        let externalDataColumns: Set<String> = Set(
            schema.entities.flatMap { entity in
                entity.attributes.compactMap { attribute in
                    guard attribute.options.contains(.externalStorage) else { return nil }
                    return "Z\(entity.name.uppercased()).Z\(attribute.name.uppercased())"
                }
            })
        let driver = try LightweightMigration.openStore(
            location: driverLocation, schema: schema, externalColumns: externalDataColumns)
        let store = SQLiteRuntimeStore(driver: driver, externalDataColumns: externalDataColumns)
        return store
    }
}

extension ModelConfiguration {
    /// Creates a SQLite-backed configuration for memory storage.
    public static func sqliteMemory(_ name: String = "default", allowsSave: Bool = true) -> Self {
        Self(
            name, isStoredInMemoryOnly: true, allowsSave: allowsSave,
            storeFactory: OpenSwiftDataSQLite.sqliteFactory,
            schemaVersionReader: OpenSwiftDataSQLite.sqliteVersionReader)
    }

    /// Creates a SQLite-backed configuration at an explicit URL.
    public static func sqliteFile(
        _ name: String = "default",
        url: URL,
        allowsSave: Bool = true
    ) -> Self {
        Self(
            name, url: url, allowsSave: allowsSave,
            storeFactory: OpenSwiftDataSQLite.sqliteFactory,
            schemaVersionReader: OpenSwiftDataSQLite.sqliteVersionReader)
    }
}
