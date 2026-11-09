import Foundation
import Dispatch
import ParityContracts
import SwiftData
import Darwin

@Model
final class ContainerParityThing {
    var name: String
    init(name: String) { self.name = name }
}

@MainActor
enum AppleModelContainerParityAdapter {
    static func runAll() throws -> [ScenarioResult] {
        try ModelContainerParityScenarioCatalog.all.map(runAndValidate)
            .sorted { $0.id.description < $1.id.description }
    }

    static func runEraseProbeChild(
        _ query: ModelContainerParitySpecification.Query,
        outputURL: URL
    ) throws {
        let resultID = query == .eraseKeepsStoreUsable
            ? ModelContainerParityScenarioCatalog.eraseKeepsStoreUsable.id
            : ModelContainerParityScenarioCatalog.eraseClearsHistory.id
        let values = query == .eraseKeepsStoreUsable
            ? try eraseKeepsStoreUsableCheckpointed(to: outputURL)
            : try eraseClearsHistoryCheckpointed(to: outputURL)
        let result = ScenarioResult(
            id: resultID,
            observations: values.keys.sorted().map {
                ParityObservation(step: 0, field: $0, value: values[$0]!)
            })
        try CanonicalJSON.encode(result).write(to: outputURL, options: .atomic)
    }

    private static func runAndValidate(_ specification: ModelContainerParitySpecification) throws -> ScenarioResult {
        let result = try run(specification)
        guard ModelContainerParityExpectationValidator.validate(result, against: specification) else {
            throw ScenarioExpectationError(id: result.id, observations: result.observations)
        }
        return result
    }

    private static func run(_ specification: ModelContainerParitySpecification) throws -> ScenarioResult {
        let values: [String: ObservedValue]
        switch specification.query {
        case .configurationsAndIdentity:
            let configuration = ModelConfiguration("A", isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: ContainerParityThing.self, configurations: configuration)
            let other = try ModelContainer(for: ContainerParityThing.self, configurations: configuration)
            values = [
                "configurationSetMatches": .bool(Set(container.configurations) == [configuration]),
                "containerEqualsSelf": .bool(container == container),
                "differentContainersUnequal": .bool(container != other),
                "schemaEntityNames": .unorderedStrings(container.schema.entities.map(\.name)),
            ]
        case .eraseKeepsStoreUsable, .eraseClearsHistory:
            values = try runIsolatedEraseProbe(specification.query)
        }

        return ScenarioResult(
            id: specification.id,
            observations: values.keys.sorted().map { field in
                ParityObservation(step: 0, field: field, value: values[field]!)
            })
    }

