import Foundation
import OSDCore
import OSDStorage

private struct SQLiteRuntimeStore: RuntimeQueryStore, RuntimeHistoryStore, RuntimeSchemaProvidingStore {
    let driver: GRDBSQLiteDriver
    let externalDataColumns: Set<String>
    let runtimeSchema: SchemaDescriptor
    let persistentStoreIdentifier: String?

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

    func fetchHistory() throws -> [StoredHistoryTransaction] {
        try driver.read { connection in
            let transactionRows = try connection.rows(
                "SELECT id, timestamp, author, bundle_identifier, process_identifier "
                    + "FROM _osd_history_transactions ORDER BY id ASC", [])
            return try transactionRows.map { row in
                guard row.count >= 5, case let .int(id) = row[0], case let .double(timestamp) = row[1] else {
                    throw SwiftDataError.unsupportedStore("Malformed history transaction row.")
                }
                func text(_ value: StoredValue) -> String? {
                    if case let .text(string) = value { return string }
                    return nil
                }
                let changes = try connection.rows(
                    "SELECT type, entity, primary_key, details FROM _osd_history_changes "
                        + "WHERE transaction_id = ? ORDER BY ordinal ASC",
                    [.int(id)]
                ).map { changeRow -> StoredHistoryChange in
                    guard changeRow.count >= 4,
                        case let .text(rawType) = changeRow[0],
                        let type = HistoryChangeType(rawValue: rawType),
                        case let .text(entityName) = changeRow[1],
                        case let .int(primaryKey) = changeRow[2]
                    else {
                        throw SwiftDataError.unsupportedStore("Malformed history change row.")
                    }
                    var details = StoredHistoryChangeDetails()
                    if case let .blob(bytes) = changeRow[3] {
                        details = try JSONDecoder().decode(StoredHistoryChangeDetails.self, from: Data(bytes))
                    }
                    return StoredHistoryChange(
                        type: type, entityName: entityName, primaryKey: primaryKey,
                        updatedAttributes: details.updatedAttributes, tombstone: details.tombstone)
                }
                return StoredHistoryTransaction(
                    id: id, timestamp: Date(timeIntervalSince1970: timestamp), author: text(row[2]),
                    bundleIdentifier: text(row[3]) ?? "", processIdentifier: text(row[4]) ?? "", changes: changes)
            }
        }
    }

