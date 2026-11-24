import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for the ported `typst-realize` subsystem: grouping rules, space
/// collapsing, show rule application, and tag generation.
@Suite("Realize")
struct RealizeTests {
    /// Run realization over content and return the resulting pairs.
    private func realizeContent(
        _ content: Content,
        kind: RealizationKind = .par,
        styles: Styles = Styles()
    ) throws -> [RealizePair] {
        var engine = Engine(world: MockWorld())
        let locator = Locator(local: hash128("test"), outer: nil).split()
        let chain = StyleChain.new(root: styles)
        return try realize(
            kind: kind, engine: &engine, locator: locator,
            content: content, styles: chain).get()
    }

    /// Realize in document mode.
    private func realizeDocument(
        _ content: Content,
        styles: Styles = Styles()
    ) throws -> [RealizePair] {
        var engine = Engine(world: MockWorld())
        let locator = Locator(local: hash128("test"), outer: nil).split()
        let chain = StyleChain.new(root: styles)
        return try realize(
            kind: .document(info: DocumentInfoRef(),
                            options: DocumentFormatOptionsRef()),
            engine: &engine, locator: locator,
            content: content, styles: chain).get()
    }

    /// The realized elements, without style chains.
    private func elements(_ pairs: [RealizePair]) -> [Content] {
        pairs.map { $0.content }
    }

    /// Realized elements with introspection tags filtered out.
    private func nonTagElements(_ pairs: [RealizePair]) -> [Content] {
        elements(pairs).filter { !$0.is(TagElem.self) }
    }

    private func text(_ content: Content) -> String? {
        content.packed(TextElem.self)?.text.value
    }

    @Test func paragraphGrouping() throws {
        let content = Content.sequence([
            TextElem.packed("a"),
            Content(SpaceElem()),
            TextElem.packed("b"),
        ])
        let pairs = try realizeDocument(content)
        let elems = elements(pairs)

        // Inline content is collected into a single paragraph.
        let pars = elems.filter { $0.is(ParElem.self) }
        #expect(pars.count == 1)
        let par = try #require(pars.first?.packed(ParElem.self))
        let children = (par.body.packed(SequenceElem.self)?.children ?? [par.body])
            .filter { !$0.is(TagElem.self) }
        #expect(children.count == 3)
        #expect(text(children[0]) == "a")
        #expect(children[1].is(SpaceElem.self))
        #expect(text(children[2]) == "b")

        // The paragraph is locatable and tagged, so it is wrapped in tags.
        #expect(elems.filter { $0.is(TagElem.self) }.count == 2)
    }

    @Test func spaceCollapsingInFragment() throws {
        let kind = FragmentKindRef()
        let content = Content.sequence([
            Content(SpaceElem()),
            TextElem.packed("a"),
            Content(SpaceElem()),
            Content(SpaceElem()),
            TextElem.packed("b"),
            Content(SpaceElem()),
        ])
        let pairs = try realizeContent(
            content, kind: .fragment(kind: kind), styles: Styles())
        let elems = nonTagElements(pairs)

        // Fully-inline fragments stay inline; edge spaces are discarded and
        // adjacent spaces collapse into one.
        #expect(kind.value == .inline)
        #expect(elems.count == 3)
        #expect(text(elems[0]) == "a")
        #expect(elems[1].is(SpaceElem.self))
        #expect(text(elems[2]) == "b")
    }

