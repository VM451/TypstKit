import Foundation
import TypstSyntax
import TypstUtils

/// A regular expression value. Port of `Regex` in `str.rs`.
///
/// Upstream wraps the Rust `regex` crate; the Swift port wraps
/// `NSRegularExpression` (ICU syntax). Match offsets are exposed as UTF-8
/// byte offsets, matching upstream's `usize` byte semantics.
public struct Regex: @unchecked Sendable {
    /// The pattern source.
    public let pattern: String
    /// The compiled expression.
    public let expression: NSRegularExpression

    public init(_ pattern: String) throws {
        self.pattern = pattern
        self.expression = try NSRegularExpression(pattern: pattern)
    }

    /// Whether the pattern matches anywhere in `string`.
    public func isMatch(_ string: String) -> Bool {
        expression.firstMatch(
            in: string,
            range: NSRange(string.startIndex..<string.endIndex, in: string)
        ) != nil
    }

    /// All matches as UTF-8 byte ranges with optional capture ranges.
    public func matches(in string: String) -> [RegexMatch] {
        let nsString = string as NSString
        let full = NSRange(location: 0, length: nsString.length)
        let mapper = Utf16ByteMapper(string: string)
        return expression.matches(in: string, range: full).map { result in
            RegexMatch(nsResult: result, mapper: mapper)
        }
    }

    /// The first match, if any.
    public func firstMatch(in string: String) -> RegexMatch? {
        matches(in: string).first
    }

    /// Whether the pattern matches the empty string.
    public func matchesEmpty() -> Bool {
        isMatch("")
    }
}

extension Regex: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(pattern)
    }

    public static func == (lhs: Regex, rhs: Regex) -> Bool {
        lhs.pattern == rhs.pattern
    }
}

extension Regex: CustomDebugStringConvertible {
    public var debugDescription: String { "Regex(\(pattern))" }
}

extension Regex: Repr {
    public func repr() -> String {
        "regex(\(Str(pattern).repr()))"
    }
}

/// A single regex match with UTF-8 byte offsets. Port of `regex::Captures`.
public struct RegexMatch {
    /// Byte range of the whole match.
    public let range: Range<Int>
    /// Byte ranges of capture groups (nil for non-participating).
    public let captures: [Range<Int>?]
    /// Texts of capture groups (nil for non-participating).
    public let captureTexts: [String?]
    /// The matched text.
    public let text: String

    init(nsResult: NSTextCheckingResult, mapper: Utf16ByteMapper) {
        range = mapper.byteRange(of: nsResult.range)
        text = mapper.substring(of: nsResult.range) ?? ""
        var caps: [Range<Int>?] = []
        var texts: [String?] = []
        for i in 1..<nsResult.numberOfRanges {
            let r = nsResult.range(at: i)
            if r.location == NSNotFound {
                caps.append(nil)
                texts.append(nil)
            } else {
                caps.append(mapper.byteRange(of: r))
                texts.append(mapper.substring(of: r))
            }
        }
        captures = caps
        captureTexts = texts
    }
}

/// Maps UTF-16 `NSRange`s to UTF-8 byte ranges. Built once per match
/// operation to keep conversions O(n).
struct Utf16ByteMapper {
    let string: String
    /// utf16 offset → utf8 byte offset, valid at Character boundaries.
    /// Built lazily.
    /// Lazily-built UTF-16 → UTF-8 offset table (boxed so `Regex` stays a
    /// `Sendable` value type).
    private final class TableBox: @unchecked Sendable {
        var map: [Int: Int]?
    }
    private let tableBox = TableBox()

    init(string: String) {
        self.string = string
    }

    private func buildTable() -> [Int: Int] {
        var map: [Int: Int] = [:]
        var u16 = 0
        var u8 = 0
        for scalar in string.unicodeScalars {
            map[u16] = u8
            let u16Len = scalar.utf16.count
            u16 += u16Len
            u8 += scalar.utf8.count
        }
        map[u16] = u8
        return map
    }

    func byteOffset(ofUTF16 offset: Int) -> Int {
        if tableBox.map == nil { tableBox.map = buildTable() }
        if let exact = tableBox.map?[offset] { return exact }
        // Find the nearest preceding boundary.
        guard let t = tableBox.map else { return offset }
        var best = 0
        for (k, _) in t where k <= offset && k > best { best = k }
        return t[best] ?? 0
    }

    func byteRange(of range: NSRange) -> Range<Int> {
        let start = byteOffset(ofUTF16: range.location)
        let end = byteOffset(ofUTF16: range.location + range.length)
        return start..<end
    }

    func substring(of range: NSRange) -> String? {
        let u16Start = string.utf16.index(string.utf16.startIndex, offsetBy: range.location)
        let u16End = string.utf16.index(string.utf16.startIndex, offsetBy: range.location + range.length)
        guard let start = String.Index(u16Start, within: string),
              let end = String.Index(u16End, within: string) else { return nil }
        return String(string[start..<end])
    }
}
