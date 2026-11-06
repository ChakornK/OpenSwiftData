import Logging

/// Provides the logging entry points used by OpenSwiftData.
public enum OSDLog {
    // Built per call so a `LoggingSystem.bootstrap` that runs after first use still takes effect.
    private static var logger: Logger { Logger(label: "com.openswiftdata") }

    /// Writes a debug-level diagnostic message.
    public static func debug(_ message: @autoclosure () -> Logger.Message) {
        logger.debug(message())
    }
}
