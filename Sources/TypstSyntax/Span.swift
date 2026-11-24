import Foundation

/// A span points into a specific location in a source file.
///
/// Port of `typst-syntax/src/span.rs`. The internal representation packs
/// a 16-bit file id and 48 bits of span data into a `UInt64`, matching
/// upstream's `NonZeroU64` layout:
///
/// ```text
/// | 16 bits file id | 48 bits number |
/// ```
///
/// Span numbers within a source file:
/// - Detached: 1 (file id is 0)
/// - Typst source: `2 ..< 2^47` (one 47-bit number)
/// - External file start: `2^47 ..< 2^47 + 2^46` (one 46-bit number)
/// - Internal range span: `2^47 + 2^46 ..< 2^48` (two 23-bit numbers)
public struct Span: Sendable {
    /// Raw packed value; never zero.
    public let raw: UInt64

    /// The detached span that does not point into any file.
    public static let detached = Span(raw: 1)

    /// The full range of numbers available for source file span numbering.
    static let fullRange: ClosedRange<UInt64> = 2 ... ((1 << 47) - 1)

    /// The full range of assignable span numbers (upstream `Span::FULL`).
    static let FULL: Range<UInt64> = 2 ..< (1 << 47)

    /// Reserved value for the detached span.
    static let detachedRaw: UInt64 = 1

    static let numberBits = 48
    static let rangeBits = 46
    static let fileIdShift = numberBits
    static let numberMask: UInt64 = (1 << numberBits) - 1
    static let externalBase: UInt64 = 1 << 47
    static let externalValueMax: UInt64 = (1 << rangeBits) - 1
    static let rangeBase: UInt64 = externalBase + (1 << rangeBits)
    static let rangeValueBits = 23
    static let rangeValueMax: UInt64 = (1 << rangeValueBits) - 1

    /// Create a span from a file id and span number.
    public init(number id: FileId, _ num: UInt64) {
        precondition(Self.fullRange.contains(num), "span number out of range")
        self.raw = Self.pack(id: id, low: num)
    }

    /// Construct from a raw number.
    public init(rawValue: UInt64) {
        self.raw = max(rawValue, 1)
    }

    private init(raw: UInt64) {
        self.raw = raw
    }

    /// Pack a file id and low bits.
    static func pack(id: FileId, low: UInt64) -> UInt64 {
        (UInt64(id.raw) << fileIdShift) | low
    }

    /// A span for the start of an external file range (paired with the
    /// end stored in `DiagSpan.extra`).
    static func externalStart(id: FileId, start: UInt64) -> Span {
        Span(raw: pack(id: id, low: externalBase + start))
    }

    /// An internal range span packing start and end (23 bits each).
    static func internalRange(id: FileId, start: UInt64, end: UInt64) -> Span {
        let s = min(start, rangeValueMax)
        let e = min(end, rangeValueMax)
        return Span(raw: pack(id: id, low: rangeBase + (s << rangeValueBits) + e))
    }

    /// Create a span from a file id and raw span number (no range check;
    /// used by the parser's number assignment).
    static func fromNumber(id: FileId, _ num: UInt64) -> Span {
        Span(raw: pack(id: id, low: num))
    }

    /// Create a span from a raw byte range instead of a span number.
    /// Parts exceeding `2^23 - 1` are saturated.
    static func fromRange(id: FileId, _ range: Range<Int>) -> Span {
        let start = saturate(range.lowerBound, rangeValueMax)
        let end = saturate(range.upperBound, rangeValueMax)
        return Span(raw: pack(id: id, low: rangeBase + (start << rangeValueBits) + end))
    }

    /// Saturate an index into the given limit.
    static func saturate(_ v: Int, _ limit: UInt64) -> UInt64 {
        Swift.min(UInt64(Swift.max(0, v)), limit)
    }

    /// Whether the span is detached.
    public var isDetached: Bool { raw == Self.detachedRaw }

    /// The id of the file the span points into.
    public var id: FileId? {
        let bits = raw >> Self.fileIdShift
        guard bits != 0, bits <= UInt64(UInt16.max) else { return nil }
        return FileId(rawValue: UInt16(bits))
    }

    /// The unique number of the span within its source.
    public var number: UInt64 { raw & Self.numberMask }

