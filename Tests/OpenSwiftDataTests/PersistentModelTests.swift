import Foundation
import Observation
import XCTest
import OpenSwiftData
import OSDTestSupport

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

@Model
class InheritanceMacroBaseFixture {
    var name: String
    init(name: String) { self.name = name }

}

@Model
class InheritanceMacroChildFixture: InheritanceMacroBaseFixture {
    var age: Int
    init(name: String, age: Int) {
        self.age = age
        super.init(name: name)
    }
}

@Model
final class InheritanceMacroGrandchildFixture: InheritanceMacroChildFixture {
    var rank: Int
    init(name: String, age: Int, rank: Int) {
        self.rank = rank
        super.init(name: name, age: age)
    }
}

@Model
class InheritanceRelationshipBaseFixture {
    @Relationship(inverse: nil) var items: [InheritanceRelationshipItemFixture]
    init(items: [InheritanceRelationshipItemFixture]) { self.items = items }
}

@Model
final class InheritanceRelationshipChildFixture: InheritanceRelationshipBaseFixture {
    var age: Int
    init(items: [InheritanceRelationshipItemFixture], age: Int) {
        self.age = age
        super.init(items: items)
    }
}

@Model
final class InheritanceRelationshipItemFixture {
    var title: String
    init(title: String) { self.title = title }
}

@Model
class InheritanceLookupBaseFixture {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class InheritanceLookupChildFixture: InheritanceLookupBaseFixture {
    var requiredValue: String
    init(name: String, requiredValue: String) {
        self.requiredValue = requiredValue
        super.init(name: name)
    }
}

/// A model subclass that exercises inheritance across target boundaries.
@Model
public final class CrossModuleInheritanceChildFixture: CrossModuleInheritanceBase {
    /// A persisted value declared by the external subclass.
    public var age: Int

    /// Creates a child model using inherited and locally declared values.
    public init(name: String, age: Int) {
        self.age = age
        super.init(name: name)
    }
}

/// An open model subclass that remains available for further inheritance.
@Model
open class CrossModuleOpenInheritanceChildFixture: CrossModuleInheritanceBase {
    /// A persisted value declared by the open child.
    public var age: Int

    /// Creates an open child model.
    public init(name: String, age: Int) {
        self.age = age
        super.init(name: name)
    }
}

@Model
final class CrossModuleOpenInheritanceGrandchildFixture: CrossModuleOpenInheritanceChildFixture {
    var rank: Int

    init(name: String, age: Int, rank: Int) {
        self.rank = rank
        super.init(name: name, age: age)
    }
}

class InheritanceBaseFixture: PersistentModel {
    typealias Model = InheritanceBaseFixture

    var persistentBackingData: any BackingData<InheritanceBaseFixture>
    var baseValue: String {
        get { getValue(forKey: \.baseValue) }
        set { setValue(forKey: \.baseValue, to: newValue) }
    }

    required init(backingData: any BackingData<InheritanceBaseFixture>) {
        persistentBackingData = backingData
    }

    class func schemaMetadata() -> [Schema.PropertyMetadata] { [] }
}

final class InheritanceChildFixture: InheritanceBaseFixture {
    var childValue: Int {
        get {
            getInheritedValue(
                at: 1, keyPath: \InheritanceChildFixture.childValue, property: "childValue", as: Int.self)
        }
        set { setInheritedValue(at: 1, keyPath: \InheritanceChildFixture.childValue, to: newValue) }
    }

    required init(backingData: any BackingData<InheritanceBaseFixture>) {
        super.init(backingData: backingData)
    }
}

final class PersistentModelTests: XCTestCase {
    func testNonfinalModelBaseStoresOwnProperties() {
        let base = InheritanceMacroBaseFixture(name: "base only")
        XCTAssertEqual(base.name, "base only")
        XCTAssertTrue(base.persistentBackingData is DetachedBackingData<InheritanceMacroBaseFixture>)
    }

    func testInheritedModelUsesBaseBackingForSubclassKeyPaths() {
        let backing = DetachedBackingData<InheritanceBaseFixture>(metadata: [])
        let child = InheritanceChildFixture(backingData: backing)
        child.childValue = 42
        XCTAssertEqual(child.childValue, 42)
        XCTAssertTrue(child.anyBackingData.supportsSubclassKeyPaths)
        XCTAssertTrue(child.persistentBackingData === backing)
    }

