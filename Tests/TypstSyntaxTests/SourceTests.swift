import Testing
@testable import TypstSyntax

/// Ports of the `Source` tests in `source.rs` and the `LinkedNode` /
/// `mode_after` tests in `node.rs` / `kind.rs`.
@Suite("Source")
struct SourceTests {
    /// Byte-slice a string (like Rust's `&text[range]`).
    private func slice(_ s: String, _ r: Range<Int>) -> String {
        String(decoding: Array(s.utf8)[r], as: UTF8.self)
    }

    @Test func sourceSubRanges() {
        let testId = FileId.newForTest("test_source_sub_ranges")
        let text = "= head <label>"
        let source = Source(id: testId, text: text)

        func get(_ span: Span, _ subRange: SubRange?) -> String {
            let num = SpanNumber(span.number)
            return slice(text, source.range(num: num, subRange: subRange)!)
        }

        let head = LinkedNode(root: source.root)
            .leafAt(2, side: .after)!.span
        #expect(get(head, nil) == "head")
        #expect(get(head, SubRange(1, 3)) == "ea")
        #expect(get(head, SubRange(0, 1)) == "h")
        #expect(get(head, SubRange(0, 4)) == "head")
        #expect(get(head, SubRange(3, 4)) == "d")
        let root = source.root.span
        #expect(get(root, nil) == text)
        #expect(get(root, SubRange(3, 10)) == "ead <la")
        #expect(get(root, SubRange(0, 10)) == "= head <la")
        #expect(get(root, SubRange(3, 14)) == "ead <label>")
    }

    @Test func linkedNode() {
        let testId = FileId.newForTest("test_linked_node")
        let source = Source(id: testId, text: "#set text(12pt, red)")

        // Find "text" with Before.
        let node = LinkedNode(root: source.root)
            .leafAt(7, side: .before)!
        #expect(node.offset == 5)
        #expect(node.leafText == "text")

        // Find "text" with After.
        let nodeAfter = LinkedNode(root: source.root)
            .leafAt(7, side: .after)!
        #expect(nodeAfter.offset == 5)
        #expect(nodeAfter.leafText == "text")

        // Go back to "#set". Skips the space.
        let prev = nodeAfter.prevSibling()!
        #expect(prev.offset == 1)
        #expect(prev.leafText == "set")
    }

    @Test func linkedNodeNonTriviaLeaf() {
        let testId = FileId.newForTest("test_linked_node_non_trivia_leaf")
        let source = Source(id: testId, text: "#set fun(12pt, red)")
        let leaf = LinkedNode(root: source.root)
            .leafAt(6, side: .before)!
        let prev = leaf.prevLeaf()!
        #expect(leaf.leafText == "fun")
        #expect(prev.leafText == "set")

        // Check position 9 with Before.
        let source2 = Source(id: testId, text: "#let x = 10")
        let leaf2 = LinkedNode(root: source2.root)
            .leafAt(9, side: .before)!
        let prev2 = leaf2.prevLeaf()!
        let next2 = leaf2.nextLeaf()!
        #expect(prev2.leafText == "=")
        #expect(leaf2.leafText == " ")
        #expect(next2.leafText == "10")

        // Check position 9 with After.
        let leaf3 = LinkedNode(root: source2.root)
            .leafAt(9, side: .after)!
        let prev3 = leaf3.prevLeaf()!
        #expect(leaf3.nextLeaf() == nil)
        #expect(prev3.leafText == "=")
        #expect(leaf3.leafText == "10")
    }

    /// Port of `test_mode` / `test_mode_after` from `kind.rs`.
    @Test func modeAfter() {
        func testMode(_ text: String, _ cursors: [Int],
                      _ expected: SyntaxMode?) {
            let source = Source(id: FileId.newForTest("test_mode"), text: text)
            let root = LinkedNode(root: source.root)
            for cursor in cursors {
                let leaf = root.leafAt(cursor, side: .after)!
                let bytes = Array(text.utf8)
                let c = cursor < bytes.count
                    ? String(decoding: [bytes[cursor]], as: UTF8.self)
                    : "?"
                #expect(leaf.modeAfter() == expected,
                        "different at '\(c)' index \(cursor)")
            }
        }

        // Trivia
        testMode("#! typ", [0, 1, 2, 3], nil)
        testMode("#! typ\n", [6], .markup)
        testMode("// xxx", [0, 1, 2, 3], nil)
        testMode("\n// xxx\n", [0, 7], .markup)
        testMode("/* xxx */", [0, 1, 2, 3, 4, 7, 8], nil)

        // Syntax errors
        testMode("*/", [0, 1], .markup)
        testMode("#{*/}", [2, 3], .code)
        testMode("$*/$", [1, 2], .math)

        // Markup
        testMode("https://typst.org", [0], .markup)
        testMode("a\\bcd", [0, 1, 2, 3], .markup)
        testMode("a   c\n\n d\\\nef", [1, 5, 9], .markup)
        testMode("\\u{41}", [0, 1, 2, 3, 5], .markup)
        testMode("\"abc\"", [0, 1, 4], .markup)
        testMode("a-?b", [1, 2], .markup)
        testMode("_*abcd*_", [0, 1, 6, 7], .markup)
        testMode("<label>", [0, 1], .markup)
        testMode("@label[x @y]", [0, 1, 6, 7, 8, 9, 11], .markup)
        testMode("= marker", [0, 1, 2], .markup)
        testMode("- marker", [0, 1, 2], .markup)
        testMode("+ marker", [0, 1, 2], .markup)
        testMode("/ marker: y", [0, 1, 2, 8, 9, 10], .markup)

