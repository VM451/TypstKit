import Foundation
import TypstSyntax

/// Any child of a table element. Port of `TableChild` in `model/table.rs`.
public enum TableChild: Sendable, Hashable {
    case header(Content)
    case footer(Content)
    case item(TableItem)
}

extension TableChild: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Content.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .header(c): return c.intoValue()
        case let .footer(c): return c.intoValue()
        case let .item(i): return i.intoValue()
        }
    }

    /// Port of `TryFrom<Content> for TableChild`: rejects `grid.header` /
    /// `grid.footer` with hints, then header → footer → item.
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .content(content) = value else {
            return .failure(error(value))
        }
        if content.is(GridHeader.self) {
            return .failure(HintedString(
                "cannot use `grid.header` as a table header")
                .withHint("use `table.header` instead"))
        }
        if content.is(GridFooter.self) {
            return .failure(HintedString(
                "cannot use `grid.footer` as a table footer")
                .withHint("use `table.footer` instead"))
        }
        if content.is(TableHeader.self) { return .success(.header(content)) }
        if content.is(TableFooter.self) { return .success(.footer(content)) }
        return TableItem.contentToItem(content).map { .item($0) }
    }
}

/// A table item: hline, vline, or cell. Port of `TableItem` in
/// `model/table.rs`.
public enum TableItem: Sendable, Hashable {
    case hline(Content)
    case vline(Content)
    case cell(Content)
}

extension TableItem: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Content.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Content.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .hline(c): return c.intoValue()
        case let .vline(c): return c.intoValue()
        case let .cell(c): return c.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .content(content) = value else {
            return .failure(error(value))
        }
        return contentToItem(content)
    }

    /// Port of `TryFrom<Content> for TableItem`: rejects misplaced headers,
    /// footers, and `grid.*` cell/line elements with hints; wraps plain
    /// content in a `table.cell`.
    static func contentToItem(_ content: Content) -> HintedStrResult<TableItem> {
        if content.is(GridHeader.self) || content.is(TableHeader.self) {
            return .failure(HintedString(
                "cannot place a grid header within another header or footer"))
        }
        if content.is(GridFooter.self) || content.is(TableFooter.self) {
            return .failure(HintedString(
                "cannot place a grid footer within another footer or header"))
        }
        if content.is(GridCell.self) {
            return .failure(HintedString(
                "cannot use `grid.cell` as a table cell")
                .withHint("use `table.cell` instead"))
        }
        if content.is(GridHLine.self) {
            return .failure(HintedString(
                "cannot use `grid.hline` as a table line")
                .withHint("use `table.hline` instead"))
        }
        if content.is(GridVLine.self) {
            return .failure(HintedString(
                "cannot use `grid.vline` as a table line")
                .withHint("use `table.vline` instead"))
        }
        if content.is(TableHLine.self) { return .success(.hline(content)) }
        if content.is(TableVLine.self) { return .success(.vline(content)) }
        if content.is(TableCell.self) { return .success(.cell(content)) }
        var cell = TableCell(body: content)
        cell.span = content.span
        return .success(.cell(Content(cell)))
    }
}

/// Describes what kind of table cell this is. Port of `TableCellKind` in
/// `model/table.rs` — internal only, used by the grid resolver for
/// accessibility metadata.
public enum TableCellKind: Sendable, Hashable {
    case header(NonZeroU32, TableHeaderScope)
    case footer
    case data
}

extension TableCellKind: Default {
    public static var `default`: TableCellKind { .data }
}

/// Which table track a header cell labels. Port of `TableHeaderScope`
/// (`#[derive(Cast)]` upstream — string cast).
public enum TableHeaderScope: String, Sendable, Hashable {
    case both
    case column
    case row
}

extension TableHeaderScope: Default {
    public static var `default`: TableHeaderScope { .column }
}

