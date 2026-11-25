import Foundation
import TypstSyntax

/// Track sizing definitions. Port of `TrackSizings` in
/// `layout/grid/mod.rs` — a list of `Sizing` values.
public struct TrackSizings: Sendable, Hashable {
    public var tracks: [Sizing]

    public init(tracks: [Sizing] = []) { self.tracks = tracks }
}

extension TrackSizings: Default {
    public static var `default`: TrackSizings { TrackSizings() }
}

extension TrackSizings: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([Sizing.input, NonZeroUsize.input, ArrayValue.input])
    }
    public static var output: CastInfo { .type(Type.of(ArrayValue.self)) }

    public static func castable(_ value: Value) -> Bool {
        Sizing.castable(value) || NonZeroUsize.castable(value)
            || ArrayValue.castable(value)
    }

    public func intoValue() -> Value {
        .array(ArrayValue(items: tracks.map { $0.intoValue() }))
    }

    /// Upstream `cast!`: a single `Sizing`, a positive count of `auto`
    /// tracks, or an array of sizings.
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Sizing.castable(value) {
            return Sizing.fromValue(value).map {
                TrackSizings(tracks: [$0])
            }
        }
        if NonZeroUsize.castable(value) {
            return NonZeroUsize.fromValue(value).map { count in
                TrackSizings(tracks: [Sizing](repeating: .auto, count: count.value))
            }
        }
        if case let .array(array) = value {
            var tracks: [Sizing] = []
            for item in array.items {
                switch Sizing.fromValue(item) {
                case let .success(s): tracks.append(s)
                case let .failure(e): return .failure(e)
                }
            }
            return .success(TrackSizings(tracks: tracks))
        }
        return .failure(error(value))
    }
}

/// A stroke that can be folded with the cell and parent element values.
/// Port of `GridStroke` in `layout/grid/resolve.rs`:
/// `Option<Option<Arc<Stroke<Length>>>>` — outer `nil` means unspecified
/// (inherit), `.some(nil)` means explicitly removed, `.some(.some(s))` a
/// concrete stroke.
public typealias GridStroke = Optional<Optional<Stroke<Length>>>

/// A value that can be configured per cell. Port of `Celled<T>` in
/// `layout/grid/mod.rs`.
public enum Celled<T> {
    /// A bare value, the same for all cells.
    case value(T)
    /// A closure mapping from cell coordinates to a value.
    case `func`(Func)
    /// An array of values corresponding to each column, cycled.
    case array([T])
}

extension Celled: Sendable where T: Sendable & Hashable {}
extension Celled: Equatable where T: Equatable {}
extension Celled: Hashable where T: Hashable {}

extension Celled: Default where T: Default {
    public static var `default`: Celled<T> { .value(T.default) }
}

extension Celled: Castable, IntoValue, FromValue
    where T: Castable & IntoValue & FromValue {

    public static var input: CastInfo {
        .union([T.input, ArrayValue.input, Func.input])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        ArrayValue.castable(value) || Func.castable(value) || T.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .value(v): return v.intoValue()
        case let .`func`(f): return f.intoValue()
        case let .array(a):
            return .array(ArrayValue(items: a.map { $0.intoValue() }))
        }
    }

    /// Upstream `FromValue for Celled<T>`: func → `.func`, array → `.array`,
    /// castable → `.value`.
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if case let .function(f) = value { return .success(.`func`(f)) }
        if case let .array(array) = value {
            var items: [T] = []
            for item in array.items {
                switch T.fromValue(item) {
                case let .success(v): items.append(v)
                case let .failure(e): return .failure(e)
                }
            }
            return .success(.array(items))
        }
        if T.castable(value) {
            return T.fromValue(value).map { .value($0) }
        }
        return .failure(error(value))
    }
}

extension Celled: Fold where T: Fold {
    /// Two bare values fold; anything else, the inner wins
    /// (upstream `Fold for Celled<T>`).
    public static func fold(_ inner: Celled<T>, _ outer: Celled<T>) -> Celled<T> {
        switch (inner, outer) {
        case let (.value(i), .value(o)):
            return .value(T.fold(i, o))
        case (let s, _):
            return s
        }
    }
}

extension Celled: Resolve where T: Resolve {
    public typealias Output = ResolvedCelled<T>

    /// Resolve the celled value's components against styles
    /// (upstream `Resolve for Celled<T>`).
    public func resolve(_ styles: StyleChain) -> ResolvedCelled<T> {
        switch self {
        case let .value(v): return ResolvedCelled(.value(v.resolve(styles)))
        case let .`func`(f): return ResolvedCelled(.`func`(f))
        case let .array(values):
            return ResolvedCelled(.array(
                values.map { $0.resolve(styles) }))
        }
    }
}