    /// Unpack into a `SpanKind` for easier use.
    public var kind: SpanKind {
        guard let id = id else { return .detached }
        let num = number
        if num >= Self.rangeBase {
            let packed = num - Self.rangeBase
            let start = Int(packed >> Self.rangeValueBits)
            let end = Int(packed & Self.rangeValueMax)
            return .range(id: id, range: start ..< end)
        }
        return .number(id: id, num: SpanNumber(num))
    }

    /// Return `other` if `self` is detached and `self` otherwise.
    public func `or`(_ other: Span) -> Span {
        isDetached ? other : self
    }

    /// Find the first non-detached span.
    public static func find(_ spans: [Span]) -> Span {
        spans.first(where: { !$0.isDetached }) ?? .detached
    }

    /// Convert to a diagnostic span (no sub-range).
    public var diag: DiagSpan { DiagSpan(span: self) }
}

extension Span: Hashable {
    public static func == (a: Span, b: Span) -> Bool { a.raw == b.raw }
    public func hash(into hasher: inout Hasher) { hasher.combine(raw) }
}

extension Span: CustomDebugStringConvertible {
    public var debugDescription: String { "Span(\(kind))" }
}

/// The unique number of a span within its `Source`.
public struct SpanNumber: Hashable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

/// The possible kinds of span.
public enum SpanKind: Sendable {
    /// A span that does not point into any file.
    case detached
    /// A numbered span.
    case number(id: FileId, num: SpanNumber)
    /// A raw byte range in a file.
    case range(id: FileId, range: Range<Int>)
}

/// A sub-range within a span's overall range.
public struct SubRange: Hashable, Sendable {
    public let start: Int
    public let end: Int

    public init?(_ start: Int, _ end: Int) {
        guard start < end else { return nil }
        self.start = start
        self.end = end
    }

    /// Express as a relative range.
    public func toRelative() -> Range<Int> { start ..< end }

    /// Express as an absolute range given the span's offset.
    public func toAbsolute(_ offset: Int) -> Range<Int> {
        (offset + start) ..< (offset + end)
    }
}

/// The span of a diagnostic message. Either from a Typst source file or
/// from a loaded external file.
///
/// Port of `DiagSpan`: a `Span` plus an `extra` word holding either a
/// sub-range (packed `start << 32 | end`) or the end of an external range.
public struct DiagSpan: Hashable, Sendable {
    /// The underlying span.
    public var span: Span
    /// Extra data: sub-range or external-range end.
    public var extra: UInt64

    /// The detached diagnostic span.
    public static let detached = DiagSpan(span: .detached, extra: 0)

    /// Direct construction from a span and extra word.
    public init(span: Span, extra: UInt64) {
        self.span = span
        self.extra = extra
    }

    /// Create from an external file's byte range.
    /// Values exceeding `2^46 - 1` are saturated.
    public init(range id: FileId, _ range: Range<Int>) {
        let start = Self.saturate(range.lowerBound, Span.externalValueMax)
        let end = Self.saturate(range.upperBound, Span.externalValueMax)
        self.init(span: Span.externalStart(id: id, start: start), extra: end)
    }

    /// Create from a source span and optional sub-range.
    public init(span: Span, subRange: SubRange? = nil) {
        self.span = span
        self.extra = subRange.map { (UInt64(bitPattern: Int64($0.start)) << 32) | UInt64($0.end) } ?? 0
    }

    /// Whether the span is detached.
    public var isDetached: Bool { span.isDetached }

    /// The id of the file the span points into.
    public var id: FileId? { span.id }

    /// Return `other` if `self` is detached.
    public func `or`(_ other: DiagSpan) -> DiagSpan {
        isDetached ? other : self
    }

    /// The unpacked kind.
    public var kind: DiagSpanKind {
        guard let id = span.id else { return .detached }
        let num = span.number
        if num >= Span.rangeBase {
            let packed = num - Span.rangeBase
            let start = Int(packed >> Span.rangeValueBits)
            let end = Int(packed & Span.rangeValueMax)
            return .range(id: id, range: start ..< end)
        } else if num >= Span.externalBase {
            return .range(id: id, range: Int(num - Span.externalBase) ..< Int(extra))
        } else {
            let sub: SubRange? = extra != 0
                ? SubRange(Int(extra >> 32), Int(extra & 0xFFFF_FFFF))
                : nil
            return .number(id: id, num: SpanNumber(num), subRange: sub)
        }
    }

