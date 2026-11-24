import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for the grid/table element definitions ported from
/// `typst-library/src/layout/grid/mod.rs` and `model/table.rs`.
@Suite("GridTableElements")
struct GridTableElementTests {
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

    // MARK: - grid basics

    @Test func gridTrackSizings() throws {
        // Integer count → that many auto tracks.
        let counted = try markup("#grid(columns: 3)[a]")
        let grid = try #require(firstElem(counted)?.element as? GridElem)
        #expect(grid.columns.tracks == [.auto, .auto, .auto])

        // Array of sizings.
        let sized = try markup("#grid(columns: (1fr, 20pt))[a]")
        let grid2 = try #require(firstElem(sized)?.element as? GridElem)
        guard case .fr = grid2.columns.tracks[0],
              case .rel(let rel) = grid2.columns.tracks[1] else {
            Issue.record("unexpected track sizings"); return
        }
        #expect(pt(rel.abs) == 20)

        // Single sizing → one track.
        let single = try markup("#grid(columns: 50%)[a]")
        let grid3 = try #require(firstElem(single)?.element as? GridElem)
        guard case .rel(let rel3) = grid3.columns.tracks.first else {
            Issue.record("expected rel track"); return
        }
        #expect(rel3.rel.get == 0.5)
    }

    @Test func gridGutterFallback() throws {
        // `gutter` feeds both column- and row-gutter.
        let content = try markup("#grid(gutter: 5pt)[a]")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        guard case .rel(let cg) = grid.columnGutter.tracks.first,
              case .rel(let rg) = grid.rowGutter.tracks.first else {
            Issue.record("expected rel gutters"); return
        }
        #expect(pt(cg.abs) == 5)
        #expect(pt(rg.abs) == 5)

        // `column-gutter` overrides `gutter` for columns only.
        let mixed = try markup("#grid(gutter: 5pt, column-gutter: 2pt)[a]")
        let grid2 = try #require(firstElem(mixed)?.element as? GridElem)
        guard case .rel(let cg2) = grid2.columnGutter.tracks.first,
              case .rel(let rg2) = grid2.rowGutter.tracks.first else {
            Issue.record("expected rel gutters"); return
        }
        #expect(pt(cg2.abs) == 2)
        #expect(pt(rg2.abs) == 5)
    }

    @Test func gridChildrenWrapping() throws {
        // Plain content children wrap into grid.cell items.
        let content = try markup("#grid[a][b]")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        #expect(grid.children.count == 2)
        guard case .item(let item) = grid.children[0],
              case .cell(let cellContent) = item,
              let cell = cellContent.to(GridCell.self) else {
            Issue.record("expected wrapped grid.cell"); return
        }
        #expect(cell.body.plainText.contains("a"))

        // Explicit grid.cell keeps its fields.
        let explicit = try markup("#grid(grid.cell(colspan: 2, x: 1)[c])[d]")
        let grid2 = try #require(firstElem(explicit)?.element as? GridElem)
        guard case .item(let item2) = grid2.children[0],
              case .cell(let cellContent2) = item2,
              let cell2 = cellContent2.to(GridCell.self) else {
            Issue.record("expected explicit cell"); return
        }
        #expect(cell2.colspan.value == 2)
        #expect(cell2.x == .custom(1))
    }

    @Test func gridNestedScopes() throws {
        // `grid.cell` / `grid.header` resolve through the element scope.
        let content = try markup(
            "#grid(grid.header[a], grid.hline(), grid.vline(), grid.cell[x])[b]")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        // Trailing `[b]` wraps into a fifth cell child.
        #expect(grid.children.count == 5)
        guard case .header = grid.children[0],
              case .item(let item1) = grid.children[1],
              case .hline = item1,
              case .item(let item2) = grid.children[2],
              case .vline = item2,
              case .item(let item3) = grid.children[3],
              case .cell = item3 else {
            Issue.record("unexpected child kinds"); return
        }
    }

    @Test func gridHeaderFooterFields() throws {
        let content = try markup(
            "#grid(grid.header(level: 2, repeat: false)[h], grid.footer[f])")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        guard case .header(let headerContent) = grid.children[0],
              let header = headerContent.to(GridHeader.self) else {
            Issue.record("expected grid.header"); return
        }
        #expect(header.level.value == 2)
        #expect(header.`repeat` == false)
        guard case .footer(let footerContent) = grid.children[1],
              let footer = footerContent.to(GridFooter.self) else {
            Issue.record("expected grid.footer"); return
        }
        #expect(footer.`repeat` == true)
    }

    @Test func gridLineFields() throws {
        let content = try markup(
            "#grid(grid.hline(y: 1, start: 2, end: 4, position: bottom, stroke: none),"
            + " grid.vline(x: 0, stroke: 2pt))[a]")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        guard case .item(let hItem) = grid.children[0],
              case .hline(let hContent) = hItem,
              let hline = hContent.to(GridHLine.self),
              case .item(let vItem) = grid.children[1],
              case .vline(let vContent) = vItem,
              let vline = vContent.to(GridVLine.self) else {
            Issue.record("expected hline/vline"); return
        }
        #expect(hline.y == .custom(1))
        #expect(hline.start == 2)
        #expect(hline.end?.value == 4)
        #expect(hline.position == .bottom)
        #expect(hline.stroke == nil)
        #expect(vline.x == .custom(0))
        #expect(vline.position == .start)
        #expect(vline.stroke != nil)
    }

