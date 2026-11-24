import Foundation

/// Typed errors thrown when a document cannot be converted completely.
public enum AnyTypError: Error, LocalizedError, Sendable, Equatable {
    /// Format is unrecognized or unsupported.
    case unsupported(String)

    /// One or more PDF pages are scanned/image-only and require OCR.
    /// `pages` contains 1-indexed page numbers.
    case needsOCR(pages: [Int], pageCount: Int, message: String)

    /// Document container or stream is structurally unusable.
    case malformed(part: String?, message: String)

    /// Document is encrypted or password-protected.
    case encrypted(message: String)

    /// Fixed safety/resource limit was exceeded (`max_entry_bytes`, `max_expansion`, etc.).
    case resourceLimit(limit: String, message: String)

    /// A required archive part or stream is missing.
    case missingPart(part: String, message: String)

    /// Input or asset output could not be read/written.
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message),
            .needsOCR(_, _, let message),
            .malformed(_, let message),
            .encrypted(let message),
            .resourceLimit(_, let message),
            .missingPart(_, let message),
            .io(let message):
            return message
        }
    }
}