    private static func saturate(_ v: Int, _ limit: UInt64) -> UInt64 {
        Swift.min(UInt64(Swift.max(0, v)), limit)
    }
}

/// The possible kinds of a diagnostic span.
public enum DiagSpanKind: Sendable {
    case detached
    case number(id: FileId, num: SpanNumber, subRange: SubRange?)
    case range(id: FileId, range: Range<Int>)
}

extension DiagSpan: CustomDebugStringConvertible {
    public var debugDescription: String { "DiagSpan(\(kind))" }
}

/// A value together with the span it originated from.
public struct Spanned<T, S: Sendable & Hashable>: Sendable, Hashable
where T: Sendable & Hashable {
    public var value: T
    public var span: S

    public init(_ value: T, span: S) {
        self.value = value
        self.span = span
    }

    public func map<U: Sendable & Hashable>(_ f: (T) -> U) -> Spanned<U, S> {
        Spanned<U, S>(f(value), span: span)
    }
}

extension Spanned where S == Span {
    /// A spanned value with a detached span.
    public static func detached(_ value: T) -> Spanned<T, Span> {
        Spanned(value, span: .detached)
    }

    /// Borrow the value with its span.
    public var asRef: Spanned<T, Span> { self }
}

/// Maps ranges in derived text back to ranges in the original text.
/// Port of `RangeMapper` in span.rs.
public struct RangeMapper: Hashable {
    /// A mapping from an old index to a new one; guarantees `old <= new`.
    struct Mapping: Hashable {
        var old: Int
        var new: Int
    }

    var vec: [Mapping]
    var total: Int

    /// Creates a new range mapper.
    ///
    /// `segments` are ranges in the original text that are consecutively
    /// concatenated to produce the derived text. Segments must be in order.
    public init(segments: [Range<Int>]) throws {
        var map = Mapping(old: 0, new: 0)
        var vec: [Mapping] = []
        for range in segments {
            let (start, end) = (range.lowerBound, range.upperBound)
            if start > end || map.new > start {
                throw RangeMapperError(message: "invalid mapper segment: (\(start), \(end))")
            }
            map.new = start
            vec.append(map)
            map.old += end - start
        }
        if vec.isEmpty {
            self.vec = [map]
            self.total = 0
        } else {
            self.vec = vec
            self.total = map.old
        }
    }

    /// The total length of the original text.
    public var totalLen: Int { total }

    /// Maps a range in the derived text back to a range in the original
    /// text. `start <= end`, `end <= totalLen`.
    public func map(_ range: Range<Int>) -> Range<Int> {
        if range.upperBound == 0 {
            let offset = vec[0].new
            return offset ..< offset
        } else if range.lowerBound == range.upperBound {
            let offset = mapEnd(range.lowerBound)
            return offset ..< offset
        } else {
            let start = mapStart(range.lowerBound)
            let end = mapEnd(range.upperBound)
            return start ..< end
        }
    }

    /// Map a relative sub-range at an offset to a new sub-range.
    public func mapSubRange(offset: Int, subRange: SubRange) -> SubRange {
        let range = subRange.toAbsolute(offset)
        let newOffset = mapStart(offset)
        let start = mapStart(range.lowerBound)
        let end = mapEnd(range.upperBound)
        // Sub-ranges have start < end, so this cannot fail.
        return SubRange(start - newOffset, end - newOffset)!
    }

    /// Map a single offset, preferring the second index if at a boundary.
    func mapStart(_ offset: Int) -> Int {
        // First index whose `old > offset`; step back one.
        var lo = 0, hi = vec.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if vec[mid].old <= offset { lo = mid + 1 } else { hi = mid }
        }
        let m = vec[lo - 1]
        return m.new + (offset - m.old)
    }

    /// Map a single offset, preferring the first index if at a boundary.
    /// Panics if `offset` is 0.
    func mapEnd(_ offset: Int) -> Int {
        precondition(offset != 0)
        var lo = 0, hi = vec.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if vec[mid].old < offset { lo = mid + 1 } else { hi = mid }
        }
        let m = vec[lo - 1]
        return m.new + (offset - m.old)
    }
}

/// Error for invalid range-mapper segments and length mismatches.
public struct RangeMapperError: Error, Hashable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}