    func deleteHistory(transactionIDs: [Int64]) throws {
        guard !transactionIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: transactionIDs.count).joined(separator: ", ")
        let arguments = transactionIDs.map(StoredValue.int)
        try driver.write { connection in
            try connection.execute(
                "DELETE FROM _osd_history_changes WHERE transaction_id IN (\(placeholders))", arguments)
            try connection.execute("DELETE FROM _osd_history_transactions WHERE id IN (\(placeholders))", arguments)
        }
    }

    func latestIssuedHistoryTransactionID() throws -> Int64 {
        try driver.read { connection in
            let rows = try connection.rows(
                "SELECT seq FROM sqlite_sequence WHERE name = '_osd_history_transactions'", [])
            if case let .int(value)? = rows.first?.first { return value }
            return 0
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
        var consumedIdentifierCaptures = Set<RuntimePredicatePath>()
        let node = try storageNode(
            request.root,
            path: [],
            captures: request.typedCaptures,
            identifierCaptures: request.identifierCaptures,
            attributeNames: request.attributeNames,
            usesTypedCaptures: request.captureEncoding == .typed,
            consumed: &consumedCaptures,
            consumedIdentifierCaptures: &consumedIdentifierCaptures)
        guard consumedCaptures == Set(request.typedCaptures.keys) else {
            throw SwiftDataError.unsupportedPredicate("Predicate capture paths did not match the reflected tree")
        }
        guard consumedIdentifierCaptures == Set(request.identifierCaptures.keys) else {
            throw SwiftDataError.unsupportedPredicate(
                "Persistent identifier capture paths did not match the reflected tree")
        }
        let ir = try PredicateIRBuilder.build(
            node,
            attributeTypes: request.attributeTypes,
            optionalAttributeNames: request.optionalAttributeNames)
        let plan = PredicatePlanBuilder.build(ir)
        let compiled = try SQLCompiler.compile(
            ir,
            entity: request.entityName,
            ordering: request.ordering,
            relationships: request.relationships,
            storeIdentifier: request.storeIdentifier ?? "",
            entityIDsByName: runtimeSchema.entityIDsByName)
        return RuntimeCompiledPredicate(
            sql: compiled.sql, arguments: compiled.arguments.map(runtimeValue), evaluatorPlan: plan)
    }

    private func storageNode(
        _ node: RuntimePredicateNode,
        path: [String],
        captures: [RuntimePredicatePath: StoredValue],
        identifierCaptures: [RuntimePredicatePath: PersistentIdentifier],
        attributeNames: Set<String>,
        usesTypedCaptures: Bool,
        consumed: inout Set<RuntimePredicatePath>,
        consumedIdentifierCaptures: inout Set<RuntimePredicatePath>
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
                    identifierCaptures: identifierCaptures,
                    attributeNames: attributeNames,
                    usesTypedCaptures: usesTypedCaptures,
                    consumed: &consumed,
                    consumedIdentifierCaptures: &consumedIdentifierCaptures)
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
                if let identifier = identifierCaptures[capturePath] {
                    guard consumedIdentifierCaptures.insert(capturePath).inserted else {
                        throw SwiftDataError.unsupportedPredicate(
                            "Duplicate persistent identifier capture at \(path)")
                    }
                    return .expression(name: name, children: [("value", .identifierCapture(identifier))])
                }
                guard let value = captures[capturePath] else {
                    throw SwiftDataError.unsupportedPredicate("Missing typed predicate capture at \(path)")
                }
                guard consumed.insert(capturePath).inserted else {
                    throw SwiftDataError.unsupportedPredicate("Duplicate typed predicate capture at \(path)")
                }
                let captureTypeName: String
                if case let .capture(typeName, _)? = children.first?.1 {
                    captureTypeName = typeName
                } else {
                    captureTypeName = ""
                }
                return .expression(
                    name: name,
                    children: [("value", .typedCapture(value, typeName: captureTypeName))])
            }
            return .expression(
                name: name,
                children: try children.map { label, child in
                    (
                        label,
                        try storageNode(
                            child, path: path + [label], captures: captures,
                            identifierCaptures: identifierCaptures,
                            attributeNames: attributeNames,
                            usesTypedCaptures: usesTypedCaptures,
                            consumed: &consumed,
                            consumedIdentifierCaptures: &consumedIdentifierCaptures)
                    )
                })
        case let .property(reference):
            let components = reference.name.split(separator: ".").map(String.init)
            if components.last == PredicatePlanProperty.persistentIdentifier {
                return .persistentIdentifierReference(Array(components.dropLast()))
            }
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
            "INSERT INTO _osd_history_transactions "
                + "(timestamp, author, bundle_identifier, process_identifier) VALUES (?, ?, ?, ?)",
            [
                .double(timestamp.timeIntervalSince1970), author.map(StoredValue.text) ?? .null,
                .text(HistoryWriter.bundleIdentifier), .text(HistoryWriter.processIdentifier),
            ])
        let transactionID = connection.lastInsertRowID()
        for (ordinal, change) in changes.enumerated() {
            let details = try JSONEncoder().encode(
                StoredHistoryChangeDetails(updatedAttributes: change.updatedAttributes, tombstone: change.tombstone))
            try connection.execute(
                "INSERT INTO _osd_history_changes "
                    + "(transaction_id, ordinal, type, entity, primary_key, details) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .int(transactionID), .int(Int64(ordinal)), .text(change.type.rawValue),
                    .text(change.entityName), .int(change.primaryKey), .blob(Array(details)),
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

/// The built-in SQLite store provider used by default and SQLite configurations.
package enum SQLiteStoreProvider {
    package static let versionReader: RuntimeSchemaVersionReader = { location in
        let driverLocation: StoreLocation =
            switch location {
            case let .memory(name): .memory(name: name)
            case let .file(url): .file(url)
            }
        let driver = try GRDBSQLiteDriver(location: driverLocation)
        defer { try? driver.close() }
        return try driver.read { try LightweightMigration.storedSchemaVersion(connection: $0) }
    }

    package static let schemaCompatibilityReader: RuntimeSchemaCompatibilityReader = { location, schema in
        let driverLocation: StoreLocation =
            switch location {
            case let .memory(name): .memory(name: name)
            case let .file(url): .file(url)
            }
        let driver = try GRDBSQLiteDriver(location: driverLocation)
        defer { try? driver.close() }
        return try driver.read { try LightweightMigration.storedSchemaMatches(schema, connection: $0) }
    }

    package static let factory: RuntimeStoreFactory = { location, schema in
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
        do {
            let (entityIDs, minimumNextIdentifier) = try driver.read { connection in
                (
                    try LightweightMigration.storedEntityIDs(schema: schema, connection: connection),
                    try LightweightMigration.storedNextEntityIdentifier(connection: connection)
                )
            }
            let runtimeSchema = try schema.reconciled(
                with: entityIDs ?? [:], minimumNextIdentifier: minimumNextIdentifier)
            let storeIdentifier = try driver.write { try LightweightMigration.storeIdentifier(connection: $0) }
            return SQLiteRuntimeStore(
                driver: driver, externalDataColumns: externalDataColumns, runtimeSchema: runtimeSchema,
                persistentStoreIdentifier: storeIdentifier)
        } catch {
            try? driver.close()
            throw error
        }
    }
}
