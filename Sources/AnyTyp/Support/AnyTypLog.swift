import Foundation
import OSLog

/// Internal diagnostic logging, mirroring the Rust `log` facade usage:
/// recoverable quirks are logged, never silent; logging never changes
/// conversion behavior and messages are not a stable API.
enum AnyTypLog {
    private static let logger = Logger(subsystem: "com.anytyp", category: "convert")

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
