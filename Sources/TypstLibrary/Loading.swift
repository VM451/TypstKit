import Foundation
import TypstSyntax
import TypstUtils

// Data-loading infrastructure — port of upstream `loading/mod.rs` plus the
// `LoadError`/`LoadedWithin`/`ReportTextPos`/`LineCol` machinery from
// `diag.rs` that external-file parse errors flow through.

// MARK: - Data sources

/// Something we can retrieve byte data from. Port of `DataSource`.
public enum DataSource: Sendable, Hashable {
    /// A path to a file.
    case path(PathOrStr)
    /// Raw bytes.
    case bytes(Bytes)
}

extension DataSource: Castable, IntoValue, FromValue {
    public static var input: CastInfo { PathOrStr.input + Bytes.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        PathOrStr.castable(value) || Bytes.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .path(let p): return p.intoValue()
        case .bytes(let b): return b.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if PathOrStr.castable(value) {
            return PathOrStr.fromValue(value).map { .path($0) }
        }
        return Bytes.fromValue(value).map { .bytes($0) }
    }
}

/// Where loaded data came from. Port of `LoadSource`.
public enum LoadSource: Sendable, Hashable {
    case path(FileId)
    case bytes
}

/// Data loaded from a `DataSource`. Port of `Loaded`.
public struct Loaded: Sendable, Hashable {
    /// Where `data` was loaded from, with the requesting span.
    public var source: Spanned<LoadSource, Span>
    /// The loaded bytes.
    public var data: Bytes

    public init(source: Spanned<LoadSource, Span>, data: Bytes) {
        self.source = source
        self.data = data
    }
}

/// Load a single `DataSource` (path resolution + `world.file`).
/// Port of `impl Load for Spanned<DataSource>`.
public func load(_ source: Spanned<DataSource, Span>, _ world: World) throws -> Loaded {
    switch source.value {
    case .path(let pathOrStr):
        let resolved: RootedPath
        switch pathOrStr.resolveIfSome(within: source.span.id) {
        case .success(let r): resolved = r
        case .failure(let e):
            var diag = SourceDiagnostic.error(source.span, e.message)
            for hint in e.hints { diag.hint(hint) }
            throw SourceDiagnostics([diag])
        }
        let fileId = resolved.intern()
        let data: Bytes
        switch world.file(fileId) {
        case .success(let d): data = d
        case .failure(let error):
            var hints: [String] = []
            if case .str(let s) = pathOrStr,
               s.value.hasPrefix("http://") || s.value.hasPrefix("https://") {
                hints.append("network access is not supported")
            }
            throw bailSpan(source.span, error.message, hints: hints)
        }
        return Loaded(
            source: Spanned(LoadSource.path(fileId), span: source.span),
            data: data)
    case .bytes(let data):
        return Loaded(
            source: Spanned(LoadSource.bytes, span: source.span),
            data: data)
    }
}

/// Load multiple sources. Port of `impl Load for OneOrMultiple<DataSource>`.
public func load(_ sources: [Spanned<DataSource, Span>], _ world: World) throws -> [Loaded] {
    try sources.map { try load($0, world) }
}

/// A value readable from a file — decoded string or raw bytes.
/// Port of `Readable`.
public enum Readable: Sendable, Hashable {
    case str(Str)
    case bytes(Bytes)

    public func intoBytes() -> Bytes {
        switch self {
        case .bytes(let b): return b
        case .str(let s): return Bytes(string: s.value)
        }
    }
}

extension Readable: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Str.input + Bytes.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Str.castable(value) || Bytes.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .str(let s): return s.intoValue()
        case .bytes(let b): return b.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Str.castable(value) {
            return Str.fromValue(value).map { .str($0) }
        }
        return Bytes.fromValue(value).map { .bytes($0) }
    }
}

/// One element, or multiple provided as an array. Port of
/// `OneOrMultiple<T>`.
public struct OneOrMultiple<T: Sendable & Hashable>: Sendable, Hashable {
    public var items: [T]
    public init(_ items: [T]) { self.items = items }
}

// MARK: - Load errors

/// A line/column pair. Port of `LineCol` (0-based storage).
public struct LineCol: Sendable, Hashable {
    /// 0-based line.
    public var line: Int
    /// 0-based column.
    public var col: Int

    public init(zeroBased line: Int, col: Int) {
        self.line = line
        self.col = col
    }

