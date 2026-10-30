import OpenSwiftData

@Model
open class CrossModuleInheritanceBase {
    /// A persisted value inherited by external model subclasses.
    public var name: String

    /// Creates a base model for cross-module subclass tests.
    public init(name: String) { self.name = name }
}

@Model final class Trip {
    var name: String
    var days: Int = 1
    var notes: String?
    @Relationship(deleteRule: .cascade, inverse: \Stop.trip) var stops: [Stop] = []
    init(name: String) { self.name = name }
}

@Model final class Stop {
    var title: String
    var order: Int
    var trip: Trip?
    init(title: String, order: Int) { self.title = title; self.order = order }
}

@Model final class Person {
    @Attribute(.unique) var email: String
    var age: Int
    init(email: String, age: Int) { self.email = email; self.age = age }
}
