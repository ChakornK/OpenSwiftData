import Foundation

package struct ExternalStorageFileOperations: Sendable {
    package var createDirectory: @Sendable (URL) throws -> Void
    package var fileExists: @Sendable (URL) -> Bool
    package var writeAtomically: @Sendable (Data, URL) throws -> Void
    package var moveItem: @Sendable (URL, URL) throws -> Void
    package var removeItem: @Sendable (URL) throws -> Void
    package var contentsOfDirectory: @Sendable (URL) throws -> [URL]

    package static let live = Self(
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        writeAtomically: { try $0.write(to: $1, options: .atomic) },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        contentsOfDirectory: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) })
}

package final class PendingExternalFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var temporaryNames: Set<String> = []
    private var publishedNames: Set<String> = []

    package func addTemporary(_ name: String) {
        lock.lock()
        temporaryNames.insert(name)
        lock.unlock()
    }

    package func addPublished(_ name: String) {
        lock.lock()
        temporaryNames.remove(name)
        publishedNames.insert(name)
        lock.unlock()
    }

    package func removeTemporary(_ name: String) {
        lock.lock()
        temporaryNames.remove(name)
        lock.unlock()
    }

    package func snapshot() -> (temporary: Set<String>, published: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (temporaryNames, publishedNames)
    }

    package func clear() {
        lock.lock()
        temporaryNames.removeAll()
        publishedNames.removeAll()
        lock.unlock()
    }
}

package final class AfterCommitActions: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [() -> Void] = []

    package func append(_ action: @escaping () -> Void) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    package func run() {
        lock.lock()
        let pending = actions
        actions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }
}

package struct ExternalStorage: Sendable {
    package static let threshold = 131_072
    private static let marker = Array("OSD_EXTERNAL_DATA_V1\0".utf8)
    private let directory: URL
    private let operations: ExternalStorageFileOperations

    package init?(databaseURL: URL?, operations: ExternalStorageFileOperations = .live) throws {
        guard let databaseURL else { return nil }
        self.operations = operations
        directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + ".external", isDirectory: true)
        try operations.createDirectory(directory)
    }

    package func externalized(_ bytes: [UInt8], pending: PendingExternalFiles) throws -> [UInt8] {
        guard bytes.count > Self.threshold else { return bytes }
        let name = Self.fileName(for: bytes)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        if operations.fileExists(destination) {
            guard try Data(contentsOf: destination) == Data(bytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            let temporaryName = ".\(UUID().uuidString).tmp"
            let temporary = directory.appendingPathComponent(temporaryName, isDirectory: false)
            pending.addTemporary(temporaryName)
            try operations.writeAtomically(Data(bytes), temporary)
            do {
                try operations.moveItem(temporary, destination)
                pending.addPublished(name)
            } catch {
                pending.removeTemporary(temporaryName)
                try? operations.removeItem(temporary)
                guard operations.fileExists(destination), try Data(contentsOf: destination) == Data(bytes) else {
                    throw error
                }
                pending.addPublished(name)
            }
        }
        return Self.marker + Array(name.utf8)
    }

    package func resolved(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let name = Self.fileName(in: bytes) else { return bytes }
        let data = try Data(contentsOf: directory.appendingPathComponent(name, isDirectory: false))
        guard Self.fileName(for: Array(data)) == name else { throw CocoaError(.fileReadCorruptFile) }
        return Array(data)
    }

    package func removeOrphans(referencedNames: Set<String>) throws {
        guard operations.fileExists(directory) else { return }
        for file in try operations.contentsOfDirectory(directory) {
            let name = file.lastPathComponent
            if name.hasSuffix(".tmp")
                || (name.hasPrefix("data-") && name.hasSuffix(".blob") && !referencedNames.contains(name))
            {
                try operations.removeItem(file)
            }
        }
    }

    package func rollback(_ pending: PendingExternalFiles) {
        let files = pending.snapshot()
        for name in files.temporary.union(files.published) {
            try? operations.removeItem(directory.appendingPathComponent(name, isDirectory: false))
        }
        pending.clear()
    }

    package static func fileName(in bytes: [UInt8]) -> String? {
        guard bytes.starts(with: marker) else { return nil }
        let suffix = bytes.dropFirst(marker.count)
        guard let name = String(bytes: suffix, encoding: .utf8),
            name.hasPrefix("data-"), name.hasSuffix(".blob"),
            name.utf8.allSatisfy({
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46
            })
        else { return nil }
        return name
    }

    private static func fileName(for bytes: [UInt8]) -> String {
        let digest = SHA256.hash(bytes).map { String(format: "%02x", $0) }.joined()
        return "data-\(digest).blob"
    }
}
