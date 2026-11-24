import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for layout element constructors (`pad`, `stack`, `hide`, `place`,
/// `columns`, `colbreak`, `layout`) ported from `typst-library/src/layout/`.
@Suite("LayoutElements")
struct LayoutElementTests {
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

    @Test func padConstruct() throws {
        // Positional `rest` applies to all four sides.
        let uniform = try markup("#pad(5pt)[x]")
        let pad = try #require(firstElem(uniform)?.element as? PadElem)
        #expect(pad.left.abs.abs.toPt() == 5)
        #expect(pad.top.abs.abs.toPt() == 5)
        #expect(pad.right.abs.abs.toPt() == 5)
        #expect(pad.bottom.abs.abs.toPt() == 5)

        // `x`/`y` split horizontal and vertical.
        let xy = try markup("#pad(x: 1pt, y: 2pt)[x]")
        let padXY = try #require(firstElem(xy)?.element as? PadElem)
        #expect(padXY.left.abs.abs.toPt() == 1)
        #expect(padXY.top.abs.abs.toPt() == 2)
        #expect(padXY.right.abs.abs.toPt() == 1)
        #expect(padXY.bottom.abs.abs.toPt() == 2)

        // Individual sides override `x`/`rest`; `rest` beats positional find?
        // Upstream: rest named wins over find; individual named beats x.
        let mixed = try markup("#pad(left: 3pt, rest: 1pt)[x]")
        let padMixed = try #require(firstElem(mixed)?.element as? PadElem)
        #expect(padMixed.left.abs.abs.toPt() == 3)
        #expect(padMixed.top.abs.abs.toPt() == 1)
        #expect(padMixed.right.abs.abs.toPt() == 1)
        #expect(padMixed.bottom.abs.abs.toPt() == 1)

        // No args → all zero.
        let zero = try markup("#pad[x]")
        let padZero = try #require(firstElem(zero)?.element as? PadElem)
        #expect(padZero.left.isZero() && padZero.top.isZero())
    }

    @Test func stackConstruct() throws {
        let stack = try markup("#stack(dir: ttb, spacing: 1em, [a], [b])")
        let elem = try #require(firstElem(stack)?.element as? StackElem)
        #expect(elem.dir == .ttb)
        #expect(elem.spacing != nil)
        #expect(elem.children.count == 2)

        // Bare spacing values become `.spacing` children.
        let spaced = try markup("#stack(1em, [a], 2em, [b])")
        let elemSpaced = try #require(firstElem(spaced)?.element as? StackElem)
        #expect(elemSpaced.children.count == 4)
        guard case .spacing = elemSpaced.children[0] else {
            Issue.record("expected spacing child")
            return
        }
        guard case .block = elemSpaced.children[1] else {
            Issue.record("expected block child")
            return
        }

        // Default dir is ttb; spacing defaults to nil.
        let bare = try markup("#stack[a]")
        let elemBare = try #require(firstElem(bare)?.element as? StackElem)
        #expect(elemBare.dir == .ttb)
        #expect(elemBare.spacing == nil)
    }

    @Test func hideConstruct() throws {
        let hidden = try markup("#hide[x]")
        let elem = try #require(firstElem(hidden)?.element as? HideElem)
        #expect(!elem.hidden)
    }

    @Test func placeConstruct() throws {
        // Positional alignment.
        let placed = try markup("#place(center)[x]")
        let elem = try #require(firstElem(placed)?.element as? PlaceElem)
        #expect(elem.alignment == .custom(.center))
        #expect(elem.scope == .column)
        #expect(!elem.float)
        #expect(elem.clearance.em == Em(1.5))

        // Named fields.
        let full = try markup(
            "#place(scope: \"parent\", float: true, clearance: 2em, dx: 1pt, dy: 2pt)[x]")
        let elemFull = try #require(firstElem(full)?.element as? PlaceElem)
        #expect(elemFull.scope == .parent)
        #expect(elemFull.float)
        #expect(elemFull.dx.abs.abs.toPt() == 1)
        #expect(elemFull.dy.abs.abs.toPt() == 2)

        // `place.flush` nested scope.
        let flush = try markup("#place.flush()")
        #expect(firstElem(flush)?.element is FlushElem)
    }

    @Test func columnsConstruct() throws {
        let cols = try markup("#columns(3, gutter: 5pt, balanced: true)[x]")
        let elem = try #require(firstElem(cols)?.element as? ColumnsElem)
        #expect(elem.count.value == 3)
        #expect(elem.gutter.rel.isZero())
        #expect(elem.gutter.abs.abs.toPt() == 5)
        #expect(elem.balanced)

        // Default count is 2, gutter is 4% ratio.
        let bare = try markup("#columns[x]")
        let elemBare = try #require(firstElem(bare)?.element as? ColumnsElem)
        #expect(elemBare.count.value == 2)
        #expect(!elemBare.gutter.rel.isZero())
        #expect(throws: (any Error).self) {
            _ = try markup("#columns(0)[x]")
        }
    }

    @Test func colbreakConstruct() throws {
        let brk = try markup("#colbreak(weak: true)")
        let elem = try #require(firstElem(brk)?.element as? ColbreakElem)
        #expect(elem.weak)
    }

    @Test func layoutConstruct() throws {
        let laid = try markup("#layout(x => x)")
        let elem = try #require(firstElem(laid)?.element as? LayoutElem)
        #expect(elem.field(0) != nil)
    }

    @Test func setRules() throws {
        // `#set` wraps following content in a StyledElem carrying the
        // property for the element's settable field.
        let content = try markup("#set pad(left: 7pt)\n#pad[x]")
        let styled = try #require(content.packed.element as? StyledElem)
        #expect(styled.child.packed.element is PadElem)
        let hasPadLeft = styled.styles.items.contains { item in
            guard case let .property(p) = item.value,
                  p.elem.name == "pad",
                  p.elem.info.fieldName(p.field) == "left"
            else { return false }
            return true
        }
        #expect(hasPadLeft)

        let placed = try markup("#set place(float: true)\n#place[x]")
        let styledPlace = try #require(placed.packed.element as? StyledElem)
        let hasFloat = styledPlace.styles.items.contains { item in
            guard case let .property(p) = item.value,
                  p.elem.name == "place",
                  p.elem.info.fieldName(p.field) == "float"
            else { return false }
            return true
        }
        #expect(hasFloat)
    }
}
