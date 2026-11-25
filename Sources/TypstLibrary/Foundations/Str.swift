import Foundation
import TypstSyntax
import TypstUtils

/// A sequence of Unicode codepoints. Port of `Str` in `str.rs`.
///
/// Indices are UTF-8 **byte** offsets, matching upstream. Grapheme-cluster
/// operations use Swift `Character` (extended grapheme clusters, UAX #29),
/// matching upstream's `graphemes(true)`.
public struct Str: Sendable, Hashable {
    /// The underlying string.
    public var value: String

    public init(_ value: String) {
        self.value = value
    }

    public init() {
        self.value = ""
    }

    public var isEmpty: Bool { value.isEmpty }

    /// Byte length (upstream `len`).
    public var byteLength: Int { value.utf8.count }

    /// Repeat the string `n` times.
    public func repeated(_ n: Int) -> StrResult<Str> {
        if n > 0, byteLength > Int.max / n {
            return .failure(StrError("cannot repeat this string \(n) times"))
        }
        return .success(Str(String(repeating: value, count: max(n, 0))))
    }

    /// The string slice.
    public var string: String { value }
}

extension Str: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.value = value
    }
}

extension Str: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self.value = stringInterpolation.description
    }
}

extension Str: CustomStringConvertible {
    public var description: String { value }
}

extension Str: Comparable {
    public static func < (lhs: Str, rhs: Str) -> Bool {
        lhs.value < rhs.value
    }
}

extension Str {
    /// Resolve a byte index, wrapping negatives; `index == len` allowed.
    /// Errors when out of bounds or not on a UTF-8 boundary.
    func locate(_ index: Int64, allowEnd: Bool = true) -> StrResult<Int> {
        switch locateOpt(index, allowEnd: allowEnd) {
        case let .success(opt):
            if let opt { return .success(opt) }
            return .failure(StrError(
                "string index out of bounds (index: \(index), len: \(byteLength))"
            ))
        case let .failure(e): return .failure(e)
        }
    }

    /// Resolve a byte index if in bounds and on a char boundary.
    func locateOpt(_ index: Int64, allowEnd: Bool = true) -> StrResult<Int?> {
        let len = Int64(byteLength)
        var i = index
        if i < 0 { i = len + i }
        let limit = allowEnd ? len : len - 1
        guard i >= 0, i <= limit else { return .success(nil) }
        guard let idx = Int(exactly: i) else { return .success(nil) }
        // Char boundary: the byte must not be a UTF-8 continuation byte.
        if idx < byteLength {
            let byte = value.utf8[value.utf8.index(value.utf8.startIndex, offsetBy: idx)]
            if byte & 0xC0 == 0x80 {
                return .failure(StrError("string index \(index) is not a character boundary"))
            }
        }
        return .success(idx)
    }

    /// Byte offset → String.Index.
    func index(atByteOffset offset: Int) -> String.Index {
        let utf8Idx = value.utf8.index(value.utf8.startIndex, offsetBy: offset)
        return String.Index(utf8Idx, within: value) ?? value.endIndex
    }

    /// Substring by byte range.
    func substring(byteStart: Int, byteEnd: Int) -> String {
        let s = index(atByteOffset: byteStart)
        let e = index(atByteOffset: byteEnd)
        return String(value[s..<e])
    }

    /// Grapheme clusters (Characters).
    var graphemes: [Character] { Array(value) }

    /// Unicode scalar values (upstream `chars`).
    var scalars: [Unicode.Scalar] { Array(value.unicodeScalars) }

    /// First grapheme cluster.
    var firstGrapheme: Character? { value.first }

    /// Last grapheme cluster.
    var lastGrapheme: Character? { value.last }
}

// MARK: - Scope methods

extension Str {
    /// `str(..)` constructor semantics are handled by the type's construct.

    /// `len` — byte length.
    public var len: Int { byteLength }

    /// `first(default:)` — first grapheme cluster.
    public func first(default defaultValue: Str? = nil) -> StrResult<Str> {
        if let g = value.first { return .success(Str(String(g))) }
        if let defaultValue { return .success(defaultValue) }
        return .failure(StrError("string is empty"))
    }

    /// `last(default:)` — last grapheme cluster.
    public func last(default defaultValue: Str? = nil) -> StrResult<Str> {
        if let g = value.last { return .success(Str(String(g))) }
        if let defaultValue { return .success(defaultValue) }
        return .failure(StrError("string is empty"))
    }

    /// `at(index, default:)` — grapheme cluster at byte index.
    public func at(_ index: Int64, default defaultValue: Value? = nil) -> StrResult<Value> {
        let len = Int64(byteLength)
        switch locateOpt(index) {
        case let .failure(e): return .failure(e)
        case let .success(opt):
            if let i = opt {
                let idx = self.index(atByteOffset: i)
                if idx < value.endIndex, let g = value[idx...].first {
                    return .success(.str(Str(String(g))))
                }
            }
            if let defaultValue { return .success(defaultValue) }
            return .failure(StrError(
                "no default value was specified and string index out of bounds (index: \(index), len: \(len))"
            ))
        }
    }

