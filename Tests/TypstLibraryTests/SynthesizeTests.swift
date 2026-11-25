import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for the `Synthesize` capability impls — heading/figure/caption
/// field synthesis (`model/heading.rs`/`model/figure.rs` synthesize
/// bodies), `Supplement.resolve`, and `Content.queryFirstNaive`.
@Suite("Synthesize")
struct SynthesizeTests {
    private func loc(_ n: Int) -> Location {
        Location(hash: Hash128(high: 0, low: UInt64(n)))
    }

    private let flags = TagFlags(introspectable: true, tagged: false)

    private func introspector(_ contents: [Content]) -> TestIntrospector {
        var b = ElementIntrospectorBuilder<Int>()
        for (i, e) in contents.enumerated() {
            let location = e.location ?? loc(1000 + i)
            var tagged = e
            tagged.location = location
            b.discoverTag(.start(tagged, flags), position: i)
            b.discoverTag(.end(location,
                                Hash128(high: 0, low: UInt64(100 + i)),
                                flags), position: i)
        }
        return TestIntrospector(inner: b.finalize())
    }

    // MARK: - Supplement.resolve

    @Test func supplementResolveContent() throws {
        let supp = Supplement.content(TextElem.packed("lit"))
        var h = FuncHarness()
        let resolved = try supp.resolve(
            engine: &h.engine, styles: StyleChain(), args: []).get()
        #expect(resolved.plainText.contains("lit"))
    }

    @Test func supplementResolveFunc() throws {
        // Function supplements are called with the target; display of the
        // result becomes the content.
        let f = Func(native: nativeFunc(
            "supp",
            params: [
                NativeParamInfo(name: "target", input: Content.input,
                                required: true),
            ]
        ) { _, _, args in
            let target: Content = try args.expectT("target")
            try args.finishT()
            return Value.int(Int64(target.plainText.count))
        })
        var h = FuncHarness()
        let resolved = try Supplement.function(f).resolve(
            engine: &h.engine, styles: StyleChain(),
            args: [TextElem.packed("abc").intoValue()]).get()
        // Int 3 displays as text content "3".
        #expect(resolved.plainText.contains("3"))
    }

