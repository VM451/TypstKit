import Foundation
import TypstSyntax
import TypstUtils

// Port of the math elements evaluated by `typst-eval/src/math.rs`:
// equation, align point, lr, attach/primes, frac, root.
// Field sets cover evaluation needs; style/numbering fields land with
// the math layout milestone.

/// A mathematical equation. Port of `EquationElem` in `math/equation.rs`.
public struct EquationElem: NativeElement {
    public static let info = ElementInfo(
        name: "equation",
        title: "Equation",
        fields: [
            FieldInfo(id: 0, name: "block"),
            FieldInfo(id: 1, name: "numbering"),
            FieldInfo(id: 2, name: "number-align"),
            FieldInfo(id: 3, name: "supplement"),
            FieldInfo(id: 4, name: "alt"),
            FieldInfo(id: 5, name: "body", required: true),
            FieldInfo(id: 6, name: "size"),
        ],
        capabilities: [.locatable, .labelled, .counted, .queriable, .tagged]
    )

    /// Whether the equation is displayed as a separate block.
    public var block: Bool = false

    /// The equation's numbering (deferred type — stored raw).
    public var numbering: Value? = nil

    /// How the numbering is aligned (deferred type — stored raw).
    public var numberAlign: Value? = nil

    /// Additional content for a reference to the equation.
    public var supplement: Spanned<Smart<Supplement?>, Span> =
        Spanned(.auto, span: .detached)

    /// Alternative plain-text representation.
    public var alt: String? = nil

    /// The equation's body.
    public var body: Content

    /// The math size (deferred type — stored raw).
    public var size: Value? = nil

    public var span: Span = .detached

    /// Create with a body (upstream `EquationElem::new`).
    public init(body: Content) { self.body = body }

    /// Set the block flag (upstream `with_block`).
    public func withBlock(_ block: Bool) -> EquationElem {
        var copy = self
        copy.block = block
        return copy
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(block)
        case 1: return numbering ?? .none
        case 2: return numberAlign ?? .none
        case 3:
            switch supplement.value {
            case .auto: return .auto
            case let .custom(s?):
                switch s {
                case let .content(c): return .content(c)
                case let .function(f): return .function(f)
                }
            case .custom(nil): return .none
            }
        case 4: return alt.map { .str(Str($0)) } ?? .none
        case 5: return .content(body)
        case 6: return size ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .bool(b)): block = b
        case (4, let .str(s)): alt = s.value
        case (4, .none): alt = nil
        case (5, let .content(c)): body = c
        default: break
        }
    }
}

/// A math alignment point. Port of `AlignPointElem` in `math/mod.rs`.
public struct AlignPointElem: NativeElement {
    public static let info = ElementInfo(
        name: "align-point",
        capabilities: []
    )

    public var span: Span = .detached

    public init() {}

    /// The shared alignment point.
    public static let shared = Content(AlignPointElem())

    public func field(_ id: UInt8) -> Value? { nil }
    public mutating func setField(_ id: UInt8, _ value: Value) throws {}
}

/// Left/right delimiters around math content. Port of `LrElem` in
/// `math/lr.rs`.
public struct LrElem: NativeElement {
    public static let info = ElementInfo(
        name: "lr",
        fields: [
            FieldInfo(id: 0, name: "size"),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: []
    )

    /// The delimiter size.
    public var size: Rel<Length> = .one()

    /// The delimited body.
    public var body: Content

    public var span: Span = .detached

    public init(body: Content) { self.body = body }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .relative(size)
        case 1: return .content(body)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .relative(r)): size = r
        case (1, let .content(c)): body = c
        default: break
        }
    }
}

/// A base with attachments in math. Port of `AttachElem` in
/// `math/attach.rs`.
public struct AttachElem: NativeElement {
    public static let info = ElementInfo(
        name: "attach",
        fields: [
            FieldInfo(id: 0, name: "base", required: true),
            FieldInfo(id: 1, name: "t"),
            FieldInfo(id: 2, name: "b"),
            FieldInfo(id: 3, name: "tl"),
            FieldInfo(id: 4, name: "bl"),
            FieldInfo(id: 5, name: "tr"),
            FieldInfo(id: 6, name: "br"),
        ],
        capabilities: []
    )

    /// The base being attached to.
    public var base: Content

