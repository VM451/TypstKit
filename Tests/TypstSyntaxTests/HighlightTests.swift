import Testing
@testable import TypstSyntax

/// Port of upstream `highlight.rs::tests::test_highlighting`.
@Suite("Highlight")
struct HighlightTests {
    /// Collect `(range, tag)` pairs for every highlighted node.
    private func highlightTree(
        _ tags: inout [(Range<Int>, HighlightTag)],
        _ node: LinkedNode
    ) {
        if let tag = highlight(node) {
            tags.append((node.range(), tag))
        }
        for child in node.children() {
            highlightTree(&tags, child)
        }
    }

    private func test(_ text: String, _ goal: [(Range<Int>, HighlightTag)]) {
        var vec: [(Range<Int>, HighlightTag)] = []
        let root = parse(text)
        highlightTree(&vec, LinkedNode(root: root))
        #expect(vec.count == goal.count)
        #expect(zip(vec, goal).allSatisfy { $0 == $1 })
    }

    @Test func highlighting() {
        test("= *AB*", [(0..<6, HighlightTag.heading), (2..<6, HighlightTag.strong)])

        test("#f(x + 1)", [
            (0..<1, HighlightTag.function),
            (1..<2, HighlightTag.function),
            (2..<3, HighlightTag.punctuation),
            (5..<6, HighlightTag.`operator`),
            (7..<8, HighlightTag.number),
            (8..<9, HighlightTag.punctuation),
        ])

        test("#let f(x) = x", [
            (0..<1, HighlightTag.keyword),
            (1..<4, HighlightTag.keyword),
            (5..<6, HighlightTag.function),
            (6..<7, HighlightTag.punctuation),
            (8..<9, HighlightTag.punctuation),
            (10..<11, HighlightTag.`operator`),
        ])
    }

    @Test func highlightHTMLOutput() {
        let root = parse("#let x = 1")
        let html = highlightHTML(root)
        #expect(html.hasPrefix("<code>"))
        #expect(html.hasSuffix("</code>"))
        #expect(html.contains("typ-key"))
    }
}
