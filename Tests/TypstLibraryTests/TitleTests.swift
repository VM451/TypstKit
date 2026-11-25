import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `TitleElem` (`model/title.rs`) and the `FontWeight`
/// constants/casts ported in `text/font/variant.rs`.
@Suite("TitleElements")
struct TitleTests {
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

    private func chainWithDocumentTitle(_ title: Content) -> StyleChain {
        StyleChain(head: [LazyHash(Style.property(Property(
            elem: Element(DocumentElem.self),
            field: 0,
            value: .content(title)
        )))][...])
    }

    @Test func titleBodyFromMarkup() throws {
        let content = try markup("#title[Hello]")
        let packed = try #require(firstElem(content)?.element as? TitleElem)
        guard case let .custom(body) = packed.body else {
            Issue.record("expected custom body"); return
        }
        #expect(body.plainText == "Hello")
    }

    @Test func titleBodyAutoResolvesDocumentTitle() throws {
        let content = try markup("#title()")
        let packed = try #require(firstElem(content)?.element as? TitleElem)
        guard case .auto = packed.body else {
            Issue.record("expected auto body"); return
        }
        let docTitle = try markup("MyDoc")
        let styles = chainWithDocumentTitle(docTitle)
        let resolved = try packed.resolveBody(styles: styles).get()
        #expect(resolved.plainText == "MyDoc")
    }

    @Test func titleBodyAutoErrorsWithoutDocumentTitle() throws {
        let content = try markup("#title()")
        let packed = try #require(firstElem(content)?.element as? TitleElem)
        let result = packed.resolveBody(styles: StyleChain())
        guard case .failure = result else {
            Issue.record("expected failure"); return
        }
    }

    @Test func titleShowSetMatchesUpstream() throws {
        let content = try markup("#title[Hello]")
        let packed = try #require(firstElem(content)?.element as? TitleElem)
        let styles = packed.showSet(styles: StyleChain())
        var sawTextSize = false
        var sawWeight = false
        var sawAbove = false
        var sawBelow = false
        var sawSticky = false
        for item in styles.items {
            guard case let .property(p) = item.value, p.elem.name == "text"
            else { continue }
            switch p.field {
            case TextElem.sizeFieldID: sawTextSize = true
            case TextElem.weightFieldID:
                sawWeight = (p.value == FontWeight.bold.intoValue())
            default: break
            }
        }
        for item in styles.items {
            guard case let .property(p) = item.value, p.elem.name == "block"
            else { continue }
            switch p.field {
            case 8: sawAbove = true
            case 9: sawBelow = true
            case 11: sawSticky = (p.value == .bool(true))
            default: break
            }
        }
        #expect(sawTextSize && sawWeight && sawAbove && sawBelow && sawSticky)
    }

    @Test func fontWeightNamedCasts() throws {
        #expect(try FontWeight.fromValue(.str("bold")).get() == .bold)
        #expect(try FontWeight.fromValue(.str("black")).get() == .black)
        #expect(throws: (any Error).self) {
            _ = try FontWeight.fromValue(.str("bogus")).get()
        }
    }

    @Test func fontWeightIntegerCastsAndClamps() throws {
        #expect(try FontWeight.fromValue(.int(650)).get().number == 650)
        #expect(try FontWeight.fromValue(.int(950)).get() == .black)
        #expect(try FontWeight.fromValue(.int(-5)).get() == .thin)
        #expect(try FontWeight.fromValue(.int(70000)).get() == .black)
        #expect(throws: (any Error).self) {
            _ = try FontWeight.fromValue(.bool(true)).get()
        }
    }

    @Test func fontWeightIntoValueRoundTrips() throws {
        #expect(FontWeight.bold.intoValue() == .str("bold"))
        #expect(FontWeight(650).intoValue() == .int(650))
        #expect(try FontWeight.fromValue(FontWeight.semibold.intoValue()).get()
                == .semibold)
    }
}