    @Test func spaceBeforeLinebreakDiscarded() throws {
        let content = Content.sequence([
            TextElem.packed("a"),
            Content(SpaceElem()),
            Content(LinebreakElem()),
            TextElem.packed("b"),
        ])
        let pairs = try realizeDocument(content)
        let par = try #require(
            elements(pairs).first { $0.is(ParElem.self) }?
                .packed(ParElem.self))
        let children = (par.body.packed(SequenceElem.self)?.children ?? [])
            .filter { !$0.is(TagElem.self) }
        // The space before the linebreak is discarded.
        #expect(children.count == 3)
        #expect(text(children[0]) == "a")
        #expect(children[1].is(LinebreakElem.self))
        #expect(text(children[2]) == "b")
    }

    @Test func listGrouping() throws {
        let content = Content.sequence([
            Content(ListItem(body: TextElem.packed("a"))),
            Content(ParbreakElem()),
            Content(ListItem(body: TextElem.packed("b"))),
        ])
        let pairs = try realizeContent(content, kind: .fragment(kind: FragmentKindRef()))
        let lists = elements(pairs).filter { $0.is(ListElem.self) }
        #expect(lists.count == 1)
        let list = try #require(lists.first?.packed(ListElem.self))
        #expect(list.children.count == 2)
        #expect(list.tight == false)
    }

    @Test func tightListGrouping() throws {
        let content = Content.sequence([
            Content(ListItem(body: TextElem.packed("a"))),
            Content(ListItem(body: TextElem.packed("b"))),
        ])
        let pairs = try realizeContent(content, kind: .fragment(kind: FragmentKindRef()))
        let list = try #require(
            elements(pairs).first { $0.is(ListElem.self) }?
                .packed(ListElem.self))
        #expect(list.children.count == 2)
        #expect(list.tight == true)
    }

    @Test func enumGrouping() throws {
        let content = Content.sequence([
            Content(EnumItem(body: TextElem.packed("a"))),
            Content(EnumItem(body: TextElem.packed("b"))),
        ])
        let pairs = try realizeContent(content, kind: .fragment(kind: FragmentKindRef()))
        let enums = elements(pairs).filter { $0.is(EnumElem.self) }
        #expect(enums.count == 1)
        #expect(try #require(enums.first?.packed(EnumElem.self)).children.count == 2)
    }

    @Test func termsGrouping() throws {
        let content = Content.sequence([
            Content(TermItem(term: TextElem.packed("a"),
                             description: TextElem.packed("b"))),
            Content(TermItem(term: TextElem.packed("c"),
                             description: TextElem.packed("d"))),
        ])
        let pairs = try realizeContent(content, kind: .fragment(kind: FragmentKindRef()))
        let terms = elements(pairs).filter { $0.is(TermsElem.self) }
        #expect(terms.count == 1)
        #expect(try #require(terms.first?.packed(TermsElem.self)).children.count == 2)
    }

    @Test func citeGrouping() throws {
        let key = try #require(Label(name: .intern("key")))
        let content = Content.sequence([
            Content(CiteElem(key: key)),
            Content(CiteElem(key: key)),
        ])
        let pairs = try realizeContent(content, kind: .fragment(kind: FragmentKindRef()))
        let groups = elements(pairs).filter { $0.is(CiteGroup.self) }
        #expect(groups.count == 1)
        #expect(try #require(groups.first?.packed(CiteGroup.self)).children.count == 2)
    }

    @Test func regexShowRule() throws {
        // A regex show rule replaces matches during textual realization.
        let regex = try Regex("a+")
        var styles = Styles()
        styles.append(.recipe(Recipe(
            selector: .regex(regex),
            transform: .content(TextElem.packed("X")),
            span: .detached)))
        let pairs = try realizeContent(TextElem.packed("aaa"), styles: styles)
        let texts = elements(pairs).compactMap { text($0) }
        #expect(texts == ["X"])
    }

    @Test func elementShowRule() throws {
        // An element selector show rule transforms matching elements.
        var styles = Styles()
        styles.append(.recipe(Recipe(
            selector: .elem(Element(StrongElem.self), fields: nil),
            transform: .content(TextElem.packed("wrapped")),
            span: .detached)))
        let content = Content(StrongElem(body: TextElem.packed("a")))
        let pairs = try realizeContent(content, styles: styles)
        #expect(elements(pairs).contains { text($0) == "wrapped" })
    }

    @Test func mathContentWrappedInEquation() throws {
        // Mathy elements are transparently wrapped into equations.
        // `EquationElem` itself is mathy but exempt from wrapping.
        let eq = Content(EquationElem(body: TextElem.packed("x")))
        let pairs = try realizeContent(eq, kind: .math)
        // In math realization the equation is unwrapped transparently.
        #expect(!elements(pairs).isEmpty)
    }

    @Test func emptyContent() throws {
        let pairs = try realizeContent(Content.empty)
        #expect(pairs.isEmpty)
    }
}
