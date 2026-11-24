import Foundation

/// A text buffer and metadata about lines.
/// Port of `typst-syntax/src/lines.rs`.
///
/// This is internally reference-counted and thus cheap to clone.
final class Lines: @unchecked Sendable {
    var inner: Inner

    final class Inner {
        var lines: [Line]
        var text: String

        init(lines: [Line], text: String) {
            self.lines = lines
            self.text = text
        }
    }

    init(text: String) {
        self.inner = Inner(lines: Lines.computeLines(text), text: text)
    }

    /// The text as a string.
    var text: String { inner.text }

    /// The length of the file in UTF-8 encoded bytes.
    var lenBytes: Int { inner.text.utf8.count }

    /// The length of the file in UTF-16 code units.
    var lenUtf16: Int {
        let last = inner.lines[inner.lines.count - 1]
        let tail = byteSlice(last.byteIdx..<inner.text.utf8.count) ?? ""
        return last.utf16Idx + Lines.lenUtf16(tail)
    }

    /// The length of the file in lines.
    var lenLines: Int { inner.lines.count }

    /// Return the index of the UTF-16 code unit at the byte index.
    func byteToUtf16(_ byteIdx: Int) -> Int? {
        guard let lineIdx = byteToLine(byteIdx),
              lineIdx < inner.lines.count else { return nil }
        let line = inner.lines[lineIdx]
        guard let head = byteSlice(line.byteIdx..<byteIdx) else { return nil }
        return line.utf16Idx + Lines.lenUtf16(head)
    }