    func testModelMacroSubclassUsesInheritedBackingForOwnAndBaseProperties() {
        let child = InheritanceMacroChildFixture(name: "base", age: 8)
        XCTAssertEqual(child.age, 8)
        child.name = "updated base"
        child.age = 9
        XCTAssertEqual(child.name, "updated base")
        XCTAssertEqual(child.age, 9)
        XCTAssertTrue(child.anyBackingData.supportsSubclassKeyPaths)
    }

    func testNestedModelSubclassInitializersAndPropertyStorage() {
        let grandchild = InheritanceMacroGrandchildFixture(name: "nested", age: 12, rank: 3)
        XCTAssertEqual(grandchild.name, "nested")
        XCTAssertEqual(grandchild.age, 12)
        XCTAssertEqual(grandchild.rank, 3)
        grandchild.name = "updated"
        grandchild.age = 13
        grandchild.rank = 4
        XCTAssertEqual(grandchild.name, "updated")
        XCTAssertEqual(grandchild.age, 13)
        XCTAssertEqual(grandchild.rank, 4)
    }

    func testSubclassKeyPathResolverRecognizesInheritedPropertyRoots() {
        XCTAssertEqual(
            InheritanceMacroChildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroChildFixture.name]?.name,
            "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroGrandchildFixture.name]?
                .name,
            "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroGrandchildFixture.age]?
                .name,
            "age")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyDescriptorsByKeyPath()[\InheritanceMacroGrandchildFixture.rank]?
                .name,
            "rank")
        XCTAssertEqual(
            InheritanceMacroChildFixture.propertyName(forKeyPath: \InheritanceMacroChildFixture.name), "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyName(forKeyPath: \InheritanceMacroGrandchildFixture.name),
            "name")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyName(forKeyPath: \InheritanceMacroGrandchildFixture.age),
            "age")
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertyName(forKeyPath: \InheritanceMacroGrandchildFixture.rank),
            "rank")
        XCTAssertEqual(InheritanceMacroBaseFixture.propertySlot(forKeyPath: \InheritanceMacroBaseFixture.name), 0)
        XCTAssertEqual(InheritanceMacroChildFixture.propertySlot(forKeyPath: \InheritanceMacroChildFixture.name), 0)
        XCTAssertEqual(InheritanceMacroChildFixture.propertySlot(forKeyPath: \InheritanceMacroChildFixture.age), 1)
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertySlot(forKeyPath: \InheritanceMacroGrandchildFixture.name), 0)
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertySlot(forKeyPath: \InheritanceMacroGrandchildFixture.age), 1)
        XCTAssertEqual(
            InheritanceMacroGrandchildFixture.propertySlot(forKeyPath: \InheritanceMacroGrandchildFixture.rank), 2)
    }

    func testCrossModuleModelSubclassUsesExportedResolverAndBacking() {
        let child = CrossModuleInheritanceChildFixture(name: "external", age: 5)
        XCTAssertEqual(child.name, "external")
        XCTAssertEqual(child.age, 5)
        XCTAssertEqual(
            CrossModuleInheritanceChildFixture.propertyName(forKeyPath: \CrossModuleInheritanceChildFixture.name),
            "name")
        child.name = "updated"
        XCTAssertEqual(child.name, "updated")

        let observation = ObservationFlag()
        withObservationTracking {
            _ = child.age
        } onChange: {
            observation.set()
        }
        child.age = 6
        XCTAssertTrue(observation.value)
    }

    func testOpenCrossModuleSubclassSupportsFurtherInheritance() {
        let grandchild = CrossModuleOpenInheritanceGrandchildFixture(name: "open", age: 8, rank: 3)

        XCTAssertEqual(grandchild.name, "open")
        XCTAssertEqual(grandchild.age, 8)
        XCTAssertEqual(grandchild.rank, 3)
        XCTAssertEqual(
            CrossModuleOpenInheritanceGrandchildFixture.propertyName(
                forKeyPath: \CrossModuleOpenInheritanceGrandchildFixture.name),
            "name")
    }

    @MainActor
    func testSubclassInitializerRelationshipSurvivesInsertionPreparation() throws {
        let container = try ModelContainer(
            for: InheritanceRelationshipBaseFixture.self,
            InheritanceRelationshipChildFixture.self,
            InheritanceRelationshipItemFixture.self)
        let context = container.mainContext
        let item = InheritanceRelationshipItemFixture(title: "item")
        let child = InheritanceRelationshipChildFixture(items: [item], age: 4)

        context.insert(child)

        XCTAssertEqual(child.items.map(\.title), ["item"])
        child.items = []
        XCTAssertTrue(child.items.isEmpty)
    }

    @MainActor
    func testInheritedRelationshipStorageMappingRetainsLogicalOwner() throws {
        let container = try ModelContainer(
            for: InheritanceRelationshipBaseFixture.self,
            InheritanceRelationshipChildFixture.self,
            InheritanceRelationshipItemFixture.self)

        let mapping = try XCTUnwrap(
            container.schema.relationshipStorageMapping(
                modelEntityName: "InheritanceRelationshipChildFixture", relationshipName: "items"))
        XCTAssertEqual(mapping.modelEntityName, "InheritanceRelationshipChildFixture")
        XCTAssertEqual(mapping.declaringEntityName, "InheritanceRelationshipBaseFixture")
        XCTAssertEqual(mapping.ownerRootEntityName, "InheritanceRelationshipBaseFixture")
        XCTAssertEqual(mapping.destinationEntityName, "InheritanceRelationshipItemFixture")
        XCTAssertEqual(mapping.destinationRootEntityName, "InheritanceRelationshipItemFixture")
    }

    func testRelationshipInverseDestinationAcceptsLogicalOwnerAncestors() {
        let types: [any PersistentModel.Type] = [
            InheritanceMacroBaseFixture.self,
            InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
        ]
        XCTAssertTrue(
            ModelContainer.relationshipDestination(
                "InheritanceMacroBaseFixture", matchesLogicalOwner: "InheritanceMacroChildFixture", among: types))
        XCTAssertTrue(
            ModelContainer.relationshipDestination(
                "InheritanceMacroChildFixture", matchesLogicalOwner: "InheritanceMacroChildFixture", among: types))
        XCTAssertFalse(
            ModelContainer.relationshipDestination(
                "InheritanceMacroGrandchildFixture", matchesLogicalOwner: "InheritanceMacroBaseFixture", among: types))
    }

    @MainActor
    func testContainerAutomaticallyIncludesModelAncestors() throws {
        let implicit = try ModelContainer(
            for: [InheritanceRelationshipChildFixture.self, InheritanceRelationshipItemFixture.self])
        let explicit = try ModelContainer(
            for: [
                InheritanceRelationshipBaseFixture.self,
                InheritanceRelationshipChildFixture.self,
                InheritanceRelationshipItemFixture.self,
            ])
        let reversed = try ModelContainer(
            for: [
                InheritanceRelationshipItemFixture.self,
                InheritanceRelationshipChildFixture.self,
                InheritanceRelationshipBaseFixture.self,
            ])

        XCTAssertEqual(implicit.schema.entities, explicit.schema.entities)
        XCTAssertEqual(reversed.schema.entityIDsByName, explicit.schema.entityIDsByName)
        XCTAssertNotNil(implicit.schema.entity(forName: "InheritanceRelationshipBaseFixture"))
        XCTAssertEqual(
            implicit.schema.relationshipStorageMapping(
                modelEntityName: "InheritanceRelationshipChildFixture", relationshipName: "items")?
                .declaringEntityName,
            "InheritanceRelationshipBaseFixture")
    }

    @MainActor
    func testSQLiteContainerAutomaticallyIncludesModelAncestors() throws {
        let implicit = try ModelContainer(
            for: [InheritanceMacroChildFixture.self],
            configurations: [.sqliteMemory("inheritance-implicit-ancestor")])
        let explicit = try ModelContainer(
            for: [InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self],
            configurations: [.sqliteMemory("inheritance-explicit-ancestor")])

        XCTAssertEqual(implicit.schema.entities, explicit.schema.entities)
        let tables = try XCTUnwrap(implicit.store).read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z%'", arguments: [])
        }
        XCTAssertEqual(tables, [[.text("Z_PRIMARYKEY")], [.text("ZINHERITANCEMACROBASEFIXTURE")]])
    }

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set() {
            lock.lock()
            storage = true
            lock.unlock()
        }
    }

    @MainActor
    func testModelContainerInfersInheritanceMetadata() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self)
        let base = try XCTUnwrap(container.schema.entity(forName: "InheritanceMacroBaseFixture"))
        let child = try XCTUnwrap(container.schema.entity(forName: "InheritanceMacroChildFixture"))
        let grandchild = try XCTUnwrap(container.schema.entity(forName: "InheritanceMacroGrandchildFixture"))
        XCTAssertNil(base.superentityName)
        XCTAssertEqual(child.superentityName, "InheritanceMacroBaseFixture")
        XCTAssertEqual(grandchild.superentityName, "InheritanceMacroChildFixture")
        XCTAssertEqual(child.attributes.map(\.name), ["name", "age"])
        XCTAssertEqual(grandchild.attributes.map(\.name), ["name", "age", "rank"])
    }

    @MainActor
    func testInheritedSQLiteSchemaBootstrapsOneRootTableAndParentIDs() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-schema-bootstrap"))
        let store = try XCTUnwrap(container.store)
        let tables = try store.read {
            try $0.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z%'", arguments: [])
        }
        XCTAssertEqual(tables, [[.text("Z_PRIMARYKEY")], [.text("ZINHERITANCEMACROBASEFIXTURE")]])
        let entities = try store.read {
            try $0.rows("SELECT Z_ENT, Z_NAME, Z_SUPER, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT", arguments: [])
        }
        XCTAssertEqual(
            entities,
            [
                [.int(1), .text("InheritanceMacroBaseFixture"), .int(0), .int(0)],
                [.int(2), .text("InheritanceMacroChildFixture"), .int(1), .int(0)],
                [.int(3), .text("InheritanceMacroGrandchildFixture"), .int(2), .int(0)],
            ])
    }

    @MainActor
    func testInheritedChildInsertUsesRootTableAndConcreteDiscriminator() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-child-insert"))
        let context = container.mainContext
        context.insert(InheritanceMacroChildFixture(name: "child", age: 7))
        try context.save()
        let rows = try container.store?.read {
            try $0.rows(
                "SELECT Z_PK, Z_ENT, ZNAME, ZAGE, ZRANK FROM ZINHERITANCEMACROBASEFIXTURE", arguments: [])
        }
        XCTAssertEqual(rows, [[.int(1), .int(2), .text("child"), .int(7), .null]])
    }

    @MainActor
    func testInheritanceFetchCountIdentifiersAndConcreteMaterialization() throws {
        let container = try ModelContainer(
            for: InheritanceMacroBaseFixture.self, InheritanceMacroChildFixture.self,
            InheritanceMacroGrandchildFixture.self,
            configurations: .sqliteMemory("inheritance-polymorphic-fetch"))
        let writer = container.mainContext
        writer.insert(InheritanceMacroBaseFixture(name: "base"))
        writer.insert(InheritanceMacroChildFixture(name: "child", age: 2))
        writer.insert(InheritanceMacroGrandchildFixture(name: "grandchild", age: 3, rank: 4))
        do {
            try writer.save()
        } catch {
            XCTFail("Saving hierarchy rows failed: \(error)")
            return
        }

        let reader = container.makeContext()
        let baseModels: [InheritanceMacroBaseFixture]
        do {
            baseModels = try reader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
        } catch {
            XCTFail("Fetching the hierarchy root failed: \(error)")
            return
        }
        XCTAssertEqual(baseModels.map(\.name), ["base", "child", "grandchild"])
        XCTAssertTrue(baseModels[1] is InheritanceMacroChildFixture)
        XCTAssertTrue(baseModels[2] is InheritanceMacroGrandchildFixture)
        XCTAssertEqual((baseModels[2] as? InheritanceMacroGrandchildFixture)?.rank, 4)
        let baseCount: Int
        do { baseCount = try reader.fetchCount(FetchDescriptor<InheritanceMacroBaseFixture>()) } catch {
            XCTFail("Counting base hierarchy failed: \(error)"); return
        }
        XCTAssertEqual(baseCount, 3)
        let baseIdentifiers: [PersistentIdentifier]
        do { baseIdentifiers = try reader.fetchIdentifiers(FetchDescriptor<InheritanceMacroBaseFixture>()) } catch {
            XCTFail("Fetching base identifiers failed: \(error)"); return
        }
        XCTAssertEqual(baseIdentifiers.count, 3)
        XCTAssertEqual(baseIdentifiers[1].entityName, "InheritanceMacroChildFixture")
        XCTAssertEqual(baseIdentifiers[2].entityName, "InheritanceMacroGrandchildFixture")

        XCTAssertTrue(try XCTUnwrap(baseModels.first(where: { $0.name == "child" })) is InheritanceMacroChildFixture)
        let childFirstReader = container.makeContext()
        let childFirst = try XCTUnwrap(
            childFirstReader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()).first)
        let childAfterRootFirst = try XCTUnwrap(
            childFirstReader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>())
                .first(where: { $0.name == "child" }))
        XCTAssertTrue(childFirst === childAfterRootFirst)

        let identifierReader = container.makeContext()
        let childIdentifier = try XCTUnwrap(
            baseIdentifiers.first(where: { $0.entityName == "InheritanceMacroChildFixture" }))
        let resolvedAsBase: InheritanceMacroBaseFixture?
        do { resolvedAsBase = try identifierReader.model(for: childIdentifier) } catch {
            XCTFail("Resolving inherited identifier as its base failed: \(error)")
            return
        }
        XCTAssertTrue(resolvedAsBase is InheritanceMacroChildFixture)
        XCTAssertTrue(
            identifierReader.registeredModel(for: childIdentifier) as InheritanceMacroChildFixture? != nil)
        let resolvedAsChild: InheritanceMacroChildFixture?
        do { resolvedAsChild = try identifierReader.model(for: childIdentifier) } catch {
            XCTFail("Resolving inherited identifier as its concrete type failed: \(error)")
            return
        }
        XCTAssertTrue(resolvedAsBase === resolvedAsChild)
        func resolveGrandchild(_ identifier: PersistentIdentifier) throws -> InheritanceMacroGrandchildFixture? {
            try identifierReader.model(for: identifier)
        }
        XCTAssertThrowsError(try resolveGrandchild(childIdentifier))
        let grandchildIdentifier = try XCTUnwrap(
            baseIdentifiers.first(where: { $0.entityName == "InheritanceMacroGrandchildFixture" }))
        let resolvedGrandchildAsChild: InheritanceMacroChildFixture? = try identifierReader.model(
            for: grandchildIdentifier)
        XCTAssertTrue(resolvedGrandchildAsChild is InheritanceMacroGrandchildFixture)
        let mismatchedIdentifier = PersistentIdentifier(
            storeIdentifier: childIdentifier.storeIdentifier,
            entityName: "InheritanceMacroChildFixture",
            primaryKey: try XCTUnwrap(grandchildIdentifier.primaryKey))
        let mismatchedModel: InheritanceMacroChildFixture? = try identifierReader.model(for: mismatchedIdentifier)
        XCTAssertNil(mismatchedModel)

        let childPredicate = #Predicate<InheritanceMacroChildFixture> {
            $0.name == "child" || $0.age == 3
        }
        let childModels: [InheritanceMacroChildFixture]
        do {
            childModels = try reader.fetch(FetchDescriptor(predicate: childPredicate))
        } catch { XCTFail("Fetching child predicate failed: \(error)"); return }
        XCTAssertEqual(childModels.map(\.age), [2, 3])
        XCTAssertTrue(childModels[1] is InheritanceMacroGrandchildFixture)
        let childCount: Int
        do { childCount = try reader.fetchCount(FetchDescriptor<InheritanceMacroChildFixture>()) } catch {
            XCTFail("Counting child hierarchy failed: \(error)"); return
        }
        XCTAssertEqual(childCount, 2)

        let sortedChildren = try reader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                sortBy: [SortDescriptor(\InheritanceMacroChildFixture.name)]))
        XCTAssertEqual(sortedChildren.map(\.name), ["child", "grandchild"])
        let projectedChildren = try reader.fetch(
            FetchDescriptor<InheritanceMacroChildFixture>(
                propertiesToFetch: [\InheritanceMacroChildFixture.name]))
        XCTAssertEqual(projectedChildren.map(\.name), ["child", "grandchild"])

        let grandchildPredicate = #Predicate<InheritanceMacroGrandchildFixture> {
            $0.name == "grandchild" || $0.rank == 4
        }
        let grandchildModels = try reader.fetch(FetchDescriptor(predicate: grandchildPredicate))
        XCTAssertEqual(grandchildModels.map(\.name), ["grandchild"])

        let reverseReader = container.makeContext()
        let reverseChildren: [InheritanceMacroChildFixture]
        do { reverseChildren = try reverseReader.fetch(FetchDescriptor<InheritanceMacroChildFixture>()) } catch {
            XCTFail("Reverse child fetch failed: \(error)"); return
        }
        let reverseRoots: [InheritanceMacroBaseFixture]
        do { reverseRoots = try reverseReader.fetch(FetchDescriptor<InheritanceMacroBaseFixture>()) } catch {
            XCTFail("Reverse root fetch failed: \(error)"); return
        }
        XCTAssertTrue(reverseRoots[1] === reverseChildren[0])
    }

    @MainActor
    func testHierarchyIdentifierLookupReusesExistingMaterializedModel() throws {
        let container = try ModelContainer(
            for: InheritanceLookupBaseFixture.self, InheritanceLookupChildFixture.self,
            configurations: .sqliteMemory("inheritance-identifier-existing"))
        let writer = container.mainContext
        writer.insert(InheritanceLookupChildFixture(name: "child", requiredValue: "required"))
        try writer.save()

        let reader = container.makeContext()
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceLookupBaseFixture>()).first)
        let identifier = fetched.persistentModelID
        let resolved: InheritanceLookupBaseFixture? = try reader.model(for: identifier)

        XCTAssertTrue(fetched === resolved)
        XCTAssertEqual((resolved as? InheritanceLookupChildFixture)?.requiredValue, "required")
    }

    @MainActor
    func testHierarchyExternalRefreshKeepsRootIdentityMapEntry() throws {
        let container = try ModelContainer(
            for: InheritanceLookupBaseFixture.self, InheritanceLookupChildFixture.self,
            configurations: .sqliteMemory("inheritance-external-refresh"))
        let writer = container.mainContext
        writer.insert(InheritanceLookupChildFixture(name: "before", requiredValue: "required"))
        try writer.save()

        let reader = container.makeContext()
        let registered = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceLookupBaseFixture>()).first)
        try reader.pollForExternalChanges()

        let writerChild = try XCTUnwrap(writer.fetch(FetchDescriptor<InheritanceLookupChildFixture>()).first)
        writerChild.name = "after"
        try writer.save()
        try reader.pollForExternalChanges()

        let fetchedAgain = try XCTUnwrap(reader.fetch(FetchDescriptor<InheritanceLookupBaseFixture>()).first)
        XCTAssertTrue(registered === fetchedAgain)
        XCTAssertEqual(registered.name, "after")
    }

    @MainActor
    func testHierarchyPendingIdentifierFetchMatchesModelFetch() throws {
        let container = try ModelContainer(
            for: InheritanceLookupBaseFixture.self, InheritanceLookupChildFixture.self,
            configurations: .sqliteMemory("inheritance-pending-identifiers"))
        let writer = container.mainContext
        writer.insert(InheritanceLookupBaseFixture(name: "saved"))
        try writer.save()

        let reader = container.makeContext()
        reader.insert(InheritanceLookupChildFixture(name: "pending", requiredValue: "required"))
        let descriptor = FetchDescriptor<InheritanceLookupBaseFixture>(fetchLimit: 1)

        let modelIdentifiers = try reader.fetch(descriptor).map(\.persistentModelID)
        let identifiers = try reader.fetchIdentifiers(descriptor)

        XCTAssertEqual(identifiers, modelIdentifiers)
    }

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

    @MainActor
    func testGeneratedScalarSetterTracksManagedMutation() throws {
        let model = MacroBackedFixture(title: "before")
        let container = try ModelContainer(
            for: MacroBackedFixture.self, configurations: .sqliteMemory("scalar-setter"))
        container.mainContext.insert(model)
        try container.mainContext.save()

        model.title = "after"

        XCTAssertEqual(model.title, "after")
        XCTAssertTrue(container.mainContext.changedModelsArray.contains { $0 === model })
    }
}