extension TableHeaderScope: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.value(.str("both"), doc: "both row and column"),
                .value(.str("column"), doc: "column"),
                .value(.str("row"), doc: "row")])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return TableHeaderScope(rawValue: s.value) != nil
    }

    public func intoValue() -> Value { .str(Str(rawValue)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value,
              let scope = TableHeaderScope(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(scope)
    }
}

// MARK: - Elements

/// Arranges content in a table.
///
/// Port of `TableElem` in `model/table.rs` (element definition; the
/// synthesized `grid` field and `table_to_cellgrid` land with the grid
/// resolver). Upstream capabilities `Locatable`, `Tagged`,
/// `LocalName`, `Figurable` — `LocalName`/`Figurable` are deferred with
/// the accessibility/figure milestones.
public struct TableElem: NativeElement {
    public static let info = ElementInfo(
        name: "table",
        title: "Table",
        scope: TableElem.scope,
        fields: [
            FieldInfo(id: 0, name: "columns", settable: true),
            FieldInfo(id: 1, name: "rows", settable: true),
            FieldInfo(id: 2, name: "column-gutter", settable: true),
            FieldInfo(id: 3, name: "row-gutter", settable: true),
            FieldInfo(id: 4, name: "inset", settable: true),
            FieldInfo(id: 5, name: "align", settable: true),
            FieldInfo(id: 6, name: "fill", settable: true),
            FieldInfo(id: 7, name: "stroke", settable: true),
            FieldInfo(id: 8, name: "children"),
        ],
        capabilities: [.locatable, .tagged],
        setImpl: { _, args in
            var collected: [Style] = []
            let element = Element(TableElem.self)
            func prop(_ field: UInt8, _ value: Value) {
                collected.append(.property(Property(
                    elem: element, field: field, value: value)))
            }
            if let v: TrackSizings = try args.namedT("columns") { prop(0, v.intoValue()) }
            if let v: TrackSizings = try args.namedT("rows") { prop(1, v.intoValue()) }
            let gutters: (TrackSizings?, TrackSizings?) = try gutterFallback(
                &args, column: "column-gutter", row: "row-gutter")
            if let v = gutters.0 { prop(2, v.intoValue()) }
            if let v = gutters.1 { prop(3, v.intoValue()) }
            if let v: Spanned<Celled<Sides<Optional<Rel<Length>>>>, Span> =
                try args.namedT("inset") { prop(4, v.intoValue()) }
            if let v: Spanned<Celled<Smart<Alignment>>, Span> =
                try args.namedT("align") { prop(5, v.intoValue()) }
            if let v: Spanned<Celled<Optional<Paint>>, Span> =
                try args.namedT("fill") { prop(6, v.intoValue()) }
            if let v: Spanned<Celled<Sides<GridStroke>>, Span> =
                try args.namedT("stroke") { prop(7, v.intoValue()) }
            return Styles(collected)
        }
    )

    /// The column sizes.
    public var columns: TrackSizings = TrackSizings()
    /// The row sizes.
    public var rows: TrackSizings = TrackSizings()
    /// The gaps between columns.
    public var columnGutter: TrackSizings = TrackSizings()
    /// The gaps between rows.
    public var rowGutter: TrackSizings = TrackSizings()
    /// How much to pad the cells' content (5pt default upstream).
    public var inset: Spanned<Celled<Sides<Optional<Rel<Length>>>>, Span> =
        .detached(.value(.splat(.some(Rel<Length>(
            rel: .zero, abs: Length(abs: .pt(5.0), em: .zero))))))
    /// How to align the cells' content.
    public var align: Spanned<Celled<Smart<Alignment>>, Span> =
        .detached(.value(.auto))
    /// How to fill the cells.
    public var fill: Spanned<Celled<Optional<Paint>>, Span> =
        .detached(.value(nil))
    /// How to stroke the cells (black stroke default upstream).
    public var stroke: Spanned<Celled<Sides<GridStroke>>, Span> =
        .detached(.value(.splat(.some(.some(Stroke<Length>())))))
    /// The table children: cells, lines, headers, footers.
    public var children: [TableChild] = []

    /// Internal: accessibility summary (`#[internal] #[parse(None)]`).
    public var summary: Str? = nil

    public var span: Span = .detached

    /// Upstream `#[scope] impl TableElem`.
    static var scope: Scope {
        let scope = Scope()
        scope.define("cell", .function(Func(element: Element(TableCell.self))))
        scope.define("hline", .function(Func(element: Element(TableHLine.self))))
        scope.define("vline", .function(Func(element: Element(TableVLine.self))))
        scope.define("header", .function(Func(element: Element(TableHeader.self))))
        scope.define("footer", .function(Func(element: Element(TableFooter.self))))
        return scope
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return columns.intoValue()
        case 1: return rows.intoValue()
        case 2: return columnGutter.intoValue()
        case 3: return rowGutter.intoValue()
        case 4: return inset.intoValue()
        case 5: return align.intoValue()
        case 6: return fill.intoValue()
        case 7: return stroke.intoValue()
        case 8: return .array(ArrayValue(items: children.map { $0.intoValue() }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: columns = try TrackSizings.fromValue(value).get()
        case 1: rows = try TrackSizings.fromValue(value).get()
        case 2: columnGutter = try TrackSizings.fromValue(value).get()
        case 3: rowGutter = try TrackSizings.fromValue(value).get()
        case 4: inset = try Spanned.fromValue(value).get()
        case 5: align = try Spanned.fromValue(value).get()
        case 6: fill = try Spanned.fromValue(value).get()
        case 7: stroke = try Spanned.fromValue(value).get()
        default: break
        }
    }
}

/// A repeatable table header. Port of `TableHeader` in `model/table.rs`.
public struct TableHeader: NativeElement {
    public static let info = ElementInfo(
        name: "header",
        title: "Table Header",
        fields: [
            FieldInfo(id: 0, name: "repeat", settable: true),
            FieldInfo(id: 1, name: "level", settable: true),
            FieldInfo(id: 2, name: "children"),
        ],
        capabilities: [.tagged]
    )

    /// Whether this header should be repeated across pages.
    public var `repeat`: Bool = true
    /// The level of the header (must not be zero).
    public var level: NonZeroU32 = NonZeroU32(value: 1)
    /// The cells and lines within the header.
    public var children: [TableItem] = []

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(`repeat`)
        case 1: return level.intoValue()
        case 2: return .array(ArrayValue(items: children.map { $0.intoValue() }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: `repeat` = try Bool.fromValue(value).get()
        case 1: level = try NonZeroU32.fromValue(value).get()
        default: break
        }
    }
}

/// A repeatable table footer. Port of `TableFooter` in `model/table.rs`.
public struct TableFooter: NativeElement {
    public static let info = ElementInfo(
        name: "footer",
        title: "Table Footer",
        fields: [
            FieldInfo(id: 0, name: "repeat", settable: true),
            FieldInfo(id: 1, name: "children"),
        ],
        capabilities: [.tagged]
    )

    /// Whether this footer should be repeated across pages.
    public var `repeat`: Bool = true
    /// The cells and lines within the footer.
    public var children: [TableItem] = []

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(`repeat`)
        case 1: return .array(ArrayValue(items: children.map { $0.intoValue() }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0 { `repeat` = try Bool.fromValue(value).get() }
    }
}

/// A horizontal line in the table. Port of `TableHLine` in
/// `model/table.rs`.
public struct TableHLine: NativeElement {
    public static let info = ElementInfo(
        name: "hline",
        title: "Table Horizontal Line",
        fields: [
            FieldInfo(id: 0, name: "y", settable: true),
            FieldInfo(id: 1, name: "start", settable: true),
            FieldInfo(id: 2, name: "end", settable: true),
            FieldInfo(id: 3, name: "stroke", settable: true),
            FieldInfo(id: 4, name: "position", settable: true),
        ],
        capabilities: [.tagged]
    )

    /// The row above which the line is placed.
    public var y: Smart<Int> = .auto
    /// The column at which the line starts (inclusive).
    public var start: Int = 0
    /// The column before which the line ends (exclusive).
    public var end: NonZeroUsize? = nil
    /// The line's stroke (`none` removes previous lines in range).
    public var stroke: Stroke<Length>? = Stroke<Length>()
    /// Whether the line is placed at the top or bottom of row `y`.
    public var position: OuterVAlignment = .top

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return y.intoValue()
        case 1: return .int(Int64(start))
        case 2: return end?.intoValue() ?? Value.none
        case 3: return stroke?.intoValue() ?? Value.none
        case 4: return position.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: y = try Smart<Int>.fromValue(value).get()
        case 1: start = try Int.fromValue(value).get()
        case 2: end = try NonZeroUsize?.fromValue(value).get()
        case 3: stroke = try Stroke<Length>?.fromValue(value).get()
        case 4: position = try OuterVAlignment.fromValue(value).get()
        default: break
        }
    }
}

/// A vertical line in the table. Port of `TableVLine` in `model/table.rs`.
public struct TableVLine: NativeElement {
    public static let info = ElementInfo(
        name: "vline",
        title: "Table Vertical Line",
        fields: [
            FieldInfo(id: 0, name: "x", settable: true),
            FieldInfo(id: 1, name: "start", settable: true),
            FieldInfo(id: 2, name: "end", settable: true),
            FieldInfo(id: 3, name: "stroke", settable: true),
            FieldInfo(id: 4, name: "position", settable: true),
        ],
        capabilities: [.tagged]
    )

    /// The column before which the line is placed.
    public var x: Smart<Int> = .auto
    /// The row at which the line starts (inclusive).
    public var start: Int = 0
    /// The row on top of which the line ends (exclusive).
    public var end: NonZeroUsize? = nil
    /// The line's stroke (`none` removes previous lines in range).
    public var stroke: Stroke<Length>? = Stroke<Length>()
    /// Whether the line is placed at the start or end of column `x`.
    public var position: OuterHAlignment = .start

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return x.intoValue()
        case 1: return .int(Int64(start))
        case 2: return end?.intoValue() ?? Value.none
        case 3: return stroke?.intoValue() ?? Value.none
        case 4: return position.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: x = try Smart<Int>.fromValue(value).get()
        case 1: start = try Int.fromValue(value).get()
        case 2: end = try NonZeroUsize?.fromValue(value).get()
        case 3: stroke = try Stroke<Length>?.fromValue(value).get()
        case 4: position = try OuterHAlignment.fromValue(value).get()
        default: break
        }
    }
}