    public static func zeroBased(_ line: Int, _ col: Int) -> LineCol {
        LineCol(zeroBased: line, col: col)
    }

    public static func oneBased(_ line: Int, _ col: Int) -> LineCol {
        LineCol(zeroBased: max(line - 1, 0), col: max(col - 1, 0))
    }

    /// 1-based line/column numbers.
    public var numbers: (Int, Int) { (line + 1, col + 1) }

    /// Try to compute a line/column from possibly-invalid UTF-8 data.
    /// Port of `LineCol::try_from_byte_pos`.
    public static func tryFromBytePos(_ pos: Int, bytes: [UInt8]) -> LineCol? {
        guard pos <= bytes.count else { return nil }
        let prefix = Array(bytes[..<pos])
        var line = 0
        var lineStart = prefix.count
        for (i, b) in prefix.enumerated() where b == 0x0A {
            line += 1
            lineStart = i + 1
        }
        // Count UTF-8 chars in the last line (replacement chars for
        // invalid sequences, matching upstream's error-tolerant count).
        var col = 0
        var i = lineStart
        while i < prefix.count {
            let b = prefix[i]
            let len: Int
            if b < 0x80 { len = 1 }
            else if b & 0xE0 == 0xC0 { len = 2 }
            else if b & 0xF0 == 0xE0 { len = 3 }
            else if b & 0xF8 == 0xF0 { len = 4 }
            else { len = 1 }
            i += len
            col += 1
        }
        return LineCol.zeroBased(line, col)
    }
}

/// A position in a text document at which an error was reported.
/// Port of `ReportTextPos`.
public enum ReportTextPos: Sendable, Hashable {
    /// Byte range plus line/column pair.
    case full(Range<Int>, LineCol)
    /// Byte range only.
    case range(Range<Int>)
    /// Line/column only.
    case lineCol(LineCol)
    /// No position (binary sources).
    case none

    public static func from(_ range: Range<Int>) -> ReportTextPos { .range(range) }
    public static func from(_ pair: LineCol) -> ReportTextPos { .lineCol(pair) }

    /// Byte range resolved against `lines`, if possible.
    func resolvedRange(_ lines: Lines) -> Range<Int>? {
        switch self {
        case .full(let r, _), .range(let r):
            return r
        case .lineCol(let pair):
            guard let i = lines.lineColumnToByte(
                lineIdx: pair.line, columnIdx: pair.col) else { return nil }
            return i ..< i
        case .none:
            return nil
        }
    }

    /// Line/column resolved against `lines`, if possible.
    func resolvedLineCol(_ lines: Lines) -> LineCol? {
        switch self {
        case .full(_, let pair), .lineCol(let pair):
            return pair
        case .range(let r):
            guard let (line, col) = lines.byteToLineColumn(r.lowerBound) else {
                return nil
            }
            return LineCol.zeroBased(line, col)
        case .none:
            return nil
        }
    }

    /// Line/column from possibly-invalid UTF-8 data.
    func tryLineCol(_ bytes: [UInt8]) -> LineCol? {
        switch self {
        case .full(_, let pair), .lineCol(let pair):
            return pair
        case .range(let r):
            return LineCol.tryFromBytePos(r.lowerBound, bytes: bytes)
        case .none:
            return nil
        }
    }
}

/// An error loading/parsing external data. Port of `LoadError`.
public struct LoadError: Error, Sendable, Hashable {
    /// Position in the file, `nil` for binary sources.
    public var textPos: ReportTextPos?
    /// Message formatted as `"failed to do thing (cause)"`.
    public var message: String

    /// Error at a text position: `"{message} ({error})"`.
    public static func text(_ pos: ReportTextPos, _ message: String,
                            _ error: String) -> LoadError {
        LoadError(textPos: pos, message: "\(message) (\(error))")
    }

    /// Error without position for binary sources.
    public static func binary(_ message: String, _ error: String) -> LoadError {
        LoadError(textPos: nil, message: "\(message) (\(error))")
    }
}

extension LoadError {
    /// Convert to a `SourceDiagnostic` with the `Loaded` context.
    /// Port of `LoadedWithin::within` for `LoadError`.
    public func within(_ loaded: Loaded) -> SourceDiagnostic {
        if let pos = textPos {
            // Text path: only if data is valid UTF-8, else binary path.
            if let str = String(bytes: loaded.data.storage, encoding: .utf8) {
                return loadErrInText(loaded, pos: pos, message: message,
                                     text: str)
            }
        }
        return loadErrInBinary(loaded, pos: textPos, message: message)
    }
}

