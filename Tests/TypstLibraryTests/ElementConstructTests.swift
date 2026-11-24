import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for element constructors (`#[elem]`-generated `Construct` impls)
/// and global scope registration — the `#element(...)` call path.
@Suite("ElementConstructs")
struct ElementConstructTests {
    /// Evaluate markup source into content.
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

    /// Evaluate a code expression and return its value.
    private func eval(_ source: String) throws -> Value {
        let node = parseCode(source)
        guard let code = node.cast(Code.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "test harness: expected code"))
        }
        let world = MockWorld()
        let engine = Engine(world: world)
        var vm = Vm(
            engine: engine,
            context: Context(),
            scopes: Scopes(base: world.library.value.scope),
            inspected: nil)
        var index = 0
        return try evalCode(&vm, code.exprs(), &index)
    }

    /// First element of content, unwrapping a top-level sequence.
    private func firstElem(_ content: Content) -> PackedElement? {
        if let seq = content.packed.element as? SequenceElem,
           let first = seq.children.first {
            return first.packed
        }
        return content.packed
    }

    @Test func spacingConstructs() throws {
        // #h(amount) — positional spacing.
        #expect(firstElem(try markup("#h(1em)"))?.element is HElem)

        // Fractional spacing.
        #expect(firstElem(try markup("#h(1fr)"))?.element is HElem)

        // #v(amount).
        #expect(firstElem(try markup("#v(2em)"))?.element is VElem)

        // Missing amount is an error.
        #expect(throws: (any Error).self) {
            _ = try markup("#h()")
        }
    }

    @Test func listConstructs() throws {
        // Variadic children become ListItems (plain content is wrapped).
        let list = try markup("#list[A][B]")
        guard let listElem = firstElem(list)?.element as? ListElem else {
            Issue.record("expected ListElem"); return
        }
        #expect(listElem.children.count == 2)

        // tight is a settable Bool field.
        let loose = try markup("#list(tight: false)[A]")
        guard let looseElem = firstElem(loose)?.element as? ListElem else {
            Issue.record("expected ListElem"); return
        }
        #expect(looseElem.tight == false)

        // Nested item func from the element scope.
        let item = try markup("#list.item[A]")
        #expect(firstElem(item)?.element is TypstLibrary.ListItem)
    }

    @Test func enumAndTermsConstructs() throws {
        let enumContent = try markup("#enum[A][B]")
        guard let enumElem = firstElem(enumContent)?.element as? EnumElem else {
            Issue.record("expected EnumElem"); return
        }
        #expect(enumElem.children.count == 2)

        // Enum item accepts a positional number.
        let numbered = try eval("enum.item(5)[A]")
        guard case .content(let numberedContent) = numbered,
              let itemElem = numberedContent.packed.element as? TypstLibrary.EnumItem else {
            Issue.record("expected EnumItem content"); return
        }
        guard case .custom(let n) = itemElem.number else {
            Issue.record("expected custom number"); return
        }
        #expect(n == 5)

        let terms = try markup("#terms[#terms.item[Term][Desc]]")
        guard let termsElem = firstElem(terms)?.element as? TermsElem else {
            Issue.record("expected TermsElem"); return
        }
        #expect(termsElem.children.count == 1)
        #expect(termsElem.children[0].term.plainText == "Term")
        #expect(termsElem.children[0].description.plainText == "Desc")
    }

    @Test func inlineConstructs() throws {
        #expect(firstElem(try markup("#pagebreak()"))?.element is PagebreakElem)

        // Alignment: positional alignment + body.
        let aligned = try markup("#align(center)[Hi]")
        guard let alignElem = firstElem(aligned)?.element as? AlignElem else {
            Issue.record("expected AlignElem"); return
        }
        #expect(alignElem.alignment == Alignment.center)

        // Alignment value itself resolves from the global scope.
        let center = try eval("center")
        #expect(center == .dynamic(Alignment.center))

        // Box with body.
        #expect(firstElem(try markup("#box[Hi]"))?.element is BoxElem)

        // Strong/emph deltas.
        #expect(firstElem(try markup("#strong[Hi]"))?.element is StrongElem)
        #expect(firstElem(try markup("#emph[Hi]"))?.element is EmphElem)
    }

    @Test func linkConstructs() throws {
        // Explicit body.
        let link = try markup("#link(\"https://typst.app\")[site]")
        #expect(firstElem(link)?.element is LinkElem)

        // URL string destination defaults body to the URL text.
        let bare = try markup("#link(\"https://typst.app\")")
        guard let bareElem = firstElem(bare)?.element as? LinkElem else {
            Issue.record("expected LinkElem"); return
        }
        #expect(bareElem.body.plainText.contains("typst.app"))

        // mailto: strips the scheme for the default body.
        let mail = try markup("#link(\"mailto:a@b.c\")")
        guard let mailElem = firstElem(mail)?.element as? LinkElem else {
            Issue.record("expected LinkElem"); return
        }
        #expect(mailElem.body.plainText == "a@b.c")
    }

    /// Element names of content, recursing into sequences.
    private func elemNames(_ content: Content) -> [String] {
        if let seq = content.packed.element as? SequenceElem {
            return seq.children.flatMap { elemNames($0) }
        }
        return [content.elem.name]
    }

    @Test func pageConstruct() throws {
        // #page does not create a PageElem — it wraps the body in a
        // pagebreak/flush sequence upstream.
        let page = try markup("#page[Hello]")
        let names = elemNames(page)
        #expect(names.contains("pagebreak"))
        #expect(names.contains("flush"))
        #expect(names.contains("text"))
    }

    @Test func setConstructs() throws {
        // #set produces a StyledElem carrying the property (statements
        // need a line break or semicolon terminator in markup).
        let styled = try markup("#set par(justify: true)\nHello")
        guard let styledElem = firstElem(styled)?.element as? StyledElem else {
            Issue.record("expected StyledElem from #set"); return
        }
        #expect(!styledElem.styles.isEmpty)

        // #set on a settable element field.
        let setAlign = try markup("#set align(center)\nHi")
        #expect(firstElem(setAlign) != nil)

        // #text applies style fields to its body.
        let text = try markup("#text(lang: \"de\")[Hallo]")
        #expect(firstElem(text) != nil)
    }

    @Test func headingAndDocumentConstructs() throws {
        let heading = try markup("#heading[Title]")
        #expect(firstElem(heading)?.element is HeadingElem)

        let deep = try markup("#heading(level: 2, numbering: \"1.\")[T]")
        guard let h = firstElem(deep)?.element as? HeadingElem else {
            Issue.record("expected HeadingElem"); return
        }
        guard case .custom = h.level else {
            Issue.record("expected custom level"); return
        }

        let doc = try markup("#document(title: \"T\")[Body]")
        guard let docElem = firstElem(doc)?.element as? DocumentElem else {
            Issue.record("expected DocumentElem"); return
        }
        #expect(docElem.title != nil)
    }

    @Test func constructorErrors() throws {
        // Missing required positional.
        #expect(throws: (any Error).self) {
            _ = try markup("#h()")
        }
        // Wrong child type for list (int is not content).
        #expect(throws: (any Error).self) {
            _ = try markup("#list(1)")
        }
        // Unknown element still errors.
        #expect(throws: (any Error).self) {
            _ = try eval("#nosuchfunc(1)")
        }
    }
}