    private func tableContent() throws -> Content {
        let node = parse("#table[a]")
        guard let markupNode = node.cast(Markup.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "test harness: expected markup"))
        }
        let world = MockWorld()
        let engine = Engine(world: world)
        var vm = Vm(engine: engine, context: Context(),
                    scopes: Scopes(base: world.library.value.scope),
                    inspected: nil)
        return try markupNode.eval(&vm)
    }

    private func nestedTable() throws -> Content {
        let evaluated = try tableContent()
        if let seq = evaluated.packed.element as? SequenceElem,
           let first = seq.children.first {
            return first
        }
        return evaluated
    }

    // MARK: - queryFirstNaive

    @Test func queryFirstNaiveNested() throws {
        let table = try nestedTable()
        let nested = Content.sequence([
            TextElem.packed("a"),
            Content.sequence([table]),
        ])
        let found = nested.queryFirstNaive {
            $0.packed.element is any Figurable
        }
        #expect(found?.packed.element is TableElem)
        // No match → nil.
        #expect(TextElem.packed("x").queryFirstNaive({
            $0.packed.element is any Figurable
        }) == nil)
    }

    // MARK: - Heading synthesize

    @Test func headingSynthesizeAutoSupplement() throws {
        var h = FuncHarness()
        var heading = HeadingElem(body: TextElem.packed("x"))
        try heading.synthesize(
            engine: &h.engine, styles: StyleChain(), location: nil)
        // Auto supplement → localized "Section".
        guard case let .custom(.some(.content(supp))) = heading.supplement.value
        else {
            Issue.record("expected custom content supplement")
            return
        }
        #expect(supp.plainText.contains("Section"))
        // Level resolved: default depth 1 → level 1.
        #expect(heading.level == .custom(1))
    }

    @Test func headingSynthesizeCustomSupplement() throws {
        var h = FuncHarness()
        var heading = HeadingElem(body: TextElem.packed("x"))
        heading.supplement = Spanned(
            .custom(.content(TextElem.packed("Kapittel"))), span: .detached)
        try heading.synthesize(
            engine: &h.engine, styles: StyleChain(), location: nil)
        guard case let .custom(.some(.content(supp))) = heading.supplement.value
        else {
            Issue.record("expected content supplement")
            return
        }
        #expect(supp.plainText.contains("Kapittel"))
    }

    @Test func headingSynthesizeNumbers() throws {
        var heading = HeadingElem(body: TextElem.packed("x"))
        heading.numbering = .pattern(try! NumberingPattern(parsing: "1"))
        let location = loc(10)
        var located = heading.pack()
        located.location = location
        var h = FuncHarness()
        h.engine.introspector = introspector([located])
        try heading.synthesize(
            engine: &h.engine, styles: StyleChain(), location: location)
        // Initial counter state [0] + no step yet → displays "0" —
        // but the key assertion is that *some* numbers were synthesized.
        #expect(!heading.numbers.value.isEmpty)
    }

    @Test func headingSynthesizeUnnumberedNoNumbers() throws {
        var h = FuncHarness()
        var heading = HeadingElem(body: TextElem.packed("x"))
        try heading.synthesize(
            engine: &h.engine, styles: StyleChain(), location: loc(10))
        #expect(heading.numbers.value.isEmpty)
    }

    // MARK: - Figure synthesize

    @Test func figureSynthesizeTableKind() throws {
        var h = FuncHarness()
        var fig = FigureElem(body: try nestedTable())
        fig.caption = FigureCaption(body: TextElem.packed("cap"))
        try fig.synthesize(
            engine: &h.engine, styles: StyleChain(), location: loc(5))
        // Kind detected from the table body.
        guard case let .custom(.elem(kindElem)) = fig.kind else {
            Issue.record("expected elem kind"); return
        }
        #expect(kindElem == Element(TableElem.self))
        // Auto supplement → local name of the kind.
        guard case let .custom(.some(.content(supp))) = fig.supplement else {
            Issue.record("expected content supplement"); return
        }
        #expect(supp.plainText.contains("Table"))
        // Counter synthesized.
        #expect(fig.counter != nil)
        // Caption filled.
        #expect(fig.caption?.kind != nil)
        #expect(fig.caption?.counter != nil)
        #expect(fig.caption?.figureLocation == loc(5))
        #expect(fig.caption?.numbering != nil)
    }

    @Test func figureSynthesizeNoFigurableFallback() throws {
        var h = FuncHarness()
        var fig = FigureElem(body: TextElem.packed("plain"))
        try fig.synthesize(
            engine: &h.engine, styles: StyleChain(), location: nil)
        // No figurable descendant → Name("image") fallback until
        // ImageElem lands.
        guard case let .custom(.name(name)) = fig.kind else {
            Issue.record("expected name kind"); return
        }
        #expect(name.value == "image")
    }

    @Test func figureSynthesizeNumberedUnnamedKindErrors() throws {
        // Custom-name kinds have no local name; numbered figures then
        // require an explicit supplement.
        var h = FuncHarness()
        var fig = FigureElem(body: TextElem.packed("x"))
        fig.kind = .custom(.name(Str("custom")))
        #expect(throws: (any Error).self) {
            try fig.synthesize(
                engine: &h.engine, styles: StyleChain(), location: nil)
        }
    }

    @Test func figureSynthesizeUnnumberedUnnamedOk() throws {
        var h = FuncHarness()
        var fig = FigureElem(body: TextElem.packed("x"))
        fig.kind = .custom(.name(Str("custom")))
        fig.numbering = nil
        try fig.synthesize(
            engine: &h.engine, styles: StyleChain(), location: nil)
        // Empty supplement, no error.
        guard case let .custom(.some(.content(supp))) = fig.supplement else {
            Issue.record("expected empty content supplement"); return
        }
        #expect(supp.isEmpty)
    }

    @Test func figureCaptionSynthesizeSeparator() throws {
        var h = FuncHarness()
        var caption = FigureCaption(body: TextElem.packed("c"))
        try caption.synthesize(
            engine: &h.engine, styles: StyleChain(), location: nil)
        guard case let .custom(sep) = caption.separator else {
            Issue.record("expected custom separator"); return
        }
        #expect(sep.plainText.contains(":"))
    }

    // MARK: - Content-driven synthesis

    @Test func contentSynthesizeElement() throws {
        // The Content-level entry point passes the location through.
        var h = FuncHarness()
        var content = HeadingElem(body: TextElem.packed("x")).pack()
        content.location = loc(7)
        try content.synthesizeElement(
            engine: &h.engine, styles: StyleChain())
        guard let heading = content.to(HeadingElem.self) else {
            Issue.record("expected heading"); return
        }
        #expect(heading.level == .custom(1))
    }
}