/// Report an error in an external text file. Port of
/// `load_err_in_text`.
func loadErrInText(_ loaded: Loaded, pos: ReportTextPos,
                   message: String, text: String) -> SourceDiagnostic {
    let lines = Lines(text: text)
    var message = message
    switch loaded.source.value {
    case .path(let fileId):
        if let range = pos.resolvedRange(lines) {
            return SourceDiagnostic.error(
                Span.fromRange(id: fileId, range), message)
        }
        // Range resolution failed; report the possibly-wrong line:col
        // inside the message over the whole file.
        let span = Span.fromRange(id: fileId, 0 ..< loaded.data.count)
        if let pair = pos.resolvedLineCol(lines) {
            message.removeLast() // drop ')'
            let (line, col) = pair.numbers
            message += " at \(line):\(col))"
        }
        return SourceDiagnostic.error(span, message)
    case .bytes:
        if let pair = pos.resolvedLineCol(lines) {
            message.removeLast()
            let (line, col) = pair.numbers
            message += " at \(line):\(col))"
        }
        return SourceDiagnostic.error(loaded.source.span, message)
    }
}

/// Report an error in a binary (non-UTF-8) external file. Port of
/// `load_err_in_binary`.
func loadErrInBinary(_ loaded: Loaded, pos: ReportTextPos?,
                     message: String) -> SourceDiagnostic {
    let lineCol = pos?.tryLineCol(loaded.data.storage)?.numbers
    var message = message
    switch loaded.source.value {
    case .path(let file):
        message.removeLast()
        switch file.path.root {
        case .project:
            message += " in \(file.vpath.withoutSlash)"
        case .package(let spec):
            message += " in \(spec)\(file.vpath.withSlash)"
        }
        if let (line, col) = lineCol {
            message += ":\(line):\(col)"
        }
        message += ")"
    case .bytes:
        if let (line, col) = lineCol {
            message.removeLast()
            message += " at \(line):\(col))"
        }
    }
    return SourceDiagnostic.error(loaded.source.span, message)
}

/// UTF-8 validation returning the byte offset of the first invalid
/// sequence (like `Utf8Error::valid_up_to`).
func utf8ValidUpTo(_ bytes: [UInt8]) -> Int? {
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b < 0x80 { i += 1; continue }
        let need: Int
        var minValue: UInt32 = 0
        var value: UInt32 = 0
        if b & 0xE0 == 0xC0 {
            need = 2; value = UInt32(b & 0x1F); minValue = 0x80
        } else if b & 0xF0 == 0xE0 {
            need = 3; value = UInt32(b & 0x0F); minValue = 0x800
        } else if b & 0xF8 == 0xF0 {
            need = 4; value = UInt32(b & 0x07); minValue = 0x10000
        } else {
            return i
        }
        if i + need > bytes.count { return i }
        for j in 1..<need {
            let c = bytes[i + j]
            guard c & 0xC0 == 0x80 else { return i }
            value = (value << 6) | UInt32(c & 0x3F)
        }
        if value < minValue || value > 0x10FFFF
            || (0xD800...0xDFFF).contains(value) {
            return i
        }
        i += need
    }
    return nil
}

/// Decode loaded bytes as UTF-8 text, producing a `LoadError` on
/// failure. Port of upstream's `data.to_str().within(&loaded)` path
/// (`From<Utf8Error> for LoadError`).
public func loadedToStr(_ loaded: Loaded) throws -> Str {
    if let invalid = utf8ValidUpTo(loaded.data.storage) {
        let end = min(invalid + 1, loaded.data.count)
        let error = LoadError.text(
            ReportTextPos.range(invalid ..< end),
            "failed to convert to string",
            "file is not valid UTF-8")
        throw SourceDiagnostics([error.within(loaded)])
    }
    // Valid UTF-8 — safe to decode.
    return Str(String(decoding: loaded.data.storage, as: UTF8.self))
}

extension OneOrMultiple: Fold {
    /// Outer items first, then inner appended (upstream `Fold for
    /// OneOrMultiple<T>`).
    public static func fold(_ inner: Self, _ outer: Self) -> Self {
        OneOrMultiple(outer.items + inner.items)
    }
}
