import TypstSyntax
import TypstUtils

// Layout element definitions ported from `typst-library/src/layout/`:
// `pad.rs`, `stack.rs`, `hide.rs`, `place.rs`, `columns.rs`, `layout.rs`.
// Their layout rules land with `typst-layout`; these are the element
// data types, constructors, and casts.

// MARK: - Padding

/// Padding around content.
///
/// Port of `PadElem` in `layout/pad.rs`. The `x`/`y`/`rest` arguments are
/// constructor-only aliases resolved into the four side fields.
public struct PadElem: NativeElement {
    public static let info = ElementInfo(
        name: "pad",
        title: "Padding",
        fields: [
            FieldInfo(id: 0, name: "left", settable: true),
            FieldInfo(id: 1, name: "top", settable: true),
            FieldInfo(id: 2, name: "right", settable: true),
            FieldInfo(id: 3, name: "bottom", settable: true),
            FieldInfo(id: 4, name: "body", required: true, settable: false, hasDefault: false),
        ],
        capabilities: []
    )

    /// The left padding.
    public var left: Rel<Length> = .zero()
    /// The top padding.
    public var top: Rel<Length> = .zero()
    /// The right padding.
    public var right: Rel<Length> = .zero()
    /// The bottom padding.
    public var bottom: Rel<Length> = .zero()
    /// The padded content.
    public var body: Content = .empty

    public var span: Span = .detached

    public init(left: Rel<Length> = .zero(), top: Rel<Length> = .zero(),
                right: Rel<Length> = .zero(), bottom: Rel<Length> = .zero(),
                body: Content) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return left.intoValue()
        case 1: return top.intoValue()
        case 2: return right.intoValue()
        case 3: return bottom.intoValue()
        case 4: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .relative(r)): left = r
        case (1, let .relative(r)): top = r
        case (2, let .relative(r)): right = r
        case (3, let .relative(r)): bottom = r
        case (4, let .content(c)): body = c
        default: break
        }
    }

    /// Custom construct: `rest`/`x`/`y` are aliases for the side fields
    /// (upstream `#[parse]` blocks).
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        let all: Rel<Length>? = try args.namedT("rest") ?? args.findT()
        let x: Rel<Length>? = try args.namedT("x") ?? all
        let y: Rel<Length>? = try args.namedT("y") ?? all
        var elem = PadElem(
            left: try args.namedT("left") ?? x ?? Rel<Length>.zero(),
            top: try args.namedT("top") ?? y ?? Rel<Length>.zero(),
            right: try args.namedT("right") ?? x ?? Rel<Length>.zero(),
            bottom: try args.namedT("bottom") ?? y ?? Rel<Length>.zero(),
            body: try args.expectT("body")
        )
        elem.span = args.span
        return Content(elem)
    }
}

// MARK: - Stack

/// A child of a `stack`: either spacing or a block.
///
/// Port of `StackChild` in `layout/stack.rs`.
public enum StackChild: Sendable, Hashable {
    /// Explicit spacing between blocks.
    case spacing(Spacing)
    /// A block-level child.
    case block(Content)
}

extension StackChild: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .union([Spacing.input, .type(Type.of(Content.self))]) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Spacing.castable(value) || Content.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .spacing(s): return s.intoValue()
        case let .block(c): return c.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Spacing.castable(value), case .success(let s) = Spacing.fromValue(value) {
            return .success(.spacing(s))
        }
        if Content.castable(value), case .success(let c) = Content.fromValue(value) {
            return .success(.block(c))
        }
        return .failure(error(value))
    }
}

/// Stacks content along an axis.
///
/// Port of `StackElem` in `layout/stack.rs`.
public struct StackElem: NativeElement {
    public static let info = ElementInfo(
        name: "stack",
        fields: [
            FieldInfo(id: 0, name: "dir", settable: true),
            FieldInfo(id: 1, name: "spacing", settable: true),
            FieldInfo(id: 2, name: "children"),
        ],
        capabilities: []
    )

    /// The direction along which the children are stacked.
    public var dir: Dir = .ttb
    /// The spacing between children (overridable per-child).
    public var spacing: Spacing?
    /// The stacked children (blocks and explicit spacing).
    public var children: [StackChild] = []

    public var span: Span = .detached

    public init(dir: Dir = .ttb, spacing: Spacing? = nil,
                children: [StackChild]) {
        self.dir = dir
        self.spacing = spacing
        self.children = children
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return dir.intoValue()
        case 1: return spacing?.intoValue() ?? Value.none
        case 2: return .array(ArrayValue(children.map { $0.intoValue() }))
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .dynamic(d)):
            if let v = d.downcast(Dir.self) { dir = v }
        case (1, .none): spacing = nil
        case (1, let v) where Spacing.castable(v):
            if case .success(let s) = Spacing.fromValue(v) { spacing = s }
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = StackElem(children: try args.allT())
        if let dir: Dir = try args.namedT("dir") { elem.dir = dir }
        if let spacing: Spacing = try args.namedT("spacing") { elem.spacing = spacing }
        try args.finishT()
        elem.span = args.span
        return Content(elem)
    }
}