/// Resolve a celled value at a cell position, calling the closure with the
/// cell's column and row indices when configured as a function.
/// Port of `Celled::resolve` in `layout/grid/mod.rs`.
extension Celled where T: Default & FromValue {
    /// Upstream `Celled::resolve` — calls the closure with `(x, y)`.
    public func resolve(engine: inout Engine, styles: StyleChain,
                        x: Int, y: Int, span: Span) -> SourceResult<T> {
        switch self {
        case let .value(v): return .success(v)
        case let .`func`(f):
            return f.call(
                engine: &engine,
                context: Context(styles: styles),
                args: Args(span: span, values: [x, y]),
                span: span)
        case let .array(array):
            guard !array.isEmpty else { return .success(T.default) }
            return .success(array[x % array.count])
        }
    }
}

/// The result of resolving a `Celled`'s value according to styles.
/// Port of `ResolvedCelled<T>` in `layout/grid/mod.rs`.
public struct ResolvedCelled<T: Resolve> {
    var celled: Celled<T.Output>

    public init(_ celled: Celled<T.Output>) { self.celled = celled }
}

extension ResolvedCelled: Sendable where T.Output: Sendable & Hashable {}
extension ResolvedCelled: Equatable where T.Output: Equatable {}
extension ResolvedCelled: Hashable where T.Output: Hashable {}

extension ResolvedCelled where T: FromValue {
    /// Resolve the value based on the cell position
    /// (upstream `ResolvedCelled::resolve`).
    public func resolve(engine: inout Engine, styles: StyleChain,
                        x: Int, y: Int, span: Span) -> SourceResult<T.Output>
        where T.Output: Default {
        switch celled {
        case let .value(v): return .success(v)
        case let .`func`(f):
            return f.callValue(
                engine: &engine,
                context: Context(styles: styles),
                args: Args(span: span, values: [x, y]),
                span: span)
                .flatMap { value in
                    T.fromValue(value).map { $0.resolve(styles) }.at(span)
                }
        case let .array(array):
            guard !array.isEmpty else { return .success(T.Output.default) }
            return .success(array[x % array.count])
        }
    }
}

// MARK: - Child/item casts

/// Any child of a grid element. Port of `GridChild` in
/// `layout/grid/mod.rs`.
public enum GridChild: Sendable, Hashable {
    case header(Content)
    case footer(Content)
    case item(GridItem)
}

extension GridChild: Castable, IntoValue, FromValue {
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

    /// Port of `TryFrom<Content> for GridChild`: rejects `table.header` /
    /// `table.footer` with hints, then header → footer → item.
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .content(content) = value else {
            return .failure(error(value))
        }
        return contentToChild(content)
    }

    static func contentToChild(_ content: Content) -> HintedStrResult<GridChild> {
        if content.is(TableHeader.self) {
            return .failure(HintedString(
                "cannot use `table.header` as a grid header")
                .withHint("use `grid.header` instead"))
        }
        if content.is(TableFooter.self) {
            return .failure(HintedString(
                "cannot use `table.footer` as a grid footer")
                .withHint("use `grid.footer` instead"))
        }
        if content.is(GridHeader.self) { return .success(.header(content)) }
        if content.is(GridFooter.self) { return .success(.footer(content)) }
        return GridItem.contentToItem(content).map { .item($0) }
    }
}

/// A grid item: hline, vline, or cell. Port of `GridItem` in
/// `layout/grid/mod.rs`.
public enum GridItem: Sendable, Hashable {
    case hline(Content)
    case vline(Content)
    case cell(Content)
}

extension GridItem: Castable, IntoValue, FromValue {
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

    /// Port of `TryFrom<Content> for GridItem`: rejects misplaced headers,
    /// footers, and `table.*` elements with hints; wraps plain content in a
    /// `grid.cell`.
    static func contentToItem(_ content: Content) -> HintedStrResult<GridItem> {
        if content.is(GridHeader.self) || content.is(TableHeader.self) {
            return .failure(HintedString(
                "cannot place a grid header within another header or footer"))
        }
        if content.is(GridFooter.self) || content.is(TableFooter.self) {
            return .failure(HintedString(
                "cannot place a grid footer within another footer or header"))
        }
        if content.is(TableCell.self) {
            return .failure(HintedString(
                "cannot use `table.cell` as a grid cell")
                .withHint("use `grid.cell` instead"))
        }
        if content.is(TableHLine.self) {
            return .failure(HintedString(
                "cannot use `table.hline` as a grid line")
                .withHint("use `grid.hline` instead"))
        }
        if content.is(TableVLine.self) {
            return .failure(HintedString(
                "cannot use `table.vline` as a grid line")
                .withHint("use `grid.vline` instead"))
        }
        if content.is(GridHLine.self) { return .success(.hline(content)) }
        if content.is(GridVLine.self) { return .success(.vline(content)) }
        if content.is(GridCell.self) { return .success(.cell(content)) }
        var cell = GridCell(body: content)
        cell.span = content.span
        return .success(.cell(Content(cell)))
    }
}

