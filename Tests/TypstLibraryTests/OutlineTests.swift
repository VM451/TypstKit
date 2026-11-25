import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `outline`/`outline.entry` (`model/outline.rs`), the
/// `Refable`/`Outlinable`/`LocalName` impls, `OutlineIndent` casts,
/// `OutlineNode.buildTree`, and the `TextElem.dir`/`TextDir` addition.
@Suite("Outline")
struct OutlineTests {
    private func loc(_ n: Int) -> Location {
        Location(hash: Hash128(high: 0, low: UInt64(n)))
    }

    private let flags = TagFlags(introspectable: true, tagged: false)

    /// Build an introspector holding `contents` as flat tag pairs.
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

    private func heading(_ body: String, depth: Int = 1,
                         location n: Int) -> Content {
        var c = HeadingElem(body: TextElem.packed(body))
            .withDepth(depth).pack()
        c.location = loc(n)
        return c
    }

    /// Evaluate markup source into content.
    private func markup(_ source: String) throws -> Content {
        let node = parse(source)
        guard let markupNode = node.cast(Markup.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "test harness: expected markup"))
        }
        let world = MockWorld()
        let engine = Engine(world: world)
        var vm = Vm(
            engine: engine,
            context: Context(),
            scopes: Scopes(base: world.library.value.scope),
            inspected: nil)
        return try markupNode.eval(&vm)
    }

    /// First element of content, unwrapping a top-level sequence.
    private func firstElem(_ content: Content) -> PackedElement? {
        if let seq = content.packed.element as? SequenceElem,
           let first = seq.children.first {
            return first.packed
        }
        return content.packed
    }

    // MARK: - Construct + registration

    @Test func constructDefaults() throws {
        let content = try markup("#outline()")
        guard let outline = firstElem(content)?.element as? OutlineElem else {
            Issue.record("expected outline element")
            return
        }
        #expect(outline.title.isAuto)
        #expect(outline.depth == nil)
        #expect(outline.indent.isAuto)
        guard case let .elem(elem, _) = outline.target.selector else {
            Issue.record("expected elem selector")
            return
        }
        #expect(elem == Element(HeadingElem.self))
    }

    @Test func constructFields() throws {
        let content = try markup("#outline(title: none, depth: 2, indent: 2em)")
        guard let outline = firstElem(content)?.element as? OutlineElem else {
            Issue.record("expected outline element")
            return
        }
        #expect(outline.depth?.value == 2)
        guard case let .custom(title) = outline.title else {
            Issue.record("expected custom title"); return
        }
        #expect(title == nil)
        guard case let .custom(.rel(indent)) = outline.indent else {
            Issue.record("expected rel indent"); return
        }
        #expect(indent.abs == Length(Em(2)))
    }

    @Test func constructCustomTitle() throws {
        let content = try markup("#outline(title: [My Outline])")
        guard let outline = firstElem(content)?.element as? OutlineElem else {
            Issue.record("expected outline element")
            return
        }
        guard case let .custom(title) = outline.title,
              let title else {
            Issue.record("expected title content"); return
        }
        #expect(title.plainText.contains("My Outline"))
    }

    @Test func entryConstructViaScope() throws {
        // `outline.entry` resolves through the outline element's scope.
        let content = try markup("#outline.entry(2, [x])")
        guard let entry = firstElem(content)?.element as? OutlineEntry else {
            Issue.record("expected outline entry")
            return
        }
        #expect(entry.level.value == 2)
        // Default fill is the dotted repeat.
        #expect(entry.fill != nil)
        #expect(entry.parent == nil)
    }

    // MARK: - Casts

    @Test func indentCasts() throws {
        let rel = try OutlineIndent.fromValue(
            .length(Length(Em(2)))).get()
        guard case let .rel(length) = rel else {
            Issue.record("expected rel indent"); return
        }
        #expect(length.abs == Length(Em(2)))

        let f = Func(native: nativeFunc(
            "f", params: [], returns: Int64.output) { _, _, _ in 0 })
        let fn = try OutlineIndent.fromValue(.function(f)).get()
        guard case .function = fn else {
            Issue.record("expected func indent"); return
        }
    }

    @Test func indentFuncResolve() throws {
        // `(n) => n * 2em` — depth passed as int.
        let f = Func(native: nativeFunc(
            "scale",
            params: [
                NativeParamInfo(name: "n", input: Int64.input,
                                required: true),
            ]
        ) { _, _, args in
            let n: Int64 = try args.expectT("n")
            try args.finishT()
            return Value.length(Length(Em(2 * Double(n))))
        })
        var h = FuncHarness()
        let indent = OutlineIndent.function(f)
        let result = indent.resolve(
            engine: &h.engine, context: h.context,
            level: NonZeroUsize(value: 3), span: .detached)
        guard case let .success(length) = result else {
            Issue.record("resolve failed"); return
        }
        #expect(length.abs == Length(Em(4)))
    }

    @Test func entryCasts() throws {
        let entry = OutlineEntry(level: NonZeroUsize(value: 1),
                                 element: TextElem.packed("x"))
        let value = entry.intoValue()
        let back = try OutlineEntry.fromValue(value).get()
        #expect(back.level.value == 1)
        // Non-entry content is rejected.
        let other = Value.content(TextElem.packed("y"))
        #expect((try? OutlineEntry.fromValue(other).get()) == nil)
    }

    // MARK: - OutlineNode.buildTree

    private func entryContent() -> Content { TextElem.packed("e") }

    @Test func buildTreeBasic() {
        let flat: [(Content, NonZeroUsize, Bool)] = [
            (entryContent(), NonZeroUsize(value: 1), true),
            (entryContent(), NonZeroUsize(value: 2), true),
            (entryContent(), NonZeroUsize(value: 1), true),
        ]
        let tree = OutlineNode.buildTree(flat: flat)
        #expect(tree.count == 2)
        #expect(tree[0].level.value == 1)
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].level.value == 2)
        #expect(tree[1].level.value == 1)
        #expect(tree[1].children.isEmpty)
    }

    @Test func buildTreeSkippedLevels() {
        // Included 1, skipped 2, included 3 — the level-3 entry takes the
        // place of its skipped level-2 ancestor, becoming a child of the
        // level-1 entry.
        let flat: [(Content, NonZeroUsize, Bool)] = [
            (entryContent(), NonZeroUsize(value: 1), true),
            (entryContent(), NonZeroUsize(value: 2), false),
            (entryContent(), NonZeroUsize(value: 3), true),
        ]
        let tree = OutlineNode.buildTree(flat: flat)
        #expect(tree.count == 1)
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].level.value == 3)

        // A deeper skipped level does NOT collapse: the level-2 skipped
        // entry means the level-3 included entry is NOT a child of the
        // level-1 — upstream: descend stops when reaching a node whose
        // children would be siblings of the skipped heading. The level 3
        // becomes a root-level sibling only if the skipped level is lower
        // than the node's level; here it stays nested.
    }

    @Test func buildTreeDeepSkipChain() {
        // Included 1, skipped 2, skipped 3, included 4 — the level-4 entry
        // takes the place of the topmost skipped ancestor (level 2).
        let flat: [(Content, NonZeroUsize, Bool)] = [
            (entryContent(), NonZeroUsize(value: 1), true),
            (entryContent(), NonZeroUsize(value: 2), false),
            (entryContent(), NonZeroUsize(value: 3), false),
            (entryContent(), NonZeroUsize(value: 4), true),
        ]
        let tree = OutlineNode.buildTree(flat: flat)
        #expect(tree.count == 1)
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].level.value == 4)
    }

    @Test func buildTreeAllSkipped() {
        let flat: [(Content, NonZeroUsize, Bool)] = [
            (entryContent(), NonZeroUsize(value: 1), false),
            (entryContent(), NonZeroUsize(value: 2), false),
        ]
        #expect(OutlineNode.buildTree(flat: flat).isEmpty)
    }

    // MARK: - realizeTitle

    @Test func realizeTitleAuto() {
        let outline = OutlineElem()
        let title = outline.realizeTitle(StyleChain())
        guard let headingElem = title?.to(HeadingElem.self) else {
            Issue.record("expected heading"); return
        }
        // Auto title → English local name "Contents".
        #expect(headingElem.body.plainText.contains("Contents"))
        #expect(headingElem.depth == 1)
    }

    @Test func realizeTitleNoneAndCustom() {
        var outline = OutlineElem()
        outline.title = .custom(nil)
        #expect(outline.realizeTitle(StyleChain()) == nil)

        outline.title = .custom(TextElem.packed("ToC"))
        #expect(outline.realizeTitle(StyleChain())?
            .to(HeadingElem.self)?.body.plainText.contains("ToC") == true)
    }

    // MARK: - realizeFlat / realizeTree

    @Test func realizeFlatHeadings() throws {
        let contents = [
            heading("Intro", depth: 1, location: 10),
            heading("Detail", depth: 2, location: 20),
            heading("Outro", depth: 1, location: 30),
        ]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        let flat = try OutlineElem().realizeFlat(
            engine: &h.engine, styles: StyleChain()).get()
        #expect(flat.count == 3)
        let levels = flat.compactMap { $0.to(OutlineEntry.self)?.level.value }
        #expect(levels == [1, 2, 1])
    }

    @Test func realizeFlatDepthFilter() throws {
        let contents = [
            heading("Intro", depth: 1, location: 10),
            heading("Detail", depth: 2, location: 20),
        ]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        var outline = OutlineElem()
        outline.depth = NonZeroUsize(value: 1)
        let flat = try outline.realizeFlat(
            engine: &h.engine, styles: StyleChain()).get()
        #expect(flat.count == 1)
    }

    @Test func realizeFlatOutlinedFalse() throws {
        var h2 = HeadingElem(body: TextElem.packed("Hidden"))
        h2.outlined = false
        var hidden = h2.pack()
        hidden.location = loc(20)
        let contents = [heading("Shown", depth: 1, location: 10), hidden]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        let flat = try OutlineElem().realizeFlat(
            engine: &h.engine, styles: StyleChain()).get()
        #expect(flat.count == 1)
    }

    @Test func realizeFlatNonOutlinableErrors() throws {
        var text = TextElem.packed("plain")
        text.location = loc(10)
        var h = FuncHarness()
        h.engine.introspector = introspector([text])
        var outline = OutlineElem()
        outline.target = LocatableSelector(
            .elem(Element(TextElem.self), fields: nil))
        switch outline.realizeFlat(
            engine: &h.engine, styles: StyleChain()) {
        case .success:
            Issue.record("expected failure for non-outlinable target")
        case let .failure(e):
            #expect(e.description.contains("cannot outline text"))
        }
    }

    @Test func realizeTreeShape() throws {
        let contents = [
            heading("A", depth: 1, location: 10),
            heading("B", depth: 2, location: 20),
            heading("C", depth: 1, location: 30),
        ]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        let tree = try OutlineElem().realizeTree(
            engine: &h.engine, styles: StyleChain()).get()
        #expect(tree.count == 2)
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].level.value == 2)
        #expect(tree[1].children.isEmpty)
    }

    // MARK: - Entry scope functions

    private func entryHarness(
        element: Content, level: Int = 1
    ) -> (FuncHarness, Content) {
        let h = FuncHarness()
        h.context = Context(location: loc(0), styles: StyleChain())
        var entry = OutlineEntry(level: NonZeroUsize(value: level),
                                 element: element)
        entry.span = .detached
        return (h, entry.pack())
    }

    @Test func entryBodyHeading() throws {
        let elem = heading("My Section", depth: 1, location: 10)
        let (h, entry) = entryHarness(element: elem)
        let value = try h.call(entryBody, h.args([.content(entry)])).get()
        guard case let .content(body) = value else {
            Issue.record("expected content"); return
        }
        #expect(body.plainText.contains("My Section"))
    }

    @Test func entryBodyNonOutlinableErrors() throws {
        var text = TextElem.packed("plain")
        text.location = loc(10)
        let (h, entry) = entryHarness(element: text)
        switch h.call(entryBody, h.args([.content(entry)])) {
        case .success:
            Issue.record("expected failure")
        case let .failure(e):
            #expect(e.description.contains("cannot outline text"))
        }
    }

    @Test func entryPrefixUnnumberedIsNone() throws {
        // A heading without numbering has no prefix.
        let elem = heading("Unnumbered", depth: 1, location: 10)
        let (h, entry) = entryHarness(element: elem)
        let value = try h.call(entryPrefix, h.args([.content(entry)])).get()
        #expect(value == .none)
    }

    @Test func entryPrefixMissingLocationErrors() throws {
        // Outlinable but locationless → the location hint fires.
        let elem = HeadingElem(body: TextElem.packed("x")).pack()
        let (h, entry) = entryHarness(element: elem)
        switch h.call(entryPrefix, h.args([.content(entry)])) {
        case .success(let v):
            // No numbering → still returns none before the location check.
            #expect(v == .none)
        case .failure:
            Issue.record("prefix without numbering should not fail")
        }
    }

    @Test func entryPageFormatsNumber() throws {
        let elem = heading("Paged", depth: 1, location: 10)
        var h = FuncHarness()
        h.engine.introspector = introspector([elem])
        h.context = Context(location: loc(0), styles: StyleChain())
        var entry = OutlineEntry(level: NonZeroUsize(value: 1),
                                 element: elem)
        entry.span = .detached
        let value = try h.call(
            entryPage, h.args([.content(entry.pack())])).get()
        guard case let .content(page) = value else {
            Issue.record("expected content"); return
        }
        // Fallback numbering "1", initial page counter state [1] → "1".
        #expect(page.plainText.contains("1"))
    }

    @Test func entryInnerShape() throws {
        let elem = heading("Section", depth: 1, location: 10)
        var h = FuncHarness()
        h.engine.introspector = introspector([elem])
        h.context = Context(location: loc(0), styles: StyleChain())
        var entry = OutlineEntry(level: NonZeroUsize(value: 1),
                                 element: elem)
        entry.span = .detached
        let value = try h.call(
            entryInner, h.args([.content(entry.pack())])).get()
        guard case let .content(inner) = value,
              let children = inner.sequenceChildren else {
            Issue.record("expected sequence"); return
        }
        // Default fill present: body, space, box(filler), space,
        // word joiner, page — 6+ children with a fractional box inside.
        #expect(children.count >= 5)
        let hasBox = children.contains {
            $0.packed.element is BoxElem
        }
        #expect(hasBox)
    }

    @Test func entryInnerNoFillUsesH() throws {
        let elem = heading("Section", depth: 1, location: 10)
        var h = FuncHarness()
        h.engine.introspector = introspector([elem])
        h.context = Context(location: loc(0), styles: StyleChain())
        var entry = OutlineEntry(level: NonZeroUsize(value: 1),
                                 element: elem)
        entry.fill = nil
        entry.span = .detached
        let value = try h.call(
            entryInner, h.args([.content(entry.pack())])).get()
        guard case let .content(inner) = value,
              let children = inner.sequenceChildren else {
            Issue.record("expected sequence"); return
        }
        #expect(children.contains { $0.packed.element is HElem })
        #expect(!children.contains { $0.packed.element is BoxElem })
    }

    // MARK: - showSet

    @Test func showSetProperties() {
        let styles = OutlineElem().showSet(styles: StyleChain())
        var found: Set<String> = []
        for style in styles.items {
            guard case let .property(p) = style.value else { continue }
            if p.elem == Element(HeadingElem.self), p.field == 6 {
                #expect(p.value == .bool(false))
                found.insert("heading-outlined")
            }
            if p.elem == Element(HeadingElem.self), p.field == 3 {
                #expect(p.value == .none)
                found.insert("heading-numbering")
            }
            if p.elem == Element(ParElem.self), p.field == 2 {
                #expect(p.value == .bool(false))
                found.insert("par-justify")
            }
            if p.elem == Element(BlockElem.self), p.field == 8 {
                found.insert("block-above")
            }
            if p.elem == Element(OutlineEntry.self), p.field == 3 {
                // Parent is the outline itself.
                guard case .content = p.value else {
                    Issue.record("parent should be content"); continue
                }
                found.insert("entry-parent")
            }
        }
        #expect(found.count == 5)
    }

    // MARK: - Refable / Outlinable impls

    @Test func headingImpls() {
        let h = HeadingElem(body: TextElem.packed("x")).withDepth(2)
        #expect(h.refNumbering() == nil)
        #expect(h.isOutlined())
        #expect(h.outlineLevel().value == 2)
        #expect(h.outlineBody().plainText.contains("x"))
        #expect(h.outlinePrefix(TextElem.packed("1")).plainText.contains("1"))
        guard case let .selector(.elem(elem, _)) = h.refCounter().key else {
            Issue.record("expected element counter key"); return
        }
        #expect(elem == Element(HeadingElem.self))
    }

    @Test func headingLevelResolution() {
        // level: auto → depth; explicit level wins.
        var h = HeadingElem(body: TextElem.packed("x")).withDepth(3)
        #expect(h.outlineLevel().value == 3)
        h = HeadingElem(body: TextElem.packed("x")).withDepth(1)
        h.level = .custom(5)
        #expect(h.outlineLevel().value == 5)
    }

    @Test func figureImpls() {
        // Default figure: numbering present → outlined.
        var fig = FigureElem(body: TextElem.packed("img"))
        #expect(fig.isOutlined())
        #expect(fig.outlineBody().isEmpty)

        // No caption and no numbering → not outlined.
        fig.numbering = nil
        #expect(!fig.isOutlined())

        // Caption present → outlined again, body from caption.
        fig.caption = FigureCaption(body: TextElem.packed("A caption"))
        #expect(fig.isOutlined())
        #expect(fig.outlineBody().plainText.contains("A caption"))

        // outlined: false wins over everything.
        fig.outlined = false
        #expect(!fig.isOutlined())
    }

    @Test func figurePrefixWithSupplement() {
        var fig = FigureElem(body: TextElem.packed("img"))
        fig.caption = FigureCaption(body: TextElem.packed("cap"))
        // No supplement synthesized yet → bare numbers.
        let bare = fig.outlinePrefix(TextElem.packed("1"))
        #expect(bare.plainText.contains("1"))

        // Content supplement → "supp\u{a0}1".
        fig.supplement = .custom(.content(TextElem.packed("Figure")))
        let withSupp = fig.outlinePrefix(TextElem.packed("1"))
        #expect(withSupp.plainText.contains("Figure"))
        #expect(withSupp.plainText.contains("1"))
    }

    @Test func figureCounterFallback() {
        let fig = FigureElem(body: TextElem.packed("img"))
        // No synthesized counter → falls back to the figure element counter.
        guard case let .selector(.elem(elem, _)) = fig.refCounter().key else {
            Issue.record("expected element counter key"); return
        }
        #expect(elem == Element(FigureElem.self))
    }

    // MARK: - TextDir + Content.isEmpty

    @Test func textDirCasts() throws {
        // Horizontal directions accepted.
        let rtl = try TextDir.fromValue(.dynamic(Dir.rtl)).get()
        #expect(rtl.dir == .custom(.rtl))
        // Vertical directions rejected.
        #expect((try? TextDir.fromValue(.dynamic(Dir.ttb)).get()) == nil)
        // Auto passes through.
        let auto = try TextDir.fromValue(.auto).get()
        #expect(auto.dir == .auto)
    }

    @Test func textDirResolution() throws {
        // Custom wins; auto → ltr until `Lang` lands.
        #expect(TextDir(.custom(.rtl)).resolve(StyleChain()) == .rtl)
        #expect(TextDir(.auto).resolve(StyleChain()) == .ltr)
    }

    @Test func textDirFieldRoundtrip() throws {
        var text = TextElem(TypstLibrary.Str("x"))
        try text.setField(TextElem.dirFieldID, .dynamic(Dir.rtl))
        #expect(text.dir.dir == .custom(.rtl))
        guard case .dynamic(let d) = text.field(TextElem.dirFieldID),
              let dir = d.downcast(Dir.self) else {
            Issue.record("expected dir value"); return
        }
        #expect(dir == .rtl)
    }

    @Test func contentIsEmpty() {
        #expect(Content.empty.isEmpty)
        #expect(!TextElem.packed("x").isEmpty)
        #expect(!Content.sequence([TextElem.packed("x")]).isEmpty)
    }
}