    /// `slice(start, end?, count?)` — byte-range substring.
    public func slice(start: Int64, end: Int64? = nil, count: Int64? = nil) -> StrResult<Str> {
        if end != nil && count != nil {
            return .failure(StrError("`end` and `count` are mutually exclusive"))
        }
        let s: Int
        switch locate(start) {
        case let .success(v): s = v
        case let .failure(e): return .failure(e)
        }
        let e0 = end ?? count.map { Int64(s) + $0 }
        let e: Int
        switch locate(e0 ?? Int64(byteLength)) {
        case let .success(v): e = Swift.max(v, s)
        case let .failure(err): return .failure(err)
        }
        return .success(Str(substring(byteStart: s, byteEnd: e)))
    }

    /// `clusters()` — grapheme clusters as array.
    public var clusters: ArrayValue {
        ArrayValue(items: value.map { .str(Str(String($0))) })
    }

    /// `codepoints()` — Unicode scalars as array of single-char strings.
    public var codepoints: ArrayValue {
        ArrayValue(items: value.unicodeScalars.map { scalar in
            .str(Str(String(scalar)))
        })
    }

    /// `to-unicode(character)` — scalar value of a single char.
    public static func toUnicode(_ character: Unicode.Scalar) -> UInt32 {
        character.value
    }

    /// `from-unicode(value)`.
    public static func fromUnicode(_ value: UInt32) -> StrResult<Str> {
        guard let scalar = Unicode.Scalar(value) else {
            return .failure(StrError("\(String(value, radix: 16)) is not a valid codepoint"))
        }
        return .success(Str(String(scalar)))
    }

    /// `normalize(form:)`.
    public func normalize(_ form: UnicodeNormalForm) -> Str {
        switch form {
        case .nfc: return Str(value.precomposedStringWithCanonicalMapping)
        case .nfd: return Str(value.decomposedStringWithCanonicalMapping)
        case .nfkc: return Str(value.precomposedStringWithCompatibilityMapping)
        case .nfkd: return Str(value.decomposedStringWithCompatibilityMapping)
        }
    }

    /// `contains(pattern)`.
    public func contains(_ pattern: StrPattern) -> Bool {
        switch pattern {
        case let .str(pat): return value.contains(pat.value)
        case let .regex(re): return re.isMatch(value)
        }
    }

    /// `starts-with(pattern)`.
    public func startsWith(_ pattern: StrPattern) -> Bool {
        switch pattern {
        case let .str(pat): return value.hasPrefix(pat.value)
        case let .regex(re):
            guard let m = re.firstMatch(in: value) else { return false }
            return m.range.lowerBound == 0
        }
    }

    /// `ends-with(pattern)`.
    public func endsWith(_ pattern: StrPattern) -> Bool {
        switch pattern {
        case let .str(pat): return value.hasSuffix(pat.value)
        case let .regex(re):
            // Find all non-overlapping matches; check if any ends at len.
            // Upstream advances by one codepoint after each match to catch
            // overlapping endings.
            var startByte = 0
            let utf8 = value.utf8
            while startByte <= utf8.count {
                guard let sub = substring(fromByte: startByte) else { break }
                guard let m = re.firstMatch(in: sub) else { break }
                let endByte = startByte + m.range.upperBound
                if endByte == byteLength { return true }
                // Advance past the first codepoint of the match.
                guard m.range.lowerBound < sub.utf8.count else { break }
                let firstScalarEnd = sub.utf8.index(sub.utf8.startIndex, offsetBy: 1)
                // Move to next scalar boundary after match start.
                var idx = sub.utf8.index(sub.utf8.startIndex, offsetBy: m.range.lowerBound)
                idx = sub.utf8.index(after: idx)
                // Skip continuation bytes.
                while idx < sub.utf8.endIndex {
                    let b = sub.utf8[idx]
                    if b & 0xC0 != 0x80 { break }
                    idx = sub.utf8.index(after: idx)
                }
                startByte += sub.utf8.distance(from: sub.utf8.startIndex, to: idx)
                _ = firstScalarEnd
            }
            return false
        }
    }

    private func substring(fromByte offset: Int) -> String? {
        guard offset <= byteLength else { return nil }
        let s = index(atByteOffset: offset)
        return String(value[s...])
    }

    /// `find(pattern)` → matched string or none.
    public func find(_ pattern: StrPattern) -> Str? {
        switch pattern {
        case let .str(pat):
            return value.contains(pat.value) ? pat : nil
        case let .regex(re):
            guard let m = re.firstMatch(in: value) else { return nil }
            return Str(m.text)
        }
    }