// MARK: - Hide

/// Hides content without affecting layout.
///
/// Port of `HideElem` in `layout/hide.rs`.
public struct HideElem: NativeElement {
    public static let info = ElementInfo(
        name: "hide",
        fields: [
            FieldInfo(id: 0, name: "body", required: true, settable: false, hasDefault: false),
        ],
        capabilities: [.tagged]
    )

    /// The hidden content.
    public var body: Content = .empty

    /// Internal ghost field (upstream `#[internal] #[ghost]`): set by
    /// realization, not exposed through `fields`.
    public var hidden: Bool = false

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? body.intoValue() : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0, case let .content(c) = value { body = c }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = HideElem(body: try args.expectT("body"))
        try args.finishT()
        elem.span = args.span
        return Content(elem)
    }
}

// MARK: - Place

/// The scope in which a `place` element is placed.
///
/// Port of `PlacementScope` in `layout/place.rs`.
public enum PlacementScope: String, Sendable, Hashable, CaseIterable {
    /// Place within the current column.
    case column
    /// Place on the parent page.
    case parent
}

extension PlacementScope: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { .type(Type.of(Str.self)) }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return PlacementScope(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value,
              let scope = PlacementScope(rawValue: s.value)
        else { return .failure(error(value)) }
        return .success(scope)
    }
}

/// Places content at an absolute position.
///
/// Port of `PlaceElem` in `layout/place.rs`. The nested `flush` element is
/// available as `place.flush` via `scope`.
public struct PlaceElem: NativeElement {
    public static let info = ElementInfo(
        name: "place",
        scope: PlaceElem.scope,
        fields: [
            FieldInfo(id: 0, name: "alignment", settable: true),
            FieldInfo(id: 1, name: "scope", settable: true),
            FieldInfo(id: 2, name: "float", settable: true),
            FieldInfo(id: 3, name: "clearance", settable: true),
            FieldInfo(id: 4, name: "dx", settable: true),
            FieldInfo(id: 5, name: "dy", settable: true),
            FieldInfo(id: 6, name: "body", required: true, settable: false, hasDefault: false),
        ],
        capabilities: [.locatable, .tagged, .unqueriable]
    )

    /// The placed content.
    public var body: Content = .empty
    /// The alignment of the content (positional).
    public var alignment: Smart<Alignment> = .custom(.start)
    /// Whether the element is placed in the column or on the parent page.
    public var scope: PlacementScope = .column
    /// Whether the element floats in the content flow.
    public var float: Bool = false
    /// The clearance around floating placements.
    public var clearance: Length = Length(Em(1.5))
    /// The horizontal offset.
    public var dx: Rel<Length> = .zero()
    /// The vertical offset.
    public var dy: Rel<Length> = .zero()

    public var span: Span = .detached

    public init(body: Content, alignment: Smart<Alignment> = .custom(.start),
                scope: PlacementScope = .column, float: Bool = false,
                clearance: Length = Length(Em(1.5)),
                dx: Rel<Length> = .zero(), dy: Rel<Length> = .zero()) {
        self.body = body
        self.alignment = alignment
        self.scope = scope
        self.float = float
        self.clearance = clearance
        self.dx = dx
        self.dy = dy
    }

    /// Upstream `#[scope] impl PlaceElem { #[elem] type FlushElem; }`.
    static var scope: Scope {
        let scope = Scope()
        scope.define("flush", .function(Func(element: Element(FlushElem.self))))
        return scope
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return alignment.intoValue()
        case 1: return scope.intoValue()
        case 2: return .bool(float)
        case 3: return .length(clearance)
        case 4: return dx.intoValue()
        case 5: return dy.intoValue()
        case 6: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, .auto): alignment = .auto
        case (0, let .dynamic(d)):
            if let v = d.downcast(Alignment.self) { alignment = .custom(v) }
        case (1, let .str(s)):
            if let v = PlacementScope(rawValue: s.value) { scope = v }
        case (2, let .bool(b)): float = b
        case (3, let .length(l)):
            guard case .success(let v) = Length.fromValue(.length(l)) else { break }
            clearance = v
        case (4, let .relative(r)): dx = r
        case (5, let .relative(r)): dy = r
        case (6, let .content(c)): body = c
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        // Field order matters: the positional `alignment` must be consumed
        // before `body` takes the remaining positional argument.
        var elem = PlaceElem(body: .empty)
        if let alignment: Smart<Alignment> = try args.findT() {
            elem.alignment = alignment
        }
        if let scope: PlacementScope = try args.namedT("scope") { elem.scope = scope }
        if let float: Bool = try args.namedT("float") { elem.float = float }
        if let clearance: Length = try args.namedT("clearance") { elem.clearance = clearance }
        if let dx: Rel<Length> = try args.namedT("dx") { elem.dx = dx }
        if let dy: Rel<Length> = try args.namedT("dy") { elem.dy = dy }
        elem.body = try args.expectT("body")
        try args.finishT()
        elem.span = args.span
        return Content(elem)
    }
}

