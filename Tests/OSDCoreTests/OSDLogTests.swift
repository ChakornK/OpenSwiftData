import Logging
import XCTest
@testable import OSDCore

final class OSDLogTests: XCTestCase {
    func testDebugEmitsMessageAtDebugLevel() {
        let capture = LogCapture()
        LoggingSystem.bootstrap { label in
            CapturingLogHandler(label: label, capture: capture)
        }

        OSDLog.debug("captured diagnostic")

        let events = capture.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.level, .debug)
        XCTAssertEqual(events.first?.message, "captured diagnostic")
        XCTAssertEqual(events.first?.label, "com.openswiftdata")
    }
}

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [CapturedLogEvent] = []

    var events: [CapturedLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func append(_ event: CapturedLogEvent) {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append(event)
    }
}

private struct CapturedLogEvent {
    let label: String
    let level: Logger.Level
    let message: String
}

private struct CapturingLogHandler: LogHandler {
    let label: String
    let capture: LogCapture
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        capture.append(CapturedLogEvent(label: label, level: event.level, message: event.message.description))
    }
}