    /// `position(pattern)` → byte index of first match or none.
    public func position(_ pattern: StrPattern) -> Int? {
        switch pattern {
        case let .str(pat):
            guard let range = value.range(of: pat.value) else { return nil }
            return value[..<range.lowerBound].utf8.count
        case let .regex(re):
            guard let m = re.firstMatch(in: value) else { return nil }
            return m.range.lowerBound
        }
    }

    /// `match(pattern)` → dict with start/end/text/captures or none.
    public func match(_ pattern: StrPattern) -> Dict? {
        switch pattern {
        case let .str(pat):
            guard let range = value.range(of: pat.value) else { return nil }
            let start = value[..<range.lowerBound].utf8.count
            let end = start + pat.byteLength
            var dict = Dict()
            dict.insert("start", .int(Int64(start)))
            dict.insert("end", .int(Int64(end)))
            dict.insert("text", .str(pat))
            dict.insert("captures", .array(ArrayValue()))
            return dict
        case let .regex(re):
            guard let m = re.firstMatch(in: value) else { return nil }
            return capturesToDict(m)
        }
    }

    /// `matches(pattern)` → array of match dicts.
    public func matches(_ pattern: StrPattern) -> ArrayValue {
        switch pattern {
        case let .str(pat):
            var result: [Value] = []
            var searchStart = value.startIndex
            while let range = value.range(of: pat.value, range: searchStart..<value.endIndex) {
                let start = value[..<range.lowerBound].utf8.count
                let end = start + pat.byteLength
                var dict = Dict()
                dict.insert("start", .int(Int64(start)))
                dict.insert("end", .int(Int64(end)))
                dict.insert("text", .str(pat))
                dict.insert("captures", .array(ArrayValue()))
                result.append(.dict(dict))
                searchStart = range.upperBound
                if pat.isEmpty { break }
            }
            return ArrayValue(items: result)
        case let .regex(re):
            return ArrayValue(items: re.matches(in: value).map {
                .dict(capturesToDict($0))
            })
        }
    }

    /// `replace(pattern, replacement, count:)`.
    public func replace(
        _ pattern: StrPattern,
        _ replacement: Replacement,
        count: Int? = nil,
        engine: inout Engine,
        context: Context
    ) -> SourceResult<Str> {
        var output = ""
        output.reserveCapacity(byteLength)

        var lastMatch = 0
        func handleMatch(range: Range<Int>, dict: Dict) -> SourceResult<()> {
            // Push everything until the match.
            output += substring(byteStart: lastMatch, byteEnd: range.lowerBound)
            lastMatch = range.upperBound

            switch replacement {
            case let .str(s):
                output += s.value
            case let .function(f):
                let callArgs = Args(span: .detached, items: [
                    Arg(span: .detached, name: nil,
                        value: Spanned(.dict(dict), span: .detached))
                ])
                let result: SourceResult<Str> = f.call(
                    engine: &engine, context: context,
                    args: callArgs, span: .detached
                )
                switch result {
                case let .success(piece): output += piece.value
                case let .failure(diags): return .failure(diags)
                }
            }
            return .success(())
        }

        let limit = count ?? Int.max
        var handled = 0

        switch pattern {
        case let .str(pat):
            var searchStart = value.startIndex
            while handled < limit,
                  let range = value.range(of: pat.value, range: searchStart..<value.endIndex) {
                let byteStart = value[..<range.lowerBound].utf8.count
                let byteEnd = byteStart + pat.byteLength
                var dict = Dict()
                dict.insert("start", .int(Int64(byteStart)))
                dict.insert("end", .int(Int64(byteEnd)))
                dict.insert("text", .str(pat))
                dict.insert("captures", .array(ArrayValue()))
                if case let .failure(diags) = handleMatch(range: byteStart..<byteEnd, dict: dict) {
                    return .failure(diags)
                }
                handled += 1
                searchStart = range.upperBound
                if pat.isEmpty { break }
            }
        case let .regex(re):
            for m in re.matches(in: value) {
                if handled >= limit { break }
                if case let .failure(diags) = handleMatch(range: m.range, dict: capturesToDict(m)) {
                    return .failure(diags)
                }
                handled += 1
            }
        }

        output += substring(byteStart: lastMatch, byteEnd: byteLength)
        return .success(Str(output))
    }

