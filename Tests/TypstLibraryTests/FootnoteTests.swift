import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `FootnoteElem`, `FootnoteEntry`, `FootnoteContainer`,
/// `FootnoteMarker`, `DirectLinkElem`, and `LinkMarker` ported from
/// `typst-library/src/model/{footnote,link}.rs`.
@Suite("Footnote")
struct FootnoteTests {
    private func markup(_ source: String) throws -> Content {
        let node = parse(source)
        guard let markup = node.cast(Markup.self) else {
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
        return try markup.eval(&vm)
    }

    private func firstElem(_ content: Content) -> PackedElement? {
        if let seq = content.packed.element as? SequenceElem,
           let first = seq.children.first {
            return first.packed
        }
        return content.packed
    }

    // MARK: - footnote

    @Test func footnoteContentBody() throws {
        let content = try markup("#footnote[Hello]")
        let elem = try #require(firstElem(content)?.element as? FootnoteElem)
        #expect(elem.numbering == .pattern(
            NumberingPattern(pieces: [("", .arabic)], suffix: "")))
        guard case let .content(body) = elem.body else {
            Issue.record("expected content body"); return
        }
        #expect(body.packed(TextElem.self) != nil)
    }

    @Test func footnoteLabelBody() throws {
        let content = try markup("#footnote(<fn>)")
        let elem = try #require(firstElem(content)?.element as? FootnoteElem)
        guard case let .reference(label) = elem.body else {
            Issue.record("expected reference body"); return
        }
        #expect(label.resolved == "fn")
        #expect(elem.isRef())
        #expect(elem.bodyContent() == nil)
    }

    @Test func footnoteNumbering() throws {
        let content = try markup("#footnote(numbering: \"a)\", [x])")
        let elem = try #require(firstElem(content)?.element as? FootnoteElem)
        guard case let .pattern(p) = elem.numbering else {
            Issue.record("expected pattern numbering"); return
        }
        #expect(p.suffix == ")")
    }

    @Test func footnoteHelpers() {
        let note = FootnoteElem.withContent(TextElem.packed("hi"))
        #expect(!note.isRef())
        #expect(note.bodyContent() != nil)
        let label = Label(name: "fn")!
        let refr = note.intoRef(label)
        #expect(refr.isRef())
        #expect(refr.bodyContent() == nil)
        #expect(FootnoteElem.withLabel(label).isRef())
    }

    @Test func footnoteBodyCast() throws {
        let c = TextElem.packed("x")
        let body = try FootnoteBody.fromValue(c.intoValue()).get()
        guard case .content = body else {
            Issue.record("expected content cast"); return
        }
        let label = Label(name: "l")!
        let body2 = try FootnoteBody.fromValue(label.intoValue()).get()
        guard case .reference = body2 else {
            Issue.record("expected label cast"); return
        }
        if case .success = FootnoteBody.fromValue(.int(1)) {
            Issue.record("expected cast failure")
        }
    }

    // MARK: - footnote.entry

    @Test func footnoteEntryScope() throws {
        // `footnote.entry` resolves through the footnote element's scope.
        let world = MockWorld()
        let footnote = world.library.value.scope.get("footnote")
        guard let footnote,
              case let .function(f) = footnote.value,
              let scope = f.element?.info.scope,
              let entryBinding = scope.get("entry"),
              case let .function(entry) = entryBinding.value else {
            Issue.record("footnote.entry not registered"); return
        }
        #expect(entry.element?.info.name == "entry")
    }

    @Test func footnoteEntryConstruct() throws {
        let content = try markup("#footnote.entry(footnote[x], clearance: 2em)")
        let elem = try #require(firstElem(content)?.element as? FootnoteEntry)
        #expect(elem.note.packed(FootnoteElem.self) != nil)
        #expect(elem.clearance == Length(Em(2.0)))
        // Defaults: separator is a line, gap/indent are 0.5em/1em.
        #expect(elem.separator.packed(LineElem.self) != nil)
        #expect(elem.gap == Length(Em(0.5)))
        #expect(elem.indent == Length(Em(1.0)))
    }

    @Test func footnoteEntryRejectsNonFootnote() {
        // `x` markup is text content, not a footnote — construct must fail.
        #expect(throws: (any Error).self) {
            _ = try markup("#footnote.entry[x]")
        }
    }

    @Test func footnoteEntryShowSet() {
        let entry = FootnoteEntry(note: Content(FootnoteElem(body: .content(TextElem.packed("x")))))
        let styles = entry.showSet(styles: StyleChain())
        var found = Set<String>()
        for style in styles.items {
            guard case let .property(p) = style.value else { continue }
            found.insert("\(p.elem.name).\(p.field)")
        }
        #expect(found.contains("par.0"))
        #expect(found.contains("text.3"))
    }

    // MARK: - internal elements

    @Test func footnoteContainerMarker() {
        #expect(FootnoteContainer.info.name == "footnote-container")
        #expect(FootnoteMarker.info.name == "footnote-marker")
        #expect(FootnoteContainer.info.capabilities.contains(.locatable))
        #expect(FootnoteMarker.info.capabilities.contains(.locatable))
        _ = FootnoteContainer.shared
    }

    @Test func directLinkAndMarker() throws {
        #expect(DirectLinkElem.info.name == "direct-link")
        #expect(LinkMarker.info.name == "link-marker")
        let loc = Location(hash: Hash128(high: 0, low: 0))
        let link = DirectLinkElem(loc: loc, body: TextElem.packed("x"),
                                  alt: Str("alt"))
        #expect(link.field(1) == .content(link.body))
        #expect(link.field(2) == .str(Str("alt")))
        let marker = LinkMarker(body: TextElem.packed("y"))
        #expect(marker.field(0) == .content(marker.body))
        #expect(marker.field(1) == nil)
    }

    @Test func internalConstructsThrow() {
        var engine = Engine(world: MockWorld())
        var args = Args(span: .detached)
        #expect(throws: HintedString.self) {
            try DirectLinkElem.construct(engine: &engine, args: &args)
        }
        #expect(throws: HintedString.self) {
            try LinkMarker.construct(engine: &engine, args: &args)
        }
    }
}
