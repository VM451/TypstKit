import Testing
@testable import TypstSyntax

/// Ports of the tests in `typst-syntax/src/reparser.rs`.
@Suite("Reparser")
struct ReparserTests {
    /// How to replace text in the test string.
    enum Edit {
        /// Insert at the end.
        case end
        /// Insert at an index.
        case at(Int)
        /// Replace the given range.
        case range(Range<Int>)
        /// Replace the first match in the original.
        case match(String)
        /// Insert at the index after the first match of this string.
        case after(String)

        func intoRange(_ text: String) -> Range<Int> {
            switch self {
            case .end:
                return text.utf8.count..<text.utf8.count
            case .at(let index):
                #expect(text.utf8.count >= index, "index is out of bounds")
                return index..<index
            case .range(let range):
                #expect(text.utf8.count >= range.upperBound, "range is out of bounds")
                return range
            case .match(let pat):
                guard let r = text.range(of: pat) else {
                    Issue.record("pattern must exist in original")
                    return 0..<0
                }
                let start = text[..<r.lowerBound].utf8.count
                return start..<(start + pat.utf8.count)
            case .after(let pat):
                guard let r = text.range(of: pat) else {
                    Issue.record("pattern must exist in original")
                    return 0..<0
                }
                let end = text[..<r.upperBound].utf8.count
                return end..<end
            }
        }
    }

    /// What kind of reparsing happened.
    enum Reparse: Equatable {
        /// The whole text was reparsed.
        case all
        /// The text was parsed incrementally matching this string.
        case incr(String)
    }