    /// Return the index of the line that contains the given byte index.
    func byteToLine(_ byteIdx: Int) -> Int? {
        guard byteIdx >= 0, byteIdx <= inner.text.utf8.count else { return nil }
        // Binary search for the last line starting at or before byteIdx.
        var lo = 0
        var hi = inner.lines.count
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if inner.lines[mid].byteIdx <= byteIdx {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Return the index of the column at the byte index.
    ///
    /// The column is defined as the number of characters in the line before
    /// the byte index.
    func byteToColumn(_ byteIdx: Int) -> Int? {
        guard let line = byteToLine(byteIdx),
              let start = lineToByte(line),
              let head = byteSlice(start..<byteIdx) else { return nil }
        return head.unicodeScalars.count
    }

    /// Return the index of the line and column at the byte index.
    func byteToLineColumn(_ byteIdx: Int) -> (line: Int, column: Int)? {
        guard let line = byteToLine(byteIdx),
              let start = lineToByte(line),
              let head = byteSlice(start..<byteIdx) else { return nil }
        return (line, head.unicodeScalars.count)
    }

    /// Return the byte index at the UTF-16 code unit.
    func utf16ToByte(_ utf16Idx: Int) -> Int? {
        guard utf16Idx >= 0 else { return nil }
        let bytes = Array(inner.text.utf8)
        // Find the last line whose utf16 start is <= utf16Idx.
        var lo = 0
        var hi = inner.lines.count
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if inner.lines[mid].utf16Idx <= utf16Idx {
                lo = mid
            } else {
                hi = mid
            }
        }
        guard lo < inner.lines.count else { return nil }
        let line = inner.lines[lo]

        var k = line.utf16Idx
        var idx = line.byteIdx
        while idx < bytes.count {
            if k >= utf16Idx {
                return idx
            }
            let scalarLen = Lines.utf8ScalarLength(bytes[idx])
            guard let scalar = Lines.decodeScalar(bytes, at: idx) else { break }
            k += scalar.utf16.count
            idx += scalarLen
        }
        return k == utf16Idx ? bytes.count : nil
    }

    /// Return the byte position at which the given line starts.
    func lineToByte(_ lineIdx: Int) -> Int? {
        guard lineIdx < inner.lines.count else { return nil }
        return inner.lines[lineIdx].byteIdx
    }

    /// Return the range which encloses the given line.
    func lineToRange(_ lineIdx: Int) -> Range<Int>? {
        guard let start = lineToByte(lineIdx) else { return nil }
        let end = lineToByte(lineIdx + 1) ?? inner.text.utf8.count
        return start..<end
    }

    /// Return the byte index of the given (line, column) pair, or `nil` if
    /// either is out-of-range.
    ///
    /// The column defines the number of characters to go beyond the start of
    /// the line.
    func lineColumnToByte(lineIdx: Int, columnIdx: Int) -> Int? {
        guard columnIdx >= 0,
              let range = lineToRange(lineIdx),
              let line = byteSlice(range) else { return nil }
        var byteCount = 0
        var seen = 0
        for scalar in line.unicodeScalars {
            if seen == columnIdx { break }
            byteCount += String(scalar).utf8.count
            seen += 1
        }
        guard seen == columnIdx else { return nil }
        return range.lowerBound + byteCount
    }

    // MARK: - Editing

    /// Fully replace the source text.
    ///
    /// Performs a naive (suffix/prefix-based) diff to produce the smallest
    /// single edit and calls `edit` with it.
    ///
    /// Returns whether any changes were made.
    @discardableResult
    func replace(_ new: String) -> Bool {
        guard let (prefix, suffix) = replacementRange(new) else { return false }

        let old = inner.text
        let replace = prefix..<(old.utf8.count - suffix)
        let newBytes = Array(new.utf8)
        let with = String(decoding: newBytes[prefix..<(newBytes.count - suffix)],
                          as: UTF8.self)
        edit(replace, with: with)
        return true
    }

    /// Returns the common prefix and suffix lengths.
    /// Returns `nil` if the old and new strings are equal.
    func replacementRange(_ new: String) -> (prefix: Int, suffix: Int)? {
        let old = inner.text
        let oldBytes = Array(old.utf8)
        let newBytes = Array(new.utf8)

        var prefix = 0
        while prefix < oldBytes.count && prefix < newBytes.count
            && oldBytes[prefix] == newBytes[prefix] {
            prefix += 1
        }

        if prefix == oldBytes.count && prefix == newBytes.count {
            return nil
        }

        // Back off to a char boundary in both strings.
        while !isCharBoundary(old, byteOffset: prefix)
            || !isCharBoundary(new, byteOffset: prefix) {
            prefix -= 1
        }

        var suffix = 0
        while suffix < oldBytes.count - prefix && suffix < newBytes.count - prefix
            && oldBytes[oldBytes.count - 1 - suffix] == newBytes[newBytes.count - 1 - suffix] {
            suffix += 1
        }

        while !isCharBoundary(old, byteOffset: oldBytes.count - suffix)
            || !isCharBoundary(new, byteOffset: newBytes.count - suffix) {
            suffix += 1
        }

        return (prefix, suffix)
    }

    /// Edit the source file by replacing the given range.
    ///
    /// The method traps if the `replace` range is out of bounds or not on a
    /// char boundary, matching Rust's `String::replace_range` panics.
    func edit(_ replace: Range<Int>, with: String) {
        let startByte = replace.lowerBound
        let startUtf16 = byteToUtf16(startByte)!
        let line = byteToLine(startByte)!

        // Update the text itself (byte splice; ranges are UTF-8 offsets).
        var bytes = Array(inner.text.utf8)
        precondition(replace.lowerBound >= 0
            && replace.upperBound <= bytes.count
            && replace.lowerBound <= replace.upperBound)
        precondition(isCharBoundary(inner.text, byteOffset: replace.lowerBound))
        precondition(isCharBoundary(inner.text, byteOffset: replace.upperBound))
        bytes.replaceSubrange(replace, with: with.utf8)
        inner.text = String(decoding: bytes, as: UTF8.self)

        // Remove invalidated line starts.
        inner.lines.removeLast(inner.lines.count - (line + 1))

        // Handle adjoining of \r and \n.
        let newBytes = Array(inner.text.utf8)
        if startByte > 0, startByte <= newBytes.count,
           newBytes[startByte - 1] == 0x0D,
           with.utf8.first == 0x0A {
            inner.lines.removeLast()
        }

        // Recalculate the line starts after the edit.
        let tailBytes = Array(inner.text.utf8)[startByte...]
        let tail = String(decoding: tailBytes, as: UTF8.self)
        inner.lines.append(contentsOf: Lines.linesFrom(
            byteOffset: startByte, utf16Offset: startUtf16, text: tail
        ))
    }

    // MARK: - Helpers

    /// Extract a byte range as a String (nil if out of bounds or not on a
    /// char boundary).
    private func byteSlice(_ range: Range<Int>) -> String? {
        let bytes = Array(inner.text.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count,
              range.lowerBound <= range.upperBound else { return nil }
        // Validate boundaries.
        guard isCharBoundary(inner.text, byteOffset: range.lowerBound),
              isCharBoundary(inner.text, byteOffset: range.upperBound) else {
            return nil
        }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    /// Whether `byteOffset` is a valid UTF-8 char boundary in `text`.
    private func isCharBoundary(_ text: String, byteOffset: Int) -> Bool {
        let bytes = Array(text.utf8)
        guard byteOffset >= 0, byteOffset <= bytes.count else { return false }
        if byteOffset == bytes.count || byteOffset == 0 { return true }
        return (bytes[byteOffset] & 0xC0) != 0x80
    }

    private static func lenUtf16(_ string: String) -> Int {
        string.unicodeScalars.reduce(0) { $0 + $1.utf16.count }
    }

    private static func utf8ScalarLength(_ first: UInt8) -> Int {
        if first < 0x80 { return 1 }
        if first < 0xE0 { return 2 }
        if first < 0xF0 { return 3 }
        return 4
    }

    private static func decodeScalar(_ bytes: [UInt8], at i: Int) -> Unicode.Scalar? {
        guard i < bytes.count else { return nil }
        let len = utf8ScalarLength(bytes[i])
        guard i + len <= bytes.count else { return nil }
        return String(decoding: bytes[i..<(i + len)], as: UTF8.self).unicodeScalars.first
    }

    /// Create a line vector.
    private static func computeLines(_ text: String) -> [Line] {
        [Line(byteIdx: 0, utf16Idx: 0)] + linesFrom(byteOffset: 0, utf16Offset: 0, text: text)
    }

    /// Compute line starts from an offset.
    private static func linesFrom(
        byteOffset: Int, utf16Offset: Int, text: String
    ) -> [Line] {
        let bytes = Array(text.utf8)
        var result: [Line] = []
        var utf16Idx = utf16Offset
        var i = 0

        while i < bytes.count {
            // Advance utf16 index over scalars until a newline.
            let scalarLen = Lines.utf8ScalarLength(bytes[i])
            guard let scalar = Lines.decodeScalar(bytes, at: i) else { break }
            utf16Idx += scalar.utf16.count
            i += scalarLen

            if isNewline(scalar) {
                // Handle \r\n as a single line break.
                if scalar == "\r", i < bytes.count, bytes[i] == 0x0A {
                    utf16Idx += 1
                    i += 1
                }
                result.append(Line(byteIdx: byteOffset + i, utf16Idx: utf16Idx))
            }
        }
        return result
    }
}

/// Metadata about a line.
struct Line: Equatable {
    /// The UTF-8 byte offset where the line starts.
    var byteIdx: Int
    /// The UTF-16 code unit offset where the line starts.
    var utf16Idx: Int
}
