import Foundation

/// A cursor-based scanner over UTF-8 text, port of the `unscanny::Scanner`
/// API surface used by `typst-syntax` (lexer, raw parsing, link prefixes).
///
/// All offsets are byte offsets into the UTF-8 encoding, matching Rust's
/// `&str` byte indexing.
struct Scanner {
    /// The full UTF-8 bytes being scanned.
    let bytes: [UInt8]
    /// Current byte cursor.
    private(set) var cursor: Int

    init(_ text: String) {
        self.bytes = Array(text.utf8)
        self.cursor = 0
    }

    init(bytes: [UInt8], cursor: Int = 0) {
        self.bytes = bytes
        self.cursor = cursor
    }

    /// The remaining text as a String (decodes lossily like Rust would not
    /// need to — input is always valid UTF-8 in practice).
    var after: String {
        String(decoding: bytes[cursor...], as: UTF8.self)
    }

    /// The text before the cursor.
    var before: String {
        String(decoding: bytes[..<cursor], as: UTF8.self)
    }

    /// Whether the scanner is at the end.
    var done: Bool { cursor >= bytes.count }

    /// Total byte length.
    var length: Int { bytes.count }

    /// Decode the Unicode scalar starting at `index`, returning it and its
    /// UTF-8 length, or nil if out of bounds / invalid.
    private func scalar(at index: Int) -> (Unicode.Scalar, Int)? {
        guard index < bytes.count else { return nil }
        let b0 = bytes[index]
        if b0 < 0x80 { return (Unicode.Scalar(b0), 1) }
        let len: Int
        var value: UInt32
        if b0 & 0xE0 == 0xC0 { len = 2; value = UInt32(b0 & 0x1F) }
        else if b0 & 0xF0 == 0xE0 { len = 3; value = UInt32(b0 & 0x0F) }
        else if b0 & 0xF8 == 0xF0 { len = 4; value = UInt32(b0 & 0x07) }
        else { return (Unicode.Scalar(0xFFFD)!, 1) }
        guard index + len <= bytes.count else { return nil }
        for i in 1..<len {
            let b = bytes[index + i]
            guard b & 0xC0 == 0x80 else { return (Unicode.Scalar(0xFFFD)!, 1) }
            value = (value << 6) | UInt32(b & 0x3F)
        }
        guard let scalar = Unicode.Scalar(value) else {
            return (Unicode.Scalar(0xFFFD)!, 1)
        }
        return (scalar, len)
    }

    /// Eat the next scalar, returning it.
    mutating func eat() -> Unicode.Scalar? {
        guard let (scalar, len) = scalar(at: cursor) else { return nil }
        cursor += len
        return scalar
    }

    /// Peek at the next scalar without consuming.
    func peek() -> Unicode.Scalar? { scalar(at: cursor)?.0 }

    /// Look `offset` scalars ahead (negative looks behind). Returns nil when
    /// out of bounds. Mirrors `unscanny`'s `scout`.
    func scout(_ offset: Int) -> Unicode.Scalar? {
        if offset == 0 { return peek() }
        if offset > 0 {
            var idx = cursor
            var remaining = offset
            while remaining > 0 {
                guard let (_, len) = scalar(at: idx) else { return nil }
                idx += len
                remaining -= 1
            }
            return scalar(at: idx)?.0
        }
        // Negative: walk backwards over UTF-8 continuation boundaries.
        var idx = cursor
        var remaining = -offset
        while remaining > 0 {
            guard idx > 0 else { return nil }
            idx -= 1
            while idx > 0 && bytes[idx] & 0xC0 == 0x80 { idx -= 1 }
            remaining -= 1
        }
        return scalar(at: idx)?.0
    }

    /// Jump the cursor to a byte offset.
    mutating func jump(_ index: Int) {
        cursor = min(max(index, 0), bytes.count)
    }

    /// Move the cursor forward by `by` bytes.
    mutating func advance(_ by: Int) {
        jump(cursor + by)
    }

    /// Move the cursor back over the last eaten scalar.
    mutating func uneat() {
        guard cursor > 0 else { return }
        cursor -= 1
        while cursor > 0 && bytes[cursor] & 0xC0 == 0x80 { cursor -= 1 }
    }