/// A cell in the table. Port of `TableCell` in `model/table.rs`.
public struct TableCell: NativeElement {
    public static let info = ElementInfo(
        name: "cell",
        title: "Table Cell",
        fields: [
            FieldInfo(id: 0, name: "body", required: true, settable: false, hasDefault: false),
            FieldInfo(id: 1, name: "x", settable: true),
            FieldInfo(id: 2, name: "y", settable: true),
            FieldInfo(id: 3, name: "colspan", settable: true),
            FieldInfo(id: 4, name: "rowspan", settable: true),
            FieldInfo(id: 5, name: "inset", settable: true),
            FieldInfo(id: 6, name: "align", settable: true),
            FieldInfo(id: 7, name: "fill", settable: true),
            FieldInfo(id: 8, name: "stroke", settable: true),
            FieldInfo(id: 9, name: "breakable", settable: true),
        ],
        capabilities: [.tagged]
    )

    /// The cell's body.
    public var body: Content
    /// The cell's column (zero-indexed).
    public var x: Smart<Int> = .auto
    /// The cell's row (zero-indexed).
    public var y: Smart<Int> = .auto
    /// The amount of columns spanned by this cell.
    public var colspan: NonZeroUsize = NonZeroUsize(value: 1)
    /// The amount of rows spanned by this cell.
    public var rowspan: NonZeroUsize = NonZeroUsize(value: 1)
    /// The cell's inset override.
    public var inset: Smart<Sides<Optional<Rel<Length>>>> = .auto
    /// The cell's alignment override.
    public var align: Smart<Alignment> = .auto
    /// The cell's fill override.
    public var fill: Smart<Optional<Paint>> = .auto
    /// The cell's stroke override.
    public var stroke: Sides<GridStroke> = .splat(nil)
    /// Whether rows spanned by this cell can be placed on different pages.
    public var breakable: Smart<Bool> = .auto
    /// Internal: what kind of cell this is
    /// (`#[internal] #[parse(Some(Smart::Auto))]`).
    public var kind: Smart<TableCellKind> = .auto
    /// Internal: whether the cell is in a repeated header/footer
    /// (`#[internal] #[parse(Some(false))]`).
    public var isRepeated: Bool = false

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// A default cell wrapping plain content (upstream `From<Content>`).
    public static func cell(_ content: Content) -> TableCell {
        content.is(TableCell.self) ? (content.to(TableCell.self) ?? TableCell(body: content))
            : TableCell(body: content)
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return body.intoValue()
        case 1: return x.intoValue()
        case 2: return y.intoValue()
        case 3: return colspan.intoValue()
        case 4: return rowspan.intoValue()
        case 5: return inset.intoValue()
        case 6: return align.intoValue()
        case 7: return fill.intoValue()
        case 8: return stroke.intoValue()
        case 9: return breakable.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 1: x = try Smart<Int>.fromValue(value).get()
        case 2: y = try Smart<Int>.fromValue(value).get()
        case 3: colspan = try NonZeroUsize.fromValue(value).get()
        case 4: rowspan = try NonZeroUsize.fromValue(value).get()
        case 5: inset = try Smart<Sides<Optional<Rel<Length>>>>.fromValue(value).get()
        case 6: align = try Smart<Alignment>.fromValue(value).get()
        case 7: fill = try Smart<Optional<Paint>>.fromValue(value).get()
        case 8: stroke = try Sides<GridStroke>.fromValue(value).get()
        case 9: breakable = try Smart<Bool>.fromValue(value).get()
        default: break
        }
    }
}