    @Test func gridCellOverrides() throws {
        let content = try markup(
            "#grid(grid.cell(inset: 3pt, align: right, breakable: false)[x])")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        guard case .item(let item) = grid.children[0],
              case .cell(let cellContent) = item,
              let cell = cellContent.to(GridCell.self) else {
            Issue.record("expected grid.cell"); return
        }
        guard case .custom(let sides) = cell.inset,
              let rel = sides.left else {
            Issue.record("expected custom inset"); return
        }
        #expect(pt(rel.abs) == 3)
        #expect(cell.align == .custom(.h(.right)))
        #expect(cell.fill == .auto)
        #expect(cell.breakable == .custom(false))
    }

    @Test func gridRejectsTableParts() throws {
        // `table.cell` inside `grid` errors with a hint.
        #expect(throws: (any Error).self) {
            _ = try markup("#grid(table.cell[x])")
        }
    }

    // MARK: - table

    @Test func tableDefaults() throws {
        let content = try markup("#table[a][b]")
        let table = try #require(firstElem(content)?.element as? TableElem)
        // Table defaults: 5pt inset, black stroke — as celled values.
        guard case .value(let sides) = table.inset.value,
              let rel = sides.left else {
            Issue.record("expected default inset"); return
        }
        #expect(pt(rel.abs) == 5)
        guard case .value(let strokeSides) = table.stroke.value,
              case .some(.some) = strokeSides.left else {
            Issue.record("expected default stroke"); return
        }
        #expect(table.children.count == 2)
    }

    @Test func tableTrackSizingsAndGutter() throws {
        let content = try markup("#table(columns: 2, gutter: 4pt)[a][b]")
        let table = try #require(firstElem(content)?.element as? TableElem)
        #expect(table.columns.tracks == [.auto, .auto])
        guard case .rel(let cg) = table.columnGutter.tracks.first,
              case .rel(let rg) = table.rowGutter.tracks.first else {
            Issue.record("expected rel gutters"); return
        }
        #expect(pt(cg.abs) == 4)
        #expect(pt(rg.abs) == 4)
    }

    @Test func tableNestedScopes() throws {
        let content = try markup(
            "#table(table.header[h], table.hline(), table.cell(colspan: 2)[c])")
        let table = try #require(firstElem(content)?.element as? TableElem)
        #expect(table.children.count == 3)
        guard case .header(let headerContent) = table.children[0],
              let header = headerContent.to(TableHeader.self),
              case .item(let item) = table.children[1],
              case .hline = item,
              case .item(let item2) = table.children[2],
              case .cell(let cellContent) = item2,
              let cell = cellContent.to(TableCell.self) else {
            Issue.record("unexpected table children"); return
        }
        #expect(header.level.value == 1)
        #expect(cell.colspan.value == 2)
        #expect(cell.kind == .auto)
    }

    @Test func tableRejectsGridParts() throws {
        #expect(throws: (any Error).self) {
            _ = try markup("#table(grid.cell[x])")
        }
        #expect(throws: (any Error).self) {
            _ = try markup("#grid(table.header[h])")
        }
    }

    // MARK: - set rules

    private func hasProperty(_ styles: Styles, elem: String,
                             field: String) -> Bool {
        styles.items.contains { item in
            guard case let .property(p) = item.value,
                  p.elem.name == elem,
                  p.elem.info.fieldName(p.field) == field
            else { return false }
            return true
        }
    }

    @Test func gridSetRuleGutter() throws {
        // `#set grid(gutter: ..)` feeds both gutters via setImpl.
        let content = try markup("#set grid(gutter: 7pt)\n#grid[a]")
        let styled = try #require(content.packed.element as? StyledElem)
        #expect(hasProperty(styled.styles, elem: "grid", field: "column-gutter"))
        #expect(hasProperty(styled.styles, elem: "grid", field: "row-gutter"))
        #expect(styled.child.packed.element is GridElem)
    }

    @Test func tableSetRuleColumns() throws {
        let content = try markup("#set table(columns: 4)\n#table[a]")
        let styled = try #require(content.packed.element as? StyledElem)
        #expect(hasProperty(styled.styles, elem: "table", field: "columns"))
        #expect(styled.child.packed.element is TableElem)
    }

    // MARK: - celled values

    @Test func celledArrayAndFunc() throws {
        // Array form cycles per column.
        let content = try markup("#grid(inset: (3pt, 4pt))[a]")
        let grid = try #require(firstElem(content)?.element as? GridElem)
        guard case .array(let insets) = grid.inset.value else {
            Issue.record("expected celled array"); return
        }
        #expect(insets.count == 2)

        // Alignment array form.
        let alignContent = try markup("#grid(align: (left, right))[a]")
        let grid2 = try #require(firstElem(alignContent)?.element as? GridElem)
        guard case .array(let aligns) = grid2.align.value,
              aligns.count == 2 else {
            Issue.record("expected celled align array"); return
        }

        // Function form.
        let funcContent = try markup("#grid(align: (x, y) => left)[a]")
        let grid3 = try #require(firstElem(funcContent)?.element as? GridElem)
        guard case .`func` = grid3.align.value else {
            Issue.record("expected celled func"); return
        }
    }

    @Test func celledPaintCast() throws {
        // `Celled<Option<Paint>>` accepts bare paint values and arrays.
        let paint = Paint.fromValue(Color.navy.intoValue())
        guard case .success = paint else {
            Issue.record("expected paint cast"); return
        }
        let celled = Celled<Optional<Paint>>.fromValue(
            .array(ArrayValue(items: [Color.navy.intoValue()])))
        guard case .success(.array(let items)) = celled else {
            Issue.record("expected celled array"); return
        }
        #expect(items.count == 1)
    }
}