    /// The text from byte `start` to the cursor.
    func from(_ start: Int) -> String {
        String(decoding: bytes[start..<cursor], as: UTF8.self)
    }

    /// The text in a byte range.
    func get(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// The UTF-8 byte length of a string.
    static func byteLength(_ s: String) -> Int { s.utf8.count }

    /// Eat one newline sequence (CRLF counts as one).
    @discardableResult
    mutating func eatNewline() -> Bool {
        guard let c = peek(), isNewline(c) else { return false }
        _ = eat()
        if c == "\r", peek() == "\n" { _ = eat() }
        return true
    }

    /// Whether the scanner is positioned at a prefix matching `text`.
    func at(_ text: String) -> Bool {
        let t = Array(text.utf8)
        guard cursor + t.count <= bytes.count else { return false }
        return Array(bytes[cursor..<cursor + t.count]) == t
    }

    /// Whether the next scalar satisfies `pred`.
    func at(_ pred: (Unicode.Scalar) -> Bool) -> Bool {
        guard let c = peek() else { return false }
        return pred(c)
    }

    /// Whether the next scalar is in `chars`.
    func at(_ chars: Set<Unicode.Scalar>) -> Bool {
        guard let c = peek() else { return false }
        return chars.contains(c)
    }

    /// Eat the next scalar if it equals `c`.
    @discardableResult
    mutating func eatIf(_ c: Unicode.Scalar) -> Bool {
        guard peek() == c else { return false }
        _ = eat()
        return true
    }

    /// Eat the next scalar if it is in `chars`.
    @discardableResult
    mutating func eatIf(_ chars: Set<Unicode.Scalar>) -> Bool {
        guard let c = peek(), chars.contains(c) else { return false }
        _ = eat()
        return true
    }

    /// Eat the next scalar if it satisfies `pred`.
    @discardableResult
    mutating func eatIf(_ pred: (Unicode.Scalar) -> Bool) -> Bool {
        guard let c = peek(), pred(c) else { return false }
        _ = eat()
        return true
    }

    /// Eat the given string prefix.
    @discardableResult
    mutating func eatIf(_ text: String) -> Bool {
        guard at(text) else { return false }
        advance(text.utf8.count)
        return true
    }

    /// Eat while `pred` holds, returning the eaten text.
    @discardableResult
    mutating func eatWhile(_ pred: (Unicode.Scalar) -> Bool) -> String {
        let start = cursor
        while let c = peek(), pred(c) { _ = eat() }
        return from(start)
    }

    /// Eat while the next scalar is in `chars`, returning the eaten text.
    @discardableResult
    mutating func eatWhile(_ chars: Set<Unicode.Scalar>) -> String {
        eatWhile { chars.contains($0) }
    }

    /// Eat until `pred` holds (or end), returning the eaten text.
    @discardableResult
    mutating func eatUntil(_ pred: (Unicode.Scalar) -> Bool) -> String {
        let start = cursor
        while let c = peek(), !pred(c) { _ = eat() }
        return from(start)
    }
}

/// Whether a scalar is interpreted as a newline by Typst.
/// Port of `lexer.rs::is_newline`.
func isNewline(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "\n", "\u{0B}", "\u{0C}", "\r",
         "\u{0085}", "\u{2028}", "\u{2029}":
        return true
    default:
        return false
    }
}

/// Count newline sequences in text.
func countNewlines(_ text: String) -> Int {
    var s = Scanner(text)
    var count = 0
    while let c = s.eat() {
        if isNewline(c) {
            if c == "\r", s.peek() == "\n" { _ = s.eat() }
            count += 1
        }
    }
    return count
}

/// Split text at newlines; newline characters are not kept.
/// Port of `lexer.rs::split_newlines`.
func splitNewlines(_ text: String) -> [String] {
    var s = Scanner(text)
    var lines: [String] = []
    var start = 0
    var end = 0
    while let c = s.eat() {
        if isNewline(c) {
            if c == "\r", s.peek() == "\n" { _ = s.eat() }
            lines.append(s.get(start..<end))
            start = s.cursor
        }
        end = s.cursor
    }
    lines.append(s.get(start..<s.cursor))
    return lines
}