// MARK: - Columns

/// Lays out content in columns.
///
/// Port of `ColumnsElem` in `layout/columns.rs`.
public struct ColumnsElem: NativeElement {
    public static let info = ElementInfo(
        name: "columns",
        fields: [
            FieldInfo(id: 0, name: "count", settable: true),
            FieldInfo(id: 1, name: "gutter", settable: true),
            FieldInfo(id: 2, name: "balanced", settable: true),
            FieldInfo(id: 3, name: "separator", settable: true),
            FieldInfo(id: 4, name: "body", required: true, settable: false, hasDefault: false),
        ],
        capabilities: []
    )

    /// The number of columns.
    public var count: NonZeroUsize = NonZeroUsize(value: 2)
    /// The gap between columns.
    public var gutter: Rel<Length> = Rel<Length>(Ratio(0.04))
    /// Whether to balance the columns' heights.
    public var balanced: Bool = false
    /// The separator placed between columns.
    public var separator: Content?
    /// The columnized content.
    public var body: Content = .empty

    public var span: Span = .detached

    public init(count: NonZeroUsize = NonZeroUsize(value: 2),
                gutter: Rel<Length> = Rel<Length>(Ratio(0.04)),
                balanced: Bool = false, separator: Content? = nil,
                body: Content) {
        self.count = count
        self.gutter = gutter
        self.balanced = balanced
        self.separator = separator
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .int(Int64(count.value))
        case 1: return gutter.intoValue()
        case 2: return .bool(balanced)
        case 3: return separator?.intoValue() ?? Value.none
        case 4: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .int(v)) where v > 0:
            count = NonZeroUsize(value: Int(v))
        case (1, let .relative(r)): gutter = r
        case (2, let .bool(b)): balanced = b
        case (3, .none): separator = nil
        case (3, let .content(c)): separator = c
        case (4, let .content(c)): body = c
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        // Field order matters: positional `count` is consumed before `body`.
        var elem = ColumnsElem(body: .empty)
        if let count: NonZeroUsize = try args.findT() { elem.count = count }
        if let gutter: Rel<Length> = try args.namedT("gutter") { elem.gutter = gutter }
        if let balanced: Bool = try args.namedT("balanced") { elem.balanced = balanced }
        if let separator: Content = try args.namedT("separator") { elem.separator = separator }
        elem.body = try args.expectT("body")
        try args.finishT()
        elem.span = args.span
        return Content(elem)
    }
}

/// A weak column break.
///
/// Port of `ColbreakElem` in `layout/columns.rs`.
public struct ColbreakElem: NativeElement {
    public static let info = ElementInfo(
        name: "colbreak",
        title: "Column Break",
        fields: [
            FieldInfo(id: 0, name: "weak", settable: true),
        ],
        capabilities: []
    )

    /// Whether the break collapses at column boundaries.
    public var weak: Bool = false

    public var span: Span = .detached

    public init(weak: Bool = false) { self.weak = weak }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .bool(weak) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0, case let .bool(b) = value { weak = b }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = ColbreakElem()
        if let weak: Bool = try args.namedT("weak") { elem.weak = weak }
        try args.finishT()
        elem.span = args.span
        return Content(elem)
    }
}

// MARK: - Layout function

/// Custom layout via a function.
///
/// Port of `LayoutElem` in `layout/layout.rs`. The `layout` function
/// itself is registered alongside `measure` once `Frame` lands.
public struct LayoutElem: NativeElement {
    public static let info = ElementInfo(
        name: "layout",
        fields: [
            FieldInfo(id: 0, name: "func", required: true, settable: false, hasDefault: false),
        ],
        capabilities: [.locatable]
    )

    /// The layout function.
    public var `func`: Func

    public var span: Span = .detached

    public init(`func`: Func) { self.func = `func` }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .function(`func`) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0, case let .function(f) = value { `func` = f }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = LayoutElem(func: try args.expectT("func"))
        try args.finishT()
        elem.span = args.span
        return Content(elem)
    }
}
