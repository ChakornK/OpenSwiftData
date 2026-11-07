import Foundation
import OpenSwiftData
import Testing

@Model final class StringPredicateParityItem {
    var name: String
    var nick: String?
    init(_ name: String, nick: String?) {
        self.name = name
        self.nick = nick
    }
}

/// `String.isEmpty`, `String.count`, and `Optional.flatMap` over scalar attributes evaluate with Swift
/// semantics. Apple's SwiftData accepts these predicates too, but some of its results contradict Swift
/// (for example, `name.count == 4` doesn't match "beta", and `nick.flatMap { $0.isEmpty }` doesn't match
/// an empty nick), so OpenSwiftData returns what the predicate means rather than copying those results.
@MainActor @Suite struct StringPredicateParityTests {
    private func names(_ predicate: Predicate<StringPredicateParityItem>, save: Bool) throws -> [String] {
        let container = try ModelContainer(
            for: StringPredicateParityItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        for (name, nick) in [("Alpha", "al"), ("beta", nil), ("Gamma", "GA"), ("délta", ""), ("Épsilon", nil)] {
            context.insert(StringPredicateParityItem(name, nick: nick))
        }
        if save { try context.save() }
        return try context.fetch(FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.name)])).map(\.name)
    }

    @Test(arguments: [false, true])
    func `string isEmpty`(save: Bool) throws {
        #expect(try names(#Predicate { $0.name.isEmpty }, save: save) == [])
        #expect(try names(#Predicate { !$0.name.isEmpty }, save: save).count == 5)
    }

    @Test(arguments: [false, true])
    func `string count counts characters`(save: Bool) throws {
        #expect(try names(#Predicate { $0.name.count == 4 }, save: save) == ["beta"])
        // "délta" has five characters even though its UTF-8 form is six bytes.
        #expect(Set(try names(#Predicate { $0.name.count == 5 }, save: save)) == ["Alpha", "Gamma", "délta"])
        #expect(try names(#Predicate { $0.name.count > 5 }, save: save) == ["Épsilon"])
    }

    @Test(arguments: [false, true])
    func `optional flatMap over a string`(save: Bool) throws {
        #expect(try names(#Predicate { $0.nick.flatMap { $0.isEmpty } ?? false }, save: save) == ["délta"])
        #expect(try names(#Predicate { $0.nick.flatMap { $0.count > 1 } ?? false }, save: save) == ["Alpha", "Gamma"])
        #expect(
            Set(try names(#Predicate { $0.nick.flatMap { $0.count > 1 } ?? true }, save: save))
                == ["Alpha", "Gamma", "beta", "Épsilon"])
        #expect(try names(#Predicate { $0.nick?.isEmpty == true }, save: save) == ["délta"])
    }
}
