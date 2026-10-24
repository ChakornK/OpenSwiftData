import Logging

/// Provides the logging entry points used by OpenSwiftData.
public enum OSDLog {
    private static let logger = Logger(label: "com.openswiftdata")

    /// Writes a debug-level diagnostic message.
    public static func debug(_ message: @autoclosure () -> Logger.Message) {
        logger.debug(message())
    }
}
