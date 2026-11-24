import Foundation

/// Why a conversion could not produce a useful result.
///
/// An error means a complete conversion was impossible: the input was
/// unreadable or structurally unusable, encrypted, or crossed a fixed
/// safety/resource limit. Recoverable producer quirks never surface here -
/// they are recovered or skipped (and logged) while conversion continues.
enum ConvertError: Error {
    /// The format is unknown or cannot be converted at all.
    case unsupported(String)
    /// Some pages of a PDF are scanned or image-only and need OCR.
    /// `pages` contains 1-indexed page numbers.
    case needsOCR(pages: [Int], pageCount: Int)
    /// The document is structurally unusable. `part` names the package part
    /// or stream when known.
    case malformed(part: String?, detail: String)
    /// The document is encrypted or password-protected.
    case encrypted
    /// A fixed safety limit was exceeded. These are hard errors in every
    /// case; see `Limits` for the documented defaults.
    case resourceLimit(limit: String, detail: String)
    /// A part required for any meaningful output is missing.
    case missingPart(part: String)
    /// The input could not be read.
    case io(String)

    /// `2, 5-7, 12` from ascending page numbers.
    static func pageRanges(_ pages: [Int]) -> String {
        var ranges: [String] = []
        var i = 0
        while i < pages.count {
            let start = pages[i]
            var end = start
            var j = i
            while j + 1 < pages.count, pages[j + 1] == end + 1 {
                j += 1
                end = pages[j]
            }
            ranges.append(end > start ? "\(start)-\(end)" : "\(start)")
            i = j + 1
        }
        return ranges.joined(separator: ", ")
    }

    /// True when recovery must not swallow this error: fixed safety limits
    /// hard-fail in every context, including optional parts.
    var isFatal: Bool {
        if case .resourceLimit = self { return true }
        return false
    }

    /// Map onto the public `AnyTypError` type at the API boundary.
    var anyTypError: AnyTypError {
        switch self {
        case .unsupported(let what):
            return .unsupported("unsupported input: \(what)")
        case .needsOCR(let pages, let pageCount):
            let message: String
            if pages.count == 1, let page = pages.first {
                message = "page \(page) of \(pageCount) needs OCR"
            } else if pages.count >= pageCount {
                message = "all \(pageCount) pages need OCR"
            } else {
                message = "pages \(Self.pageRanges(pages)) of \(pageCount) need OCR"
            }
            return .needsOCR(pages: pages, pageCount: pageCount, message: message)
        case .malformed(let part, let detail):
            if let part {
                return .malformed(part: part, message: "malformed document (\(part)): \(detail)")
            }
            return .malformed(part: nil, message: "malformed document: \(detail)")
        case .encrypted:
            return .encrypted(message: "document is encrypted")
        case .resourceLimit(let limit, let detail):
            return .resourceLimit(limit: limit, message: "resource limit exceeded (\(limit)): \(detail)")
        case .missingPart(let part):
            return .missingPart(part: part, message: "missing required part: \(part)")
        case .io(let detail):
            return .io("io error: \(detail)")
        }
    }

    static func malformed(_ detail: String) -> ConvertError {
        .malformed(part: nil, detail: detail)
    }

    static func malformedPart(_ part: String, _ detail: String) -> ConvertError {
        .malformed(part: part, detail: detail)
    }
}
