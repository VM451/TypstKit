import Testing
@testable import TypstSyntax

/// Ports of the unit tests in `typst-syntax/src/lines.rs`.
@Suite("Lines")
struct LinesTests {
    private let test = "ä\tcde\nf💛g\r\nhi\rjkl"

    @Test func lineStarts() {
        let lines = Lines(text: test)
        #expect(lines.inner.lines == [
            Line(byteIdx: 0, utf16Idx: 0),
            Line(byteIdx: 7, utf16Idx: 6),
            Line(byteIdx: 15, utf16Idx: 12),
            Line(byteIdx: 18, utf16Idx: 15),
        ])
    }

    @Test func byteToLine() {
        let lines = Lines(text: test)
        #expect(lines.byteToLine(0) == 0)
        #expect(lines.byteToLine(2) == 0)
        #expect(lines.byteToLine(6) == 0)
        #expect(lines.byteToLine(7) == 1)
        #expect(lines.byteToLine(8) == 1)
        #expect(lines.byteToLine(12) == 1)
        #expect(lines.byteToLine(21) == 3)
        #expect(lines.byteToLine(22) == nil)
        #expect(lines.byteToLine(-1) == nil)
    }

    @Test func byteToColumn() {
        let lines = Lines(text: test)
        #expect(lines.byteToColumn(0) == 0)
        #expect(lines.byteToColumn(2) == 1)
        #expect(lines.byteToColumn(6) == 5)
        #expect(lines.byteToColumn(7) == 0)
        #expect(lines.byteToColumn(8) == 1)
        #expect(lines.byteToColumn(12) == 2)
    }

    @Test func utf16RoundTrip() {
        func roundtrip(_ lines: Lines, _ byteIdx: Int, _ utf16Idx: Int) {
            let middle = lines.byteToUtf16(byteIdx)!
            let result = lines.utf16ToByte(middle)!
            #expect(middle == utf16Idx)
            #expect(result == byteIdx)
        }

        let lines = Lines(text: test)
        roundtrip(lines, 0, 0)
        roundtrip(lines, 2, 1)
        roundtrip(lines, 3, 2)
        roundtrip(lines, 8, 7)
        roundtrip(lines, 12, 9)
        roundtrip(lines, 21, 18)
        #expect(lines.byteToUtf16(22) == nil)
        #expect(lines.utf16ToByte(19) == nil)
    }

    @Test func lineColumnRoundTrip() {
        func roundtrip(_ lines: Lines, _ byteIdx: Int) {
            let line = lines.byteToLine(byteIdx)!
            let column = lines.byteToColumn(byteIdx)!
            let result = lines.lineColumnToByte(lineIdx: line, columnIdx: column)!
            #expect(result == byteIdx)
        }

        let lines = Lines(text: test)
        roundtrip(lines, 0)
        roundtrip(lines, 7)
        roundtrip(lines, 12)
        roundtrip(lines, 21)
    }

    @Test func edit() {
        // This tests only the non-parser parts. The reparsing itself is
        // tested separately.
        func checkEdit(_ prev: String, _ range: Range<Int>, _ with: String,
                      _ after: String) {
            let reference = Lines(text: after)

            let edited = Lines(text: prev)
            edited.edit(range, with: with)
            #expect(edited.text == reference.text)
            #expect(edited.inner.lines == reference.inner.lines)

            // Replace path: the diff algorithm should find the same edit.
            let replaced = Lines(text: prev)
            _ = replaced.replace(after)
            #expect(replaced.text == reference.text)
            #expect(replaced.inner.lines == reference.inner.lines)
        }

        // Test inserting at the beginning.
        checkEdit("abc\n", 0..<0, "hi\n", "hi\nabc\n")
        checkEdit("\nabc", 0..<0, "hi\r", "hi\r\nabc")

        // Test editing in the middle.
        checkEdit(self.test, 4..<16, "❌", "ä\tc❌i\rjkl")

        // Test appending.
        checkEdit("abc\ndef", 7..<7, "hi", "abc\ndefhi")
        checkEdit("abc\ndef\n", 8..<8, "hi", "abc\ndef\nhi")

        // Test appending with adjoining \r and \n.
        checkEdit("abc\ndef\r", 8..<8, "\nghi", "abc\ndef\r\nghi")

        // Test removing everything.
        checkEdit(self.test, 0..<21, "", "")
    }
}