    /// The top attachment.
    public var t: Content? = nil
    /// The bottom attachment.
    public var b: Content? = nil
    /// The top-left attachment.
    public var tl: Content? = nil
    /// The bottom-left attachment.
    public var bl: Content? = nil
    /// The top-right attachment.
    public var tr: Content? = nil
    /// The bottom-right attachment.
    public var br: Content? = nil

    public var span: Span = .detached

    public init(base: Content) { self.base = base }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(base)
        case 1: return t.map { .content($0) } ?? .none
        case 2: return b.map { .content($0) } ?? .none
        case 3: return tl.map { .content($0) } ?? .none
        case 4: return bl.map { .content($0) } ?? .none
        case 5: return tr.map { .content($0) } ?? .none
        case 6: return br.map { .content($0) } ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        func content(_ v: Value) -> Content? {
            if case let .content(c) = v { return c }
            return nil
        }
        switch (id, value) {
        case (0, let .content(c)): base = c
        case (1, let v): t = content(v)
        case (2, let v): b = content(v)
        case (3, let v): tl = content(v)
        case (4, let v): bl = content(v)
        case (5, let v): tr = content(v)
        case (6, let v): br = content(v)
        default: break
        }
    }
}

/// Prime symbols in math. Port of `PrimesElem` in `math/attach.rs`.
public struct PrimesElem: NativeElement {
    public static let info = ElementInfo(
        name: "primes",
        fields: [FieldInfo(id: 0, name: "count", required: true)],
        capabilities: []
    )

    /// The number of primes.
    public var count: Int

    public var span: Span = .detached

    public init(count: Int) { self.count = count }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .int(Int64(count)) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .int(n) = value else { return }
        count = Int(n)
    }
}

/// A fraction in math. Port of `FracElem` in `math/frac.rs`.
public struct FracElem: NativeElement {
    public static let info = ElementInfo(
        name: "frac",
        fields: [
            FieldInfo(id: 0, name: "num", required: true),
            FieldInfo(id: 1, name: "denom", required: true),
            FieldInfo(id: 2, name: "style"),
            FieldInfo(id: 3, name: "num-deparenthesized"),
            FieldInfo(id: 4, name: "denom-deparenthesized"),
        ],
        capabilities: []
    )

    /// The fraction's numerator.
    public var num: Content

    /// The fraction's denominator.
    public var denom: Content

    /// How the fraction should be laid out (deferred enum — stored raw).
    public var style: Value? = nil

    /// Whether the numerator was originally surrounded by parentheses
    /// that were stripped by the parser.
    public var numDeparenthesized: Bool = false

    /// Whether the denominator was originally surrounded by parentheses
    /// that were stripped by the parser.
    public var denomDeparenthesized: Bool = false

    public var span: Span = .detached

    public init(num: Content, denom: Content) {
        self.num = num
        self.denom = denom
    }

    /// Set the deparenthesized flags (upstream `with_num_deparenthesized`
    /// / `with_denom_deparenthesized`).
    public func withNumDeparenthesized(_ v: Bool) -> FracElem {
        var copy = self
        copy.numDeparenthesized = v
        return copy
    }

    public func withDenomDeparenthesized(_ v: Bool) -> FracElem {
        var copy = self
        copy.denomDeparenthesized = v
        return copy
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .content(num)
        case 1: return .content(denom)
        case 2: return style ?? .none
        case 3: return .bool(numDeparenthesized)
        case 4: return .bool(denomDeparenthesized)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let .content(c)): num = c
        case (1, let .content(c)): denom = c
        default: break
        }
    }
}

/// A root in math. Port of `RootElem` in `math/root.rs`.
public struct RootElem: NativeElement {
    public static let info = ElementInfo(
        name: "root",
        fields: [
            FieldInfo(id: 0, name: "index"),
            FieldInfo(id: 1, name: "radicand", required: true),
        ],
        capabilities: []
    )

    /// The root's index (e.g. the `3` in a cube root).
    public var index: Content? = nil

    /// The radicand.
    public var radicand: Content

    public var span: Span = .detached

    public init(radicand: Content) { self.radicand = radicand }

    /// Set the index (upstream `with_index`).
    public func withIndex(_ index: Content?) -> RootElem {
        var copy = self
        copy.index = index
        return copy
    }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return index.map { .content($0) } ?? .none
        case 1: return .content(radicand)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, let .content(c)): radicand = c
        default: break
        }
    }
}
