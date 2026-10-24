import Foundation
import XCTest
import OpenSwiftData

@Model
final class MacroBackedFixture {
    var title: String
    var count: Int = 3
    var note: String?
    var defaultedNote: String? = "default"
    var explicitlyNil: String? = nil

    init(title: String) {
        self.title = title
    }
}

@Model
final class GroupedBindingFixture {
    var first: Int = 0
    var second: Int = 0

    init() {
        self.first = 0
        self.second = 0
    }
}

@Model
final class UnassignedPropertyFixture {
    var title: String

    init() {}
}

@Model
final class BackingDataDefaultsFixture {
    var count: Int = 5
    var optionalDefault: String? = "default"
    var explicitlyNil: String? = nil

}

final class PersistentModelTests: XCTestCase {
    func testModelMacroProvidesPersistentModelConformance() {
        let model = MacroBackedFixture(title: "conformance")
        func requiresPersistentModel<T: PersistentModel>(_ value: T) {}
        requiresPersistentModel(model)

        XCTAssertEqual(model.title, "conformance")
    }

    func testModelMacroProvidesRuntimeBackedGroupedBindingFixtureProperties() {
        let model = GroupedBindingFixture()

        XCTAssertEqual(model.first, 0)
        XCTAssertEqual(model.second, 0)
        XCTAssertEqual(GroupedBindingFixture.schemaMetadata().map(\.name), ["first", "second"])

        model.first = 11
        model.second = 22
        XCTAssertEqual(model.first, 11)
        XCTAssertEqual(model.second, 22)
    }

    func testModelMacroProvidesUncheckedSendableConformance() {
        let model = MacroBackedFixture(title: "sendable")
        func requiresSendable<T: Sendable>(_ value: T) {}
        requiresSendable(model)
    }

    func testUnassignedNonoptionalPropertyReadTerminatesWithExactMessage() throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["OpenSwiftDataTests.PersistentModelTests/testRunUnassignedPropertyChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["OSD_UNASSIGNED_PROPERTY_CHILD"] = "1"
        process.environment = environment
        process.standardError = standardError

        try process.run()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(
            String(decoding: errorOutput, as: UTF8.self)
                .contains("Fatal error: OSD: property 'title' of UnassignedPropertyFixture was read before assignment")
        )
    }

    func testRunUnassignedPropertyChild() throws {
        guard ProcessInfo.processInfo.environment["OSD_UNASSIGNED_PROPERTY_CHILD"] == "1" else {
            throw XCTSkip("Child-only crash test")
        }
        _ = UnassignedPropertyFixture().title
    }

    func testBackingDataInitializerPreservesDeclaredDefaults() {
        let backingData = BackingDataDefaultsFixture.createBackingData()
        let model = BackingDataDefaultsFixture(backingData: backingData)

        XCTAssertEqual(model.count, 5)
        XCTAssertEqual(model.optionalDefault, "default")
        XCTAssertNil(model.explicitlyNil)
    }

    func testModelMacroProvidesRuntimeBackedAccessors() {
        let model = MacroBackedFixture(title: "initial")

        XCTAssertEqual(model.title, "initial")
        XCTAssertEqual(model.count, 3)
        XCTAssertNil(model.note)
        XCTAssertEqual(model.defaultedNote, "default")
        XCTAssertNil(model.explicitlyNil)

        model.title = "updated"
        XCTAssertEqual(model.title, "updated")

        let replacement = MacroBackedFixture.createBackingData()
        replacement.setValue(forKey: \.title, to: "replacement")
        model.persistentBackingData = replacement

        XCTAssertEqual(model.title, "replacement")
        XCTAssertTrue(model.persistentBackingData === replacement)
    }
}
