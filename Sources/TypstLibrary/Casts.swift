import Foundation
import TypstSyntax

// MARK: - Primitive casts
//
// Port of the `primitive!` invocations in upstream `value.rs` plus the
// `cast!` impls for `Smart`, `Spanned`, and the string/enum helper types.
// Each conformance mirrors upstream's accepted `Value` variants exactly.

extension NoneValue: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(NoneValue.self)) }
    public static var output: CastInfo { .type(Type.of(NoneValue.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .none = value { return true }
        return false
    }
    public func intoValue() -> Value { .none }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .none = value else { return .failure(error(value)) }
        return .success(Self())
    }
}

extension AutoValue: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(AutoValue.self)) }
    public static var output: CastInfo { .type(Type.of(AutoValue.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .auto = value { return true }
        return false
    }
    public func intoValue() -> Value { .auto }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .auto = value else { return .failure(error(value)) }
        return .success(Self())
    }
}

extension Bool: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Bool.self)) }
    public static var output: CastInfo { .type(Type.of(Bool.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .bool = value { return true }
        return false
    }
    public func intoValue() -> Value { .bool(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .bool(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Int64: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .int = value { return true }
        return false
    }
    public func intoValue() -> Value { .int(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .int(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Int: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { Int64.castable(value) }
    public func intoValue() -> Value { .int(Int64(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        Int64.fromValue(value).map { Int($0) }
    }
}

extension Double: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Double.self)) }
    public static var output: CastInfo { .type(Type.of(Double.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .float = value { return true }
        if case .int = value { return true }
        return false
    }
    public func intoValue() -> Value { .float(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .float(v): return .success(v)
        case let .int(v): return .success(Double(v))
        default: return .failure(error(value))
        }
    }
}

extension Float: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Double.self)) }
    public static var output: CastInfo { .type(Type.of(Double.self)) }
    public static func castable(_ value: Value) -> Bool { Double.castable(value) }
    public func intoValue() -> Value { .float(Double(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        Double.fromValue(value).map { Float($0) }
    }
}

extension Length: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Length.self)) }
    public static var output: CastInfo { .type(Type.of(Length.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .length = value { return true }
        return false
    }
    public func intoValue() -> Value { .length(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .length(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Angle: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Angle.self)) }
    public static var output: CastInfo { .type(Type.of(Angle.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .angle = value { return true }
        return false
    }
    public func intoValue() -> Value { .angle(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .angle(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Ratio: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Ratio.self)) }
    public static var output: CastInfo { .type(Type.of(Ratio.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .ratio = value { return true }
        return false
    }
    public func intoValue() -> Value { .ratio(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .ratio(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Rel: Castable, IntoValue, FromValue where T == Length {
    public static var input: CastInfo { .type(Type.of(Rel<Length>.self)) }
    public static var output: CastInfo { .type(Type.of(Rel<Length>.self)) }
    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .relative, .length, .ratio: return true
        default: return false
        }
    }
    public func intoValue() -> Value { .relative(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .relative(v): return .success(v)
        case let .length(v): return .success(Rel(v))
        case let .ratio(v): return .success(Rel(v))
        default: return .failure(error(value))
        }
    }
}

extension Fr: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Fr.self)) }
    public static var output: CastInfo { .type(Type.of(Fr.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .fraction = value { return true }
        return false
    }
    public func intoValue() -> Value { .fraction(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .fraction(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Color: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Color.self)) }
    public static var output: CastInfo { .type(Type.of(Color.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .color = value { return true }
        return false
    }
    public func intoValue() -> Value { .color(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .color(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Gradient: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Gradient.self)) }
    public static var output: CastInfo { .type(Type.of(Gradient.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .gradient = value { return true }
        return false
    }
    public func intoValue() -> Value { .gradient(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .gradient(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Tiling: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Tiling.self)) }
    public static var output: CastInfo { .type(Type.of(Tiling.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .tiling = value { return true }
        return false
    }
    public func intoValue() -> Value { .tiling(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .tiling(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Symbol: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Symbol.self)) }
    public static var output: CastInfo { .type(Type.of(Symbol.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .symbol = value { return true }
        return false
    }
    public func intoValue() -> Value { .symbol(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .symbol(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Version: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Version.self)) }
    public static var output: CastInfo { .type(Type.of(Version.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .version = value { return true }
        return false
    }
    public func intoValue() -> Value { .version(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .version(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Str: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { .type(Type.of(Str.self)) }
    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .str, .symbol: return true
        default: return false
        }
    }
    public func intoValue() -> Value { .str(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .str(v): return .success(v)
        case let .symbol(v): return .success(Str(v.get))
        default: return .failure(error(value))
        }
    }
}

/// Swift `String` casts from Typst strings and symbols.
extension String: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { .type(Type.of(Str.self)) }
    public static func castable(_ value: Value) -> Bool { Str.castable(value) }
    public func intoValue() -> Value { .str(Str(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        Str.fromValue(value).map { $0.value }
    }
}

extension Bytes: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Bytes.self)) }
    public static var output: CastInfo { .type(Type.of(Bytes.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .bytes = value { return true }
        return false
    }
    public func intoValue() -> Value { .bytes(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .bytes(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Label: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Label.self)) }
    public static var output: CastInfo { .type(Type.of(Label.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .label = value { return true }
        return false
    }
    public func intoValue() -> Value { .label(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .label(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Datetime: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Datetime.self)) }
    public static var output: CastInfo { .type(Type.of(Datetime.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .datetime = value { return true }
        return false
    }
    public func intoValue() -> Value { .datetime(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .datetime(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Decimal: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Decimal.self)) }
    public static var output: CastInfo { .type(Type.of(Decimal.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .decimal = value { return true }
        return false
    }
    public func intoValue() -> Value { .decimal(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .decimal(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Duration: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Duration.self)) }
    public static var output: CastInfo { .type(Type.of(Duration.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .duration = value { return true }
        return false
    }
    public func intoValue() -> Value { .duration(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .duration(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Content: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Content.self)) }
    public static var output: CastInfo { .type(Type.of(Content.self)) }
    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .content, .none, .symbol, .str: return true
        default: return false
        }
    }
    public func intoValue() -> Value { .content(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .content(v): return .success(v)
        case .none: return .success(.empty)
        case let .symbol(v): return .success(SymbolElem.packed(v.get))
        case let .str(v): return .success(TextElem.packed(v.value))
        default: return .failure(error(value))
        }
    }
}

extension Styles: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Styles.self)) }
    public static var output: CastInfo { .type(Type.of(Styles.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .styles = value { return true }
        return false
    }
    public func intoValue() -> Value { .styles(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .styles(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension ArrayValue: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(ArrayValue.self)) }
    public static var output: CastInfo { .type(Type.of(ArrayValue.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .array = value { return true }
        return false
    }
    public func intoValue() -> Value { .array(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .array(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Dict: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Dict.self)) }
    public static var output: CastInfo { .type(Type.of(Dict.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .dict = value { return true }
        return false
    }
    public func intoValue() -> Value { .dict(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .dict(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Func: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Func.self)) }
    public static var output: CastInfo { .type(Type.of(Func.self)) }
    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .function, .type: return true
        default: return false
        }
    }
    public func intoValue() -> Value { .function(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .function(v): return .success(v)
        case let .type(ty):
            return ty.constructor()
                .mapError { HintedString($0.message) }
        default:
            return .failure(error(value))
        }
    }
}

extension Args: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Args.self)) }
    public static var output: CastInfo { .type(Type.of(Args.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .arguments = value { return true }
        return false
    }
    public func intoValue() -> Value { .arguments(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .arguments(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Type: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Type.self)) }
    public static var output: CastInfo { .type(Type.of(Type.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .type = value { return true }
        return false
    }
    public func intoValue() -> Value { .type(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .type(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

extension Module: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Module.self)) }
    public static var output: CastInfo { .type(Type.of(Module.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .module = value { return true }
        return false
    }
    public func intoValue() -> Value { .module(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .module(v) = value else { return .failure(error(value)) }
        return .success(v)
    }
}

// MARK: - Smart / Spanned

extension Smart: Castable where T: Castable {
    public static var input: CastInfo { T.input + AutoValue.input }
    public static var output: CastInfo { T.output + AutoValue.output }
    public static func castable(_ value: Value) -> Bool {
        AutoValue.castable(value) || T.castable(value)
    }
}

extension Smart: IntoValue where T: IntoValue {
    public func intoValue() -> Value {
        switch self {
        case .auto: return .auto
        case let .custom(v): return v.intoValue()
        }
    }
}

extension Smart: FromValue where T: FromValue {
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .auto:
            return .success(.auto)
        default:
            guard T.castable(value) else { return .failure(error(value)) }
            return T.fromValue(value).map { .custom($0) }
        }
    }
}

extension Spanned: Castable where T: Castable {
    public static var input: CastInfo { T.input }
    public static var output: CastInfo { T.output }
    public static func castable(_ value: Value) -> Bool { T.castable(value) }
}

extension Spanned: IntoValue where T: IntoValue {
    public func intoValue() -> Value { value.intoValue() }
}

extension Spanned: FromValue where T: FromValue & IntoValue, S == Span {
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        T.fromValue(value).map { Spanned($0, span: .detached) }
    }

    public static func fromSpannedValue(
        _ spanned: Spanned<Value, Span>
    ) -> HintedStrResult<Self> {
        T.fromValue(spanned.value).map { Spanned($0, span: spanned.span) }
    }
}

// MARK: - Dynamic values (`#[ty]` types stored as `Value.dynamic`)

/// Types stored as `Value.dynamic`, cast by downcasting — the Swift
/// equivalent of upstream's `#[ty]`-generated casts.
public protocol DynamicValue: DynamicBounds, Castable, IntoValue, FromValue {}

extension DynamicValue {
    public static var input: CastInfo { .type(Type(Self.typeInfo)) }
    public static var output: CastInfo { .type(Type(Self.typeInfo)) }
    public static func castable(_ value: Value) -> Bool {
        guard case let .dynamic(d) = value else { return false }
        return d.is(Self.self)
    }
    public func intoValue() -> Value { .dynamic(self) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .dynamic(d) = value, let v = d.downcast(Self.self) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

extension Alignment: NativeType {
    public static let typeInfo = TypeInfo(
        name: "alignment", longName: "alignment", title: "Alignment",
        since: .forever, keywords: ["position"])
}

extension Alignment: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

extension Alignment: DynamicValue {}

extension Dir: NativeType {
    public static let typeInfo = TypeInfo(
        name: "direction", longName: "direction", title: "Direction",
        since: .forever)
}

extension Dir: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

extension Dir: DynamicValue {}

extension Stroke: DynamicValue {}

// MARK: - Alignment component casts

extension HAlignment: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Alignment.self)) }
    public static var output: CastInfo { .type(Type.of(Alignment.self)) }
    public static func castable(_ value: Value) -> Bool { Alignment.castable(value) }
    public func intoValue() -> Value { .dynamic(Alignment.h(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch Alignment.fromValue(value) {
        case let .success(.h(h)): return .success(h)
        case let .success(align):
            return .failure(HintedString(
                "expected `start`, `left`, `center`, `right`, or `end`, found \(align.repr())"))
        case let .failure(e): return .failure(e)
        }
    }
}

extension VAlignment: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Alignment.self)) }
    public static var output: CastInfo { .type(Type.of(Alignment.self)) }
    public static func castable(_ value: Value) -> Bool { Alignment.castable(value) }
    public func intoValue() -> Value { .dynamic(Alignment.v(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch Alignment.fromValue(value) {
        case let .success(.v(v)): return .success(v)
        case let .success(align):
            return .failure(HintedString(
                "expected `top`, `horizon`, or `bottom`, found \(align.repr())"))
        case let .failure(e): return .failure(e)
        }
    }
}

extension OuterHAlignment: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Alignment.self)) }
    public static var output: CastInfo { .type(Type.of(Alignment.self)) }
    public static func castable(_ value: Value) -> Bool { Alignment.castable(value) }
    public func intoValue() -> Value {
        .dynamic(Alignment.h(HAlignment(rawValue: rawValue) ?? .start))
    }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch Alignment.fromValue(value) {
        case let .success(.h(h)):
            switch h {
            case .start: return .success(.start)
            case .left: return .success(.left)
            case .right: return .success(.right)
            case .end: return .success(.end)
            case .center:
                return .failure(HintedString(
                    "expected `start`, `left`, `right`, or `end`, found \(h.repr())"))
            }
        case let .success(align):
            return .failure(HintedString(
                "expected `start`, `left`, `right`, or `end`, found \(align.repr())"))
        case let .failure(e): return .failure(e)
        }
    }
}

extension OuterVAlignment: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Alignment.self)) }
    public static var output: CastInfo { .type(Type.of(Alignment.self)) }
    public static func castable(_ value: Value) -> Bool { Alignment.castable(value) }
    public func intoValue() -> Value {
        .dynamic(Alignment.v(VAlignment(rawValue: rawValue) ?? .top))
    }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch Alignment.fromValue(value) {
        case let .success(.v(v)):
            switch v {
            case .top: return .success(.top)
            case .bottom: return .success(.bottom)
            case .horizon:
                return .failure(HintedString(
                    "expected `top` or `bottom`, found \(v.repr())"))
            }
        case let .success(align):
            return .failure(HintedString(
                "expected `top` or `bottom`, found \(align.repr())"))
        case let .failure(e): return .failure(e)
        }
    }
}

// MARK: - Paint

extension Paint: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([Color.input, Gradient.input, Tiling.input])
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        Color.castable(value) || Gradient.castable(value) || Tiling.castable(value)
    }
    public func intoValue() -> Value {
        switch self {
        case let .solid(c): return c.intoValue()
        case let .gradient(g): return g.intoValue()
        case let .tiling(t): return t.intoValue()
        }
    }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if case let .color(c) = value { return .success(.solid(c)) }
        if case let .gradient(g) = value { return .success(.gradient(g)) }
        if case let .tiling(t) = value { return .success(.tiling(t)) }
        return .failure(error(value))
    }
}

// MARK: - String-backed enums

extension LineCap: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union(allCases.map { .value(.str(Str($0.rawValue)), doc: "") })
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return LineCap(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value, let v = LineCap(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

extension LineJoin: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union(allCases.map { .value(.str(Str($0.rawValue)), doc: "") })
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return LineJoin(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value, let v = LineJoin(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

// MARK: - Sized integers (upstream `signed_int!`/`unsigned_int!` casts)
//
// Each accepts only Typst `int` values; range errors surface in
// `fromValue` ("number must be at least zero" / "number too large").

/// Shared `castable` for the integer casts: any `int` value.
func intCastable(_ value: Value) -> Bool {
    if case .int = value { return true }
    return false
}

extension Int32: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }
    public func intoValue() -> Value { .int(Int64(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .int(v) = value else { return .failure(error(value)) }
        guard let i = Int32(exactly: v) else {
            return .failure(HintedString("number too large"))
        }
        return .success(i)
    }
}

extension UInt8: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }
    public func intoValue() -> Value { .int(Int64(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .int(v) = value else { return .failure(error(value)) }
        guard v >= 0 else {
            return .failure(HintedString("number must be at least zero"))
        }
        guard let u = UInt8(exactly: v) else {
            return .failure(HintedString("number too large"))
        }
        return .success(u)
    }
}

// MARK: - UInt64 (upstream `unsigned_int!` casts)

extension UInt64: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Int64.self)) }
    public static var output: CastInfo { .type(Type.of(Int64.self)) }
    public static func castable(_ value: Value) -> Bool { intCastable(value) }
    public func intoValue() -> Value { .int(Int64(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .int(let v) = value else { return .failure(error(value)) }
        guard v >= 0 else {
            return .failure(HintedString("number must be at least zero"))
        }
        guard let u = UInt64(exactly: v) else {
            return .failure(HintedString("number too large"))
        }
        return .success(u)
    }
}