    /// Byte-slice a string (like Rust's `&text[range]`).
    private func byteSlice(_ text: String, _ range: Range<Int>) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    /// Assert that all spans in the tree are valid and not detached.
    private func checkValidSpans(_ root: SyntaxNode) {
        root.traverse { node in
            #expect(
                !node.span.isDetached,
                "found a detached span for \(node.kind): '\(node.fullText())'"
            )
            return node.children
        }
    }

    private func test(_ text: String, _ edit: Edit, _ with: String,
                      _ expected: Reparse) {
        var source = Source(id: FileId.newForTest("test_reparse"), text: text)
        let origTree = source.root
        // `Source.edit` is the public interface for reparsing.
        let replacedRange = source.edit(edit.intoRange(text), with: with)
        let reparsedTree = source.root
        checkValidSpans(origTree)
        checkValidSpans(reparsedTree)
        let normalParse = parse(source.text)
        #expect(normalParse.span.isDetached, "should be detached")
        if !reparsedTree.spanlessEq(normalParse) {
            print("Original source text: \(text.debugDescription)")
            print("New source text: \(source.text.debugDescription)")
            Issue.record("Reparsed tree did not match normal parse")
        }
        let actual: Reparse =
            replacedRange == (0..<source.text.utf8.count)
            ? .all
            : .incr(byteSlice(source.text, replacedRange))
        #expect(actual == expected)
    }

    /// Basic tests for the reparsing algorithm and the testing framework.
    @Test func reparseBasic() {
        // Replace everything with something else:
        test("some content", .match("some content"), "do it", .all)
        test("some content", .range(0..<12), "", .all)
        test("", .at(0), "do it", .all)
        test("", .end, "do it", .all)
        // Add something at the end:
        test("some content", .after("some content"), " do it", .all)
    }

    /// Test incremental reparsing of markup expressions.
    @Test func reparseMarkupTests() {
        // Tilde is useful because it always creates a distinct token, whereas
        // spaces may join with adjacent text as one token.
        test("abc~def~gh~", .range(5..<6), "+", .incr("abc~d+f~"))
        test("~~~~~~~", .range(3..<4), "A", .incr("~~~A~~"))
        test("abc~~", .match("b"), "", .incr("ac~"))
        // Newlines behave slightly differently to tildes:
        test("~b~c~d~e", .at(0), "a", .incr("a~b"))
        test("a~b~c~d~", .end, "e", .incr("~d~e"))
        test("\nb\nc\nd\ne", .at(0), "a", .incr("a\nb\n"))
        test("a\nb\nc\nd\n", .end, "e", .incr("c\nd\ne"))
        test("#var. hello", .match(" "), " ", .all)
        test("#var;hello", .range(9..<10), "a", .all)
        test("https:/world", .after("/"), "/", .all)
        test("hello  world", .match("world"), "walkers", .all)
        test("a d e", .match(" d"), " b c d", .all)
        test("~*~*~", .at(2), "*", .all)
        test("::1\n2. a\n3", .after(" "), "4", .incr("1\n2. 4a\n"))
        test("* #{1+2} *", .match("2"), "3", .incr("{1+3}"))
        test("#{(0, 1, 2)}", .match("1"), "11pt", .incr("{(0, 11pt, 2)}"))
        test("\n= A heading", .after("A"), "n evocative", .all)
        test("#call() abc~d", .after("()"), "[]", .incr("#call()[] abc"))
        test("a your thing a", .range(6..<7), "a", .all)
        test("#grid(columns: (auto, 1fr, 40%))", .match("auto"), "4pt", .all)
        test("abc\n= a head\njoke", .match("\n"), "\nmore\n\n",
             .incr("abc\nmore\n\n= a head\n"))
        test("#show f: a => b..", .end, "c", .all)
        test("#for", .end, "//", .all)
        test("a\n#let \nb", .at(7), "i", .incr("#let i\nb"))
        test("#{{let x = z}; a = 1} b", .at(7), "//", .all)
        test("a ```typst hello```", .range(16..<17), "", .all)
        test("a{b}c", .at(1), "#", .all)
        test("a#{b}c", .match("#"), "", .all)
    }

    /// Test incremental reparsing of code and content blocks.
    @Test func reparseBlockTests() {
        test("Hello #{ x + 1 }!", .match("x"), "abc", .incr("{ abc + 1 }"))
        test("A#{}!", .after("{"), "\"", .all)
        test("#{ [= x] }!", .after("="), "=", .incr("== x"))
        test("#[[]]", .at(3), "\\", .incr("[[\\]]"))
        test("#[[ab]]", .match("b"), "\\", .incr("[[a\\]]"))
        test("#{}}", .after("{"), "{", .all)
        test("A: #[BC]", .after("B"), "{", .incr("B{C"))
        test("A: #[BC]", .after("B"), "#{", .incr("B#{C"))
        test("A: #[BC]", .after("B"), "#{}", .incr("B#{}C"))
        test("#{\"ab\"}A", .at(5), "c", .incr("{\"abc\"}"))
        test("#{\"ab\"}A", .range(5..<6), "c", .all)
        test("a#[]b", .after("["), "#{", .incr("[#{]"))
        test("a#{call(); abc}b", .at(8), "[]", .incr("{call([]); abc}"))
        test("a #while x {\n g(x) \n}  b", .after("{"), "//",
             .incr("{//\n g(x) \n}"))
        test("a#[]b", .after("["), "[hey]", .incr("[[hey]]"))
    }

    /// Test unclosed strings/blocks in embedded code.
    @Test func reparseUnclosedEmbedded() {
        test("#\"a\nb\nc", .end, "\"", .all)
        test("#return \"a\nb\nc", .end, "\"", .all)
        test("#import \"@preview/pkg", .end, "\"", .all)
        test("#import [a\nb\nc", .end, "]", .all)
        test("#import $a\nb\nc", .end, "$", .all)
        test("#set thing\"a\n", .end, "\"", .all)
        test("#let x = \"a\nb\nc", .end, "\"", .all)
        test("#let x = {\"a\nb\nc}", .after("c"), "\"",
             .incr("{\"a\nb\nc\"}"))
        test("#if x {\"a\nb\nc", .end, "\"", .all)
        test("#if x \"a\nb\nc", .end, "\"", .all)
        test("#if x \"a\nb\nc", .after("x "), "{}", .all)
        test("#if x $a\nb\nc", .end, "$", .all)
        test("#for x in \"a\nb\nc", .end, "\"", .all)
        test("#for x \"a\nb\nc", .after("x "), "in ", .all)
    }

    /// Test basic reparsing correctness when modifying, inserting, or
    /// removing syntax warnings.
    @Test func reparseSyntaxWarnings() {
        test("*strong*", .match("strong"), "", .all)
        test("**", .at(1), "strong", .all)
        test("**", .at(1), "__", .all)
        test("```warn--empty```", .match("warn-"), "still", .all)
        test("```yes-empty```", .match("yes-"), "not ", .all)
    }

    /// Test reparsing with deeply nested code and markup blocks.
    ///
    /// FUTURE: Above `n == 127`, normal parsing hits the max parsing depth,
    /// but reparsing doesn't since we don't track the depth anywhere right
    /// now. This is a bug (it yields different trees when reparsing), but it
    /// will require a bit more effort to solve.
    @Test func reparseNestedCode() {
        var text = "#{A;B}"
        var prevN = 1
        // Values chosen mostly arbitrarily, but some had interesting span
        // numbering differences when originally experimenting.
        for n in [10, 19, 20, 21, 22, 30, 50, 51, 62, 63, 100, 127] {
            for _ in prevN..<n {
                text.insert("{", at: text.index(text.startIndex, offsetBy: 1))
                text.append("}")
            }
            prevN = n

            // Decrease the number of nodes:
            test(text, .match(";"), "1", .incr("{A1B}"))
            test(text, .match("A;B"), "2", .incr("{2}"))

            // Leave the number of nodes the same:
            test(text, .match("A;B"), "A;B", .incr("{A;B}"))
            test(text, .match("A;B"), "B;C", .incr("{B;C}"))
            test(text, .match(";"), "+", .incr("{A+B}"))
            test(text, .after("A"), "3", .incr("{A3;B}"))

            // Increase the number of nodes:
            test(text, .after("A"), ";5", .incr("{A;5;B}"))
            test(text, .at(n + 3), "6;", .incr("{A;6;B}"))
        }
    }

    /// Test reparsing with deeply nested markup blocks.
    @Test func reparseNestedMarkup() {
        var text = "#[ A~B ]"
        var prevN = 1
        for n in [10, 19, 20, 21, 22, 30, 50, 51, 62, 63, 100, 127] {
            for _ in prevN..<n {
                text.insert(contentsOf: "#[", at: text.startIndex)
                text.append("]")
            }
            prevN = n

            // Decrease the number of nodes:
            test(text, .match("~"), "1", .incr(" A1B "))
            test(text, .match("A~B"), "2", .incr(" 2 "))

            // Leave the number of nodes the same:
            test(text, .match("A~B"), "A~B", .incr(" A~B "))
            test(text, .match("A~B"), "3~B", .incr(" 3~B "))
            test(text, .after("A"), "3", .incr(" A3~B "))

            // Increase the number of nodes:
            test(text, .after("A"), "~4", .incr(" A~4~B "))
            test(text, .at(2 * n + 3), "5~", .incr(" A~5~B "))
        }
    }

    /// Don't incrementally reparse ranges inside a syntax warning.
    @Test func reparseWithinWarnings() {
        // We build a custom tree with a warning since we don't currently
        // produce any syntax warnings that would trigger this bug.
        let text = "#[nor~mal] #[warn~ing]"
        let root = parse(text)

        let rootInner = root.reparseInnerNodeMut()!.inner
        let secondBlock = rootInner.children[4]
        #expect(secondBlock.fullText() == "[warn~ing]")
        // Note how the warning message can include text from within the node
        // arbitrarily. This is the primary reason reparsing within warnings
        // is unsound: there's no way to know how to update the message/hints!
        secondBlock.warnAt(5..<6, "tilde between `warn` and `ing`: `~`")
        // We have to update the parent's diagnosis due to the new warning.
        let warningDiagnosis = Diagnosis(errors: false, warnings: true)
        // `{new,prev}_{len,desc}` are 0 since only their difference matters.
        rootInner.updateParent(
            prevLen: 0, newLen: 0, prevDesc: 0, newDesc: 0,
            prevDiag: Diagnosis(), newDiag: warningDiagnosis
        )
        #expect(root.diagnosis.warnings)

        // Assign initial span numbers so we can properly reparse.
        let id = FileId.newForTest("reparse_within_warnings")
        try! root.numberize(id: id, within: Span.FULL)
        var source = Source(id: id, text: text, root: root)

        // First we edit and reparse `nor~mal` into `normal`. The reparsed
        // range should stay within the content block.
        let replaced = Edit.match("r~m").intoRange(source.text)
        let replaceWith = "rm"
        let reparsed = source.edit(replaced, with: replaceWith)
        #expect(byteSlice(source.text, reparsed) == "normal")
        // Reparsing `normal` should not affect the warning:
        #expect(source.root.diagnosis.warnings)

        // Then we edit and reparse `warn~ing` into `warning`. Even though the
        // edit is fully inside the warned content block, the reparsed range
        // should expand to the outer code block since we can't soundly
        // reparse within warnings.
        let replaced2 = Edit.match("n~i").intoRange(source.text)
        let reparsed2 = source.edit(replaced2, with: "ni")
        #expect(byteSlice(source.text, reparsed2) == "#[normal] #[warning]")
        #expect(!source.root.diagnosis.warnings)
    }
}