        // Basic code
        testMode("#{x;1}", [0, 1, 2, 3, 4], .code)
        testMode("#(x)", [1, 2, 3], .code)
        testMode("#(1,2,)", [1, 2, 3, 5, 6], .code)
        testMode("#(a:1,\"b\":2)", [1, 2, 3, 4, 5, 6, 7, 8, 9, 11], .code)
        testMode("#{-x}", [2], .code)
        testMode("#{a / b}", [4], .code)
        testMode("#a.b", [1, 2, 3], .code)
        testMode("#$$.at()", [2, 3], .code)
        testMode("#[].at()", [2, 3], .code)
        testMode("#f(x, ..y)", [2, 4, 6], .code)
        testMode("#{(x) => {}}", [3, 6], .code)
        testMode("#let x = 1", [1, 7], .code)
        testMode("#let x;", [6], .markup) // After semicolon is the parent
        testMode("#set text()", [1, 4], .code)
        testMode("#show text : it => it", [1, 11], .code)
        testMode("#context 1", [1, 8], .code)
        testMode("#while true {break;continue;}", [1, 13, 19], .code)
        testMode("#for a in b {}", [1, 7], .code)
        testMode("#if true {} else {}", [1, 12], .code)
        testMode("#import \"lib.typ\" : a, b as d, e.f",
                 [2, 8, 21, 25, 32], .code)
        testMode("#include \"lib.typ\"", [1], .code)
        testMode("#let f() = { return 1 }", [13], .code)
        testMode("#{(x, _, ..y) = (1, 2, ..z)}", [2, 14], .code)
        testMode("= #1.1", [2, 3], .code)

        // Math
        testMode("$$", [0], .math) // Opening dollar is math
        testMode("$$", [1], .markup) // Closing dollar is parent
        testMode("#$$", [2], .code) // Closing dollar is parent
        testMode("$ a b $", [1, 3, 5], .math) // Just the spaces
        testMode("$\na\nb\n$", [1, 3, 5], .math) // Just the newlines
        testMode("$arrow$", [1], .math)
        testMode("$123.32$", [1, 2, 4, 5], .math)
        testMode("$+12 * y!", [1, 5, 8], .math)
        testMode("$1/2$", [2], .math)
        testMode("$f''$", [2], .math)
        testMode("$f_(x)^y$", [2, 3, 6, 7], .math)
        testMode("$a>=b$", [2], .math)
        testMode("$√x$", [1, 4], .math)
        testMode("$&x$", [1], .math)
        testMode("$\\#\\u{41}$", [1, 2, 3, 4, 5, 6], .math)
        testMode("$ff(x, sin(y), abs(z))$", [3, 4, 5, 7, 10, 15, 18], .math)
        testMode("$ff(..args, named: key)$", [4, 6, 16, 17], .math)
        testMode("$arrow.r$", [6], .math)

        // Raw text
        testMode("`r`", [0, 1], nil)
        testMode("`r`", [2], .markup)
        testMode("` \n r\n `", [1, 2, 3, 4, 5, 6], nil)
        testMode("#`r`", [1, 2], nil)
        testMode("#`r`", [3], .code)
        testMode("```l r\n```", [7], .markup)
        testMode("```l r\n```", [0, 3, 4, 5, 6], nil)
        testMode("#```l r\n```", [8], .code)
        testMode("#```l r\n```", [1, 4, 5, 6, 7], nil)

        // Edge cases with embedded code expressions
        testMode("#<l>", [1, 2, 3], .code)
        testMode("$#pa$", [2, 3], .code)
        testMode("$#{x}$", [2], .code)
        testMode("$#[x]$", [1, 4], .code)
        testMode("$#[x]$", [2, 3], .markup)
        testMode("$#f(x, ..args, named: key)$", [3, 4, 5, 7, 9, 19, 20], .code)
        testMode("$#context 1$", [9, 10], .code)
        testMode("$#context $", [9], .code)
        testMode("$#std.align$", [2, 5, 6], .code)
        testMode("$ff(named: #ident)$", [12], .code)
        testMode("$ #$x$; $", [0, 1, 3, 4, 6, 7], .math)
        testMode("$ #$x$; $", [8], .markup)
        testMode("$ #$x$; $", [2, 5], .code)
        testMode("#[$x$]", [2, 3], .math)
        testMode("#[$x$]", [1, 4], .markup)

        // Single newlines at the edges of modes
        // (since the other tests mostly use normal spaces instead of newlines)
        testMode("#[\n$\n#{\nx\n}\n$\n]", [2, 13], .markup)
        testMode("#[\n$\n#{\nx\n}\n$\n]", [4, 11], .math)
        testMode("#[\n$\n#{\nx\n}\n$\n]", [7, 9], .code)
    }
}
