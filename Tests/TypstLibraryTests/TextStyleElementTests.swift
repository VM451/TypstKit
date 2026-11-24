import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for the text decoration/shift element definitions ported from
/// `typst-library/src/text/{deco,shift,smallcaps}.rs`.
@Suite("TextStyleElements")
struct TextStyleElementTests {
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

    private func pt(_ length: Length) -> Double { length.abs.toPt() }

    // MARK: - underline / overline / strike

    @Test func underlineFields() throws {
        let content = try markup("#underline(offset: 2pt, extent: 1pt, evade: false)[x]")
        let elem = try #require(firstElem(content)?.element as? UnderlineElem)
        #expect(elem.stroke.isAuto)
        guard case .custom(let offset) = elem.offset else {
            Issue.record("expected custom offset"); return
        }
        #expect(pt(offset) == 2)
        #expect(pt(elem.extent) == 1)
        #expect(elem.evade == false)
        #expect(elem.background == false)
    }

    @Test func overlineDefaults() throws {
        let content = try markup("#overline[x]")
        let elem = try #require(firstElem(content)?.element as? OverlineElem)
        #expect(elem.evade == true)
        #expect(elem.stroke.isAuto)
        #expect(elem.offset.isAuto)
    }

    @Test func strikeHasNoEvade() throws {
        let content = try markup("#strike(background: true)[x]")
        let elem = try #require(firstElem(content)?.element as? StrikeElem)
        #expect(elem.background == true)
        // StrikeElem has no `evade` field upstream.
        #expect(StrikeElem.info.fields.count == 5)
    }

    // MARK: - highlight

    @Test func highlightDefaults() throws {
        let content = try markup("#highlight[x]")
        let elem = try #require(firstElem(content)?.element as? HighlightElem)
        #expect(elem.fill != nil)
        #expect(elem.topEdge == .metric(.ascender))
        #expect(elem.bottomEdge == .metric(.descender))
    }

    @Test func highlightEdges() throws {
        let content = try markup(
            "#highlight(top-edge: \"cap-height\", bottom-edge: 2pt, extent: 1pt)[x]")
        let elem = try #require(firstElem(content)?.element as? HighlightElem)
        #expect(elem.topEdge == .metric(.capHeight))
        guard case .length(let bottom) = elem.bottomEdge else {
            Issue.record("expected length bottom edge"); return
        }
        #expect(pt(bottom) == 2)
        #expect(pt(elem.extent) == 1)
    }

    // MARK: - sub / super / smallcaps

    @Test func subFields() throws {
        let content = try markup("#sub(typographic: false, baseline: 1pt, size: 8pt)[x]")
        let elem = try #require(firstElem(content)?.element as? SubElem)
        #expect(elem.typographic == false)
        guard case .custom(let baseline) = elem.baseline else {
            Issue.record("expected custom baseline"); return
        }
        #expect(pt(baseline) == 1)
        guard case .custom(let size) = elem.size else {
            Issue.record("expected custom size"); return
        }
        #expect(pt(size.inner) == 8)
    }

    @Test func superDefaults() throws {
        let content = try markup("#super[x]")
        let elem = try #require(firstElem(content)?.element as? SuperElem)
        #expect(elem.typographic == true)
        #expect(elem.baseline.isAuto)
        #expect(elem.size.isAuto)
    }

    @Test func smallcaps() throws {
        let content = try markup("#smallcaps(all: true)[x]")
        let elem = try #require(firstElem(content)?.element as? SmallcapsElem)
        #expect(elem.all == true)
    }

}