    /// `trim(pattern?, at:?, repeat:)`.
    public func trim(
        pattern: StrPattern? = nil,
        at side: StrSide? = nil,
        repeat repeatMatch: Bool = true
    ) -> Str {
        var start = side == nil || side == .start
        let end = side == nil || side == .end

        let trimmed: String
        switch pattern {
        case .none:
            switch side {
            case .none: trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .start: trimmed = String(value.drop(while: { $0.isWhitespace }))
            case .end: trimmed = String(value.reversed().drop(while: { $0.isWhitespace }).reversed())
            }
        case let .some(.str(pat)):
            let p = pat.value
            var s = value
            if repeatMatch {
                if start { while s.hasPrefix(p) && !p.isEmpty { s.removeFirst(p.count) } }
                if end { while s.hasSuffix(p) && !p.isEmpty { s.removeLast(p.count) } }
            } else {
                if start, s.hasPrefix(p) { s.removeFirst(p.count) }
                if end, s.hasSuffix(p) { s.removeLast(p.count) }
            }
            trimmed = s
        case let .some(.regex(re)):
            let s = value
            var last: Int? = nil
            var range = 0..<s.utf8.count

            for m in re.matches(in: s) {
                let consecutive = last == m.range.lowerBound

                start = start && (m.range.lowerBound == 0 || consecutive)
                if start {
                    range = m.range.upperBound..<range.upperBound
                    start = start && repeatMatch
                }

                if end && (!consecutive || !repeatMatch) {
                    range = range.lowerBound..<m.range.lowerBound
                }

                last = m.range.upperBound
            }

            if let last, last < s.utf8.count {
                range = range.lowerBound..<s.utf8.count
            }

            trimmed = substring(byteStart: range.lowerBound, byteEnd: max(range.lowerBound, range.upperBound))
        }
        return Str(trimmed)
    }

    /// `split(pattern?)`.
    public func split(_ pattern: StrPattern? = nil) -> ArrayValue {
        switch pattern {
        case .none:
            return ArrayValue(items: value.split(whereSeparator: { $0.isWhitespace })
                .map { .str(Str(String($0))) })
        case let .some(.str(pat)):
            if pat.isEmpty { return ArrayValue(items: [.str(self)]) }
            return ArrayValue(items: value.components(separatedBy: pat.value)
                .map { .str(Str($0)) })
        case let .some(.regex(re)):
            // Split on match ranges.
            var result: [Value] = []
            var last = 0
            for m in re.matches(in: value) {
                result.append(.str(Str(substring(byteStart: last, byteEnd: m.range.lowerBound))))
                last = m.range.upperBound
            }
            result.append(.str(Str(substring(byteStart: last, byteEnd: byteLength))))
            return ArrayValue(items: result)
        }
    }

    /// `rev` — reversed grapheme clusters.
    public func rev() -> Str {
        Str(String(value.reversed()))
    }
}

/// Converts a match to the dict shape used by `match`/`matches`/`replace`.
func capturesToDict(_ m: RegexMatch) -> Dict {
    var dict = Dict()
    dict.insert("start", .int(Int64(m.range.lowerBound)))
    dict.insert("end", .int(Int64(m.range.upperBound)))
    dict.insert("text", .str(Str(m.text)))
    dict.insert("captures", .array(ArrayValue(items: m.captureTexts.map {
        $0.map { .str(Str($0)) } ?? Value.none
    })))
    return dict
}

// MARK: - Supporting types

/// A string or regex pattern. Port of `StrPattern`.
public enum StrPattern: Sendable, Hashable {
    case str(Str)
    case regex(Regex)
}

/// Which side of a string to trim. Port of `StrSide`.
public enum StrSide: String, Sendable, Hashable {
    case start
    case end
}

/// A replacement: literal string or function. Port of `Replacement`.
public enum Replacement: Sendable, Hashable {
    case str(Str)
    case function(Func)
}

/// Unicode normalization forms. Port of `UnicodeNormalForm`.
public enum UnicodeNormalForm: String, Sendable, Hashable {
    case nfc
    case nfd
    case nfkc
    case nfkd
}

/// Values convertible to a string in the `str()` constructor.
/// Port of `ToStr`.
public enum ToStr: Sendable, Hashable {
    case str(Str)
    case int(Int64)
}

/// The base for integer-to-string conversion. Port of `Base`.
public enum Base: Sendable, Hashable {
    case `default`
    case user(Int64)

    public var value: Int64 {
        switch self {
        case .default: return 10
        case let .user(b): return b
        }
    }
}

extension Str: Repr {
    public func repr() -> String {
        value.typstRepr
    }
}

extension String {
    /// Typst string repr with escapes, matching upstream `Repr for str`
    /// (which delegates to Rust's `char::escape_debug` per scalar).
    var typstRepr: String {
        var r = "\""
        for scalar in unicodeScalars {
            switch scalar {
            case "\0": r += "\\u{0}"
            case "'": r += "'"
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\r": r += "\\r"
            default:
                // ASCII and C1 control characters escape as `\u{hex}`,
                // approximating Rust's `char::escape_debug`.
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                    r += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    r.unicodeScalars.append(scalar)
                }
            }
        }
        r += "\""
        return r
    }
}
