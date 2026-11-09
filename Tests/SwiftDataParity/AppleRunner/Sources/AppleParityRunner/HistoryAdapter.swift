import Foundation
import ParityContracts
import SwiftData

@available(macOS 15, *)
@Model
final class HistoryParityModel {
    var name: String
    var count: Int
    @Attribute(.preserveValueOnDeletion) var code: String

    init(name: String, count: Int, code: String) {
        self.name = name
        self.count = count
        self.code = code
    }
}

@MainActor
@available(macOS 15, *)
enum AppleHistoryParityAdapter {
    private typealias Transactions = HistoryDescriptor<DefaultHistoryTransaction>

    static func runAll() throws -> [ScenarioResult] {
        try HistoryParityScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runAndValidate(_ specification: HistoryParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard HistoryParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: HistoryParitySpecification) throws -> ScenarioResult {
        let container = try ModelContainer(
            for: HistoryParityModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let values: [String: ObservedValue]

        switch specification.query {
        case .recordsChangedTransactions:
            values = try recordHistory(in: context).observations
        case .descriptors:
            _ = try recordHistory(in: context)
            let all = try context.fetchHistory(Transactions())
            let secondToken = all[1].token
            let tokenFiltered = try context.fetchHistory(Transactions(predicate: #Predicate { $0.token > secondToken }))
            let authorFiltered = try context.fetchHistory(Transactions(predicate: #Predicate { $0.author == "alice" }))
            var limited = Transactions()
            limited.fetchLimit = 2
            let limitedResults = try context.fetchHistory(limited)
            let reversed = try context.fetchHistory(
                Transactions(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)]))
            values = [
                "tokenFilterCount": .integer(Int64(tokenFiltered.count)),
                "authorFilterCount": .integer(Int64(authorFiltered.count)),
                "limitCount": .integer(Int64(limitedResults.count)),
                "reverseOrderMatches": .bool(reversed.map(\.transactionIdentifier) == all.reversed().map(\.transactionIdentifier)),
                "defaultLimit": .integer(Int64(Transactions().fetchLimit)),
            ]
        case .tokenRoundTrip:
            _ = try recordHistory(in: context)
            let token = try required(context.fetchHistory(Transactions()).first?.token)
            let data = try JSONEncoder().encode(token)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let storeTokens = object["storeTokens"] as? [String: Int64] ?? [:]
            let decoded = try JSONDecoder().decode(DefaultHistoryToken.self, from: data)
            values = [
                "storeTokenCount": .integer(Int64(storeTokens.count)),
                "tokenRoundTripEqual": .bool(decoded == token),
                "tokenValueEntryCount": .integer(Int64(token.tokenValue?.count ?? 0)),
            ]
        case .deletingHistoryExpiresTokens:
            _ = try recordHistory(in: context)
            let all = try context.fetchHistory(Transactions())
            let first = all[0].token
            let second = all[1].token
            try context.deleteHistory(Transactions(predicate: #Predicate { $0.token <= second }))
            let remaining = try context.fetchHistory(Transactions())
            let laterTokenExpired = catchesExpiredHistoryToken {
                try context.fetchHistory(Transactions(predicate: #Predicate { $0.token > second }))
            }
            let deletedTokenExpired = catchesExpiredHistoryToken {
                try context.fetchHistory(Transactions(predicate: #Predicate { $0.token > first }))
            }
            try context.deleteHistory(Transactions())
            values = [
                "remainingAfterPrefixDelete": .integer(Int64(remaining.count)),
                "laterTokenExpired": .bool(laterTokenExpired), "deletedTokenExpired": .bool(deletedTokenExpired),
                "emptyAfterDeleteAll": .bool(try context.fetchHistory(Transactions()).isEmpty),
            ]
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map {
                ParityObservation(step: 0, field: $0, value: values[$0]!)
            })
    }

    private static func recordHistory(in context: ModelContext) throws -> (
        a: HistoryParityModel, b: HistoryParityModel, observations: [String: ObservedValue]
    ) {
        let initialCount = try context.fetchHistory(Transactions()).count
        context.author = "alice"
        let a = HistoryParityModel(name: "a", count: 1, code: "A")
        let b = HistoryParityModel(name: "b", count: 2, code: "B")
        context.insert(a)
        context.insert(b)
        try context.save()
        a.count = 5
        a.name = "a2"
        try context.save()
        a.count = 5
        try context.save()
        context.author = nil
        context.delete(b)
        try context.save()
        try context.transaction { context.insert(HistoryParityModel(name: "c", count: 3, code: "C")) }

        let history = try context.fetchHistory(Transactions())
        let update: DefaultHistoryUpdate<HistoryParityModel>? = history.dropFirst().first?.changes.first.flatMap {
            if case .update(let value) = $0 { return value as? DefaultHistoryUpdate<HistoryParityModel> }
            return nil
        }
        let deletion: DefaultHistoryDelete<HistoryParityModel>? = history.dropFirst(2).first?.changes.first.flatMap {
            if case .delete(let value) = $0 { return value as? DefaultHistoryDelete<HistoryParityModel> }
            return nil
        }
        let firstChanges = history.first?.changes ?? []
        let authors = history.map { $0.author.map(ObservedValue.string) ?? .null }
        let values: [String: ObservedValue] = [
            "initialCount": .integer(Int64(initialCount)), "transactionCount": .integer(Int64(history.count)),
            "authors": .array(authors),
            "idsMatchTransactions": .bool(history.allSatisfy { $0.id == $0.transactionIdentifier }),
            "transactionIDsIncrease": .bool(zip(history, history.dropFirst()).allSatisfy { $0.transactionIdentifier < $1.transactionIdentifier }),
            "tokensIncrease": .bool(zip(history, history.dropFirst()).allSatisfy { $0.token < $1.token }),
            "tokenValuesPresent": .bool(history.allSatisfy { $0.token.tokenValue?.count == 1 }),
            "bundleIdentifierPresent": .bool(!(history.first?.bundleIdentifier.isEmpty ?? true)),
            "processIdentifierPresent": .bool(!(history.first?.processIdentifier.isEmpty ?? true)),
            "firstTransactionChangeCount": .integer(Int64(firstChanges.count)),
            "firstChangeIsInsert": .bool(firstChanges.first.map { if case .insert = $0 { true } else { false } } ?? false),
            "secondChangeIsUpdate": .bool(update != nil),
            "updatedAttributes": .stringSet(update.map { update in
                update.updatedAttributes.compactMap { attribute in
                    let keyPath = attribute as AnyKeyPath
                    if keyPath == \\HistoryParityModel.count { return "count" }
                    if keyPath == \\HistoryParityModel.name { return "name" }
                    return nil
                }
            } ?? []),
            "thirdChangeIsDelete": .bool(deletion != nil),
            "deletedCode": .string(deletion?.tombstone[\\HistoryParityModel.code] as? String ?? ""),
            "deletedNameAbsent": .bool(deletion?.tombstone[\\HistoryParityModel.name] == nil),
            "tombstoneCount": .integer(Int64(deletion.map { Array($0.tombstone).count } ?? 0)),
        ]
        return (a, b, values)
    }

    private static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw HistoryParityAdapterError.missingValue }
        return value
    }

    private static func catchesExpiredHistoryToken(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return false
        } catch SwiftDataError.historyTokenExpired {
            return true
        } catch {
            return false
        }
    }
}

private enum HistoryParityAdapterError: Error {
    case missingValue
}