// MARK: - Elements

/// Arranges content in a grid.
///
/// Port of `GridElem` in `layout/grid/mod.rs` (element definition; the
/// `grid` field synthesized by `grid_to_cellgrid` lands with the grid
/// resolver).
public struct GridElem: NativeElement {
    public static let info = ElementInfo(
        name: "grid",
        title: "Grid",
        scope: GridElem.scope,
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
        capabilities: [.tagged],
        // `gutter` is an external construct-only arg upstream; set rules
        // parse it through the `column-gutter`/`row-gutter` `#[parse]`
        // fallback, so a custom `setImpl` mirrors that.
        setImpl: { _, args in
            var collected: [Style] = []
            let element = Element(GridElem.self)
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
    /// How much to pad the cells' content.
    public var inset: Spanned<Celled<Sides<Optional<Rel<Length>>>>, Span> =
        .detached(.value(.splat(nil)))
    /// How to align the cells' content.
    public var align: Spanned<Celled<Smart<Alignment>>, Span> =
        .detached(.value(.auto))
    /// How to fill the cells.
    public var fill: Spanned<Celled<Optional<Paint>>, Span> =
        .detached(.value(nil))
    /// How to stroke the cells.
    public var stroke: Spanned<Celled<Sides<GridStroke>>, Span> =
        .detached(.value(.splat(nil)))
    /// The grid children: cells, lines, headers, footers.
    public var children: [GridChild] = []

    public var span: Span = .detached

    /// Upstream `#[scope] impl GridElem` — nested `cell`, `hline`, `vline`,
    /// `header`, `footer` elements.
    static var scope: Scope {
        let scope = Scope()
        scope.define("cell", .function(Func(element: Element(GridCell.self))))
        scope.define("hline", .function(Func(element: Element(GridHLine.self))))
        scope.define("vline", .function(Func(element: Element(GridVLine.self))))
        scope.define("header", .function(Func(element: Element(GridHeader.self))))
        scope.define("footer", .function(Func(element: Element(GridFooter.self))))
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

/// A repeatable grid header. Port of `GridHeader` in `layout/grid/mod.rs`.
public struct GridHeader: NativeElement {
    public static let info = ElementInfo(
        name: "header",
        title: "Grid Header",
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
    public var children: [GridItem] = []

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

/// A repeatable grid footer. Port of `GridFooter` in `layout/grid/mod.rs`.
public struct GridFooter: NativeElement {
    public static let info = ElementInfo(
        name: "footer",
        title: "Grid Footer",
        fields: [
            FieldInfo(id: 0, name: "repeat", settable: true),
            FieldInfo(id: 1, name: "children"),
        ],
        capabilities: [.tagged]
    )

    /// Whether this footer should be repeated across pages.
    public var `repeat`: Bool = true
    /// The cells and lines within the footer.
    public var children: [GridItem] = []

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

/// A horizontal line in the grid. Port of `GridHLine` in
/// `layout/grid/mod.rs`.
public struct GridHLine: NativeElement {
    public static let info = ElementInfo(
        name: "hline",
        title: "Grid Horizontal Line",
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

/// A vertical line in the grid. Port of `GridVLine` in
/// `layout/grid/mod.rs`.
public struct GridVLine: NativeElement {
    public static let info = ElementInfo(
        name: "vline",
        title: "Grid Vertical Line",
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

/// A cell in the grid. Port of `GridCell` in `layout/grid/mod.rs`.
public struct GridCell: NativeElement {
    public static let info = ElementInfo(
        name: "cell",
        title: "Grid Cell",
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
    /// Internal: whether the cell is in a repeated header/footer
    /// (`#[internal] #[parse(Some(false))]` upstream).
    public var isRepeated: Bool = false
    /// Whether rows spanned by this cell can be placed on different pages.
    public var breakable: Smart<Bool> = .auto

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// A default cell wrapping plain content (upstream `From<Content>`).
    public static func cell(_ content: Content) -> GridCell {
        content.is(GridCell.self) ? (content.to(GridCell.self) ?? GridCell(body: content))
            : GridCell(body: content)
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