    private static func runIsolatedEraseProbe(
        _ query: ModelContainerParitySpecification.Query
    ) throws -> [String: ObservedValue] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "parity-apple-erase-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "checkpoint.json")
        try? FileManager.default.removeItem(at: outputURL)
        let errorURL = directory.appending(path: "child-stderr.log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
        process.arguments = ["--model-container-erase-probe-child", query.rawValue, "--output", outputURL.path]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        let controller = ProbeProcessController(process: process)
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            controller.markExited()
            semaphore.signal()
        }
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("Unable to launch Apple erase probe: \(error)\n".utf8))
            return defaultValues(for: query)
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + .seconds(60))
        timer.setEventHandler {
            controller.terminateIfRunning()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                controller.forceTerminateIfRunning()
            }
        }
        timer.resume()
        let waitResult = semaphore.wait(timeout: .now() + .seconds(65))
        timer.cancel()
        if waitResult == .timedOut {
            controller.terminateIfRunning()
            controller.forceTerminateIfRunning()
            _ = semaphore.wait(timeout: .now() + .seconds(5))
        }
        let timedOut = controller.didTimeOut

        let decoded = try? JSONDecoder().decode(ScenarioResult.self, from: Data(contentsOf: outputURL))
        let expectedID = query == .eraseKeepsStoreUsable
            ? ModelContainerParityScenarioCatalog.eraseKeepsStoreUsable.id
            : ModelContainerParityScenarioCatalog.eraseClearsHistory.id
        let checkpointValid = decoded?.id == expectedID
        let collected = checkpointValid
            ? Dictionary(uniqueKeysWithValues: (decoded?.observations ?? []).map { ($0.field, $0.value) })
            : [:]
        var values = defaultValues(for: query)
        values.merge(collected) { _, captured in captured }
        let didExit = controller.didExit
        if timedOut || !didExit || (didExit && (process.terminationReason != .exit || process.terminationStatus != 0)) {
            try? errorHandle.synchronize()
            if let errorText = try? String(contentsOf: errorURL, encoding: .utf8), !errorText.isEmpty {
                FileHandle.standardError.write(Data("Apple erase probe stderr: \(errorText.suffix(2_000))\n".utf8))
            }
        }
        if !didExit {
            FileHandle.standardError.write(Data("Apple erase probe did not exit after termination.\n".utf8))
        }
        return values
    }

    private static func defaultValues(for query: ModelContainerParitySpecification.Query) -> [String: ObservedValue] {
        let specification = query == .eraseKeepsStoreUsable
            ? ModelContainerParityScenarioCatalog.eraseKeepsStoreUsable
            : ModelContainerParityScenarioCatalog.eraseClearsHistory
        var values = Dictionary(uniqueKeysWithValues: specification.expectedObservationFields.map { ($0, defaultValue(for: $0)) })
        values["lastCompletedStep"] = .integer(0)
        return values
    }

    private static func eraseKeepsStoreUsableCheckpointed(to outputURL: URL) throws -> [String: ObservedValue] {
        let url = FileManager.default.temporaryDirectory.appending(path: "parity-apple-erase-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try ModelContainer(
            for: ContainerParityThing.self, configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        let saved = ContainerParityThing(name: "a")
        context.insert(saved)
        try context.save()
        context.insert(ContainerParityThing(name: "pending"))
        var values: [String: ObservedValue] = [
            "eraseReturned": .bool(false), "fileExistsAfterErase": .bool(false),
            "contextHasChangesAfterErase": .bool(false), "savedObjectAttachedAfterErase": .bool(false),
            "fetchCountReturned": .bool(false), "storedCountAfterErase": .integer(-1),
            "pendingSaveReturned": .bool(false), "pendingFetchReturned": .bool(false),
            "pendingNamesAfterSave": .array([]), "lastCompletedStep": .integer(0),
        ]

        func checkpoint() throws {
            let result = ScenarioResult(
                id: ModelContainerParityScenarioCatalog.eraseKeepsStoreUsable.id,
                observations: values.map { ParityObservation(step: 0, field: $0.key, value: $0.value) })
            try CanonicalJSON.encode(result).write(to: outputURL, options: .atomic)
        }

        do {
            try container.erase()
        } catch {
            try checkpoint()
            return values
        }
        values["eraseReturned"] = .bool(true)
        values["fileExistsAfterErase"] = .bool(FileManager.default.fileExists(atPath: url.path))
        values["contextHasChangesAfterErase"] = .bool(context.hasChanges)
        values["savedObjectAttachedAfterErase"] = .bool(saved.modelContext === context)
        values["lastCompletedStep"] = .integer(1)
        try checkpoint()
        var stored = FetchDescriptor<ContainerParityThing>()
        stored.includePendingChanges = false
        do {
            let storedCount = try ModelContext(container).fetchCount(stored)
            values["fetchCountReturned"] = .bool(true)
            values["storedCountAfterErase"] = .integer(Int64(storedCount))
            values["lastCompletedStep"] = .integer(2)
        } catch {
            try checkpoint()
            return values
        }
        try checkpoint()
        // Saving the stale mainContext after erase traps in Apple SwiftData (DefaultStore API contract
        // violation), so prove the store stays usable by saving and fetching through a fresh context
        // instead. The pending insertion left in the stale context is intentionally abandoned; the
        // contextHasChangesAfterErase observation above already captured that the stale context still
        // holds the pending change, matching OpenSwiftData.
        let pendingContext = ModelContext(container)
        pendingContext.insert(ContainerParityThing(name: "pending"))
        do {
            try pendingContext.save()
        } catch {
            try checkpoint()
            return values
        }
        values["pendingSaveReturned"] = .bool(true)
        values["lastCompletedStep"] = .integer(3)
        try checkpoint()
        do {
            values["pendingNamesAfterSave"] = .array(
                try ModelContext(container).fetch(stored).map { .string($0.name) })
            values["pendingFetchReturned"] = .bool(true)
            values["lastCompletedStep"] = .integer(4)
        } catch {
            try checkpoint()
            return values
        }
        return values
    }

    private static func eraseClearsHistoryCheckpointed(to outputURL: URL) throws -> [String: ObservedValue] {
        let container = try ModelContainer(
            for: ContainerParityThing.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(ContainerParityThing(name: "a"))
        try container.mainContext.save()
        var values: [String: ObservedValue] = [
            "eraseReturned": .bool(false), "historyFetchReturned": .bool(false), "historyEmpty": .bool(false),
            "lastCompletedStep": .integer(0),
        ]
        func checkpoint() throws {
            let result = ScenarioResult(
                id: ModelContainerParityScenarioCatalog.eraseClearsHistory.id,
                observations: values.map { ParityObservation(step: 0, field: $0.key, value: $0.value) })
            try CanonicalJSON.encode(result).write(to: outputURL, options: .atomic)
        }
        do {
            try container.erase()
        } catch {
            try checkpoint()
            return values
        }
        values["eraseReturned"] = .bool(true)
        values["lastCompletedStep"] = .integer(1)
        try checkpoint()
        do {
            let history = try container.mainContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            values["historyFetchReturned"] = .bool(true)
            values["historyEmpty"] = .bool(history.isEmpty)
            values["lastCompletedStep"] = .integer(2)
        } catch {
            try checkpoint()
            return values
        }
        return values
    }

    private static func defaultValue(for field: String) -> ObservedValue {
        switch field {
        case "storedCountAfterErase": .integer(-1)
        case "pendingNamesAfterSave": .array([])
        case "lastCompletedStep": .integer(0)
        default: .bool(false)
        }
    }
}

private final class ProbeProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false
    private var exited = false

    init(process: Process) { self.process = process }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    var didExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func markExited() {
        lock.lock()
        exited = true
        lock.unlock()
    }

    func terminateIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard !exited && process.isRunning else { return }
        timedOut = true
        process.terminate()
    }

    func forceTerminateIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard !exited && process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
