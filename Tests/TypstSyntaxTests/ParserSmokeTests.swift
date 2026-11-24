import Testing
@testable import TypstSyntax

/// Smoke tests for the ported lexer/parser. These verify lossless round-trips
/// and basic tree shapes; fuller parity comes from the upstream suite port.
@Suite("Parser smoke tests")
struct ParserSmokeTests {
    /// The parsed tree must reproduce the source text exactly (lossless CST).
    private func assertRoundTrip(_ source: String, _ root: SyntaxNode) {
        #expect(root.fullText() == source,
                "lossless round-trip failed: \(source)")
    }

    @Test func markupRoundTrips() {
        let samples = [
            "Hello *world*!",
            "= Heading\n\nSome _emph_ and `raw`.",
            "- item one\n- item two\n  - nested\n+ enum\n/ Term: def",
            "Text with #let x = 1; #x + 2 and $a^2 + b$.\n\nNew para.",
            "@label and #link(\"https://a.b\") and <lbl>.",
            "// comment\n/* block */ Text \\u{1F600} ~ -- ...",
            "#table(columns: 2, [a], [b])\n#grid([x])",
            "#let f(x, y: 1) = x + y\n#f(1, y: 2)",
            "#if true [yes] else [no]",
            "#for i in range(3) [#i]",
            "#while false []",
            "#import \"foo.typ\": a, b as c\n#include \"bar.typ\"",
            "#show heading: it => emph(it.body)",
            "#set text(fill: red)\n#set heading(numbering: \"1.\")",
            "#context text.lang\n#(1 + 2) * 3",
            "{ let x = { nested: 1 }; x.nested }",
            "#(a: 1, b: 2)\n#(1, 2, 3)\n#(..args)",
            "$ x^2 + y_1 = z $ and $ sum_(i=1)^n i $",
            "$ f(x; y: #2) $",
            "#let (a, b) = (1, 2)\n#let (x, ..rest) = (1, 2, 3)",
            "unclosed *star and [bracket",
            "#\"unterminated",
            "$x +",
        ]
        for sample in samples {
            assertRoundTrip(sample, parse(sample))
        }
    }

    @Test func markupStructure() {
        let root = parse("= Title\n\nHello *bold* and _em_.")
        #expect(root.kind == .markup)
        #expect(root.errorsAndWarnings().errors.isEmpty)
        let kinds = root.children.map(\.kind)
        #expect(kinds.contains(.heading))
        #expect(kinds.contains(.strong))
        #expect(kinds.contains(.emph))
    }

    @Test func codeStructure() {
        let root = parseCode("let x = 1 + 2 * 3\nf(x: 1, ..rest)")
        #expect(root.kind == .code)
        #expect(root.errorsAndWarnings().errors.isEmpty)
        #expect(root.children.contains { $0.kind == .letBinding })
        #expect(root.children.contains { $0.kind == .funcCall })
    }

    @Test func mathStructure() {
        let root = parseMath("x^2 + frac(a, b) + sqrt(x)")
        #expect(root.kind == .math)
        #expect(root.errorsAndWarnings().errors.isEmpty)
    }

    @Test func errorsAreCollected() {
        let root = parse("#let = 5")
        #expect(!root.errorsAndWarnings().errors.isEmpty)
    }

    @Test func emptyInput() {
        let root = parse("")
        #expect(root.kind == .markup)
    }
}
