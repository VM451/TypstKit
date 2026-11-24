import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for `DividerElem`, `QuoteElem`, and `ArtifactElem` ported from
/// `typst-library/src/model/{divider,quote,accessibility}.rs`.
@Suite("QuoteDividerArtifact")
struct QuoteDividerArtifactTests {
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

    // MARK: - divider

    @Test func dividerElement() throws {
        let content = try markup("#divider()")
        #expect(firstElem(content)?.element is DividerElem)
    }

    @Test func dividerShowSet() throws {
        let elem = DividerElem()
        let styles = elem.showSet(styles: StyleChain())
        // Four properties: block above/below + line length/stroke.
        var found = Set<String>()
        for style in styles.items {
            guard case let .property(p) = style.value else { continue }
            found.insert("\(p.elem.name).\(p.field)")
        }
        #expect(found.contains("block.8"))
        #expect(found.contains("block.9"))
        #expect(found.contains("line.2"))
        #expect(found.contains("line.4"))
    }

    // MARK: - quote

    @Test func quoteFields() throws {
        let content = try markup("#quote(block: true, attribution: [Me])[x]")
        let quote = try #require(firstElem(content)?.element as? QuoteElem)
        #expect(quote.block == true)
        #expect(quote.quotes.isAuto)
        guard case .content = quote.attribution else {
            Issue.record("expected content attribution"); return
        }
    }

    @Test func quoteAttributionLabel() throws {
        let content = try markup("#quote(attribution: <k>)[x]")
        let quote = try #require(firstElem(content)?.element as? QuoteElem)
        guard case .label = quote.attribution else {
            Issue.record("expected label attribution"); return
        }
    }

    @Test func quoteShowSetBlock() throws {
        var elem = QuoteElem(body: .empty)
        elem.block = true
        let styles = elem.showSet(styles: StyleChain())
        #expect(!styles.items.isEmpty)
    }

    @Test func quoteShowSetInline() throws {
        let elem = QuoteElem(body: .empty)
        let styles = elem.showSet(styles: StyleChain())
        #expect(styles.items.isEmpty)
    }

    // MARK: - artifact

    @Test func artifactFields() throws {
        let elem = ArtifactElem(kind: .pageNumber, body: TextElem.packed("1"))
        #expect(elem.kind == .pageNumber)
        #expect(ArtifactElem.info.capabilities.contains(.tagged))
    }

    @Test func artifactKindCast() throws {
        #expect(try ArtifactKind.fromValue(.str(Str("bates"))).get() == .bates)
        #expect(try ArtifactKind.fromValue(.str(Str("other"))).get() == .other)
    }
}
