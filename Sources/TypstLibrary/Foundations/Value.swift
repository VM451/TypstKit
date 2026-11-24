import Foundation
import TypstSyntax
import TypstUtils

/// A value in Typst. Port of `Value` in `value.rs`.
public indirect enum Value: Sendable {
    case none
    case auto
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case length(Length)
    case angle(Angle)
    case ratio(Ratio)
    case relative(Rel<Length>)
    case fraction(Fr)
    case color(Color)
    case gradient(Gradient)
    case tiling(Tiling)
    case symbol(Symbol)
    case version(Version)
    case str(Str)
    case bytes(Bytes)
    case label(Label)
    case datetime(Datetime)
    case decimal(Decimal)
    case duration(Duration)
    case content(Content)
    case styles(Styles)
    case array(ArrayValue)
    case dict(Dict)
    case function(Func)
    case arguments(Args)
    case type(Type)
    case module(Module)
    case dynamic(Dynamic)
}

extension Value {
    /// Create a dynamic value from a native type.
    public static func dynamic<T: DynamicBounds>(_ any: T) -> Value {
        .dynamic(Dynamic(any))
    }

    /// Create a value from a numeric literal with its unit.
    public static func numeric(_ pair: (Double, TypstSyntax.NumericUnit)) -> Value {
        let (v, unit) = pair
        switch unit {
        case .pt: return .length(Length(Abs.pt(v)))
        case .mm: return .length(Length(Abs.mm(v)))
        case .cm: return .length(Length(Abs.cm(v)))
        case .in_: return .length(Length(Abs.inches(v)))
        case .rad: return .angle(Angle.rad(v))
        case .deg: return .angle(Angle.deg(v))
        case .em: return .length(Length(Em(v)))
        case .fr: return .fraction(Fr(v))
        case .percent: return .ratio(Ratio(v / 100))
        }
    }

    /// The type of this value.
    public var type: Type {
        switch self {
        case .none: return Type.of(NoneValue.self)
        case .auto: return Type.of(AutoValue.self)
        case .bool: return Type.of(Bool.self)
        case .int: return Type.of(Int64.self)
        case .float: return Type.of(Double.self)
        case .length: return Type.of(Length.self)
        case .angle: return Type.of(Angle.self)
        case .ratio: return Type.of(Ratio.self)
        case .relative: return Type.of(Rel<Length>.self)
        case .fraction: return Type.of(Fr.self)
        case .color: return Type.of(Color.self)
        case .gradient: return Type.of(Gradient.self)
        case .tiling: return Type.of(Tiling.self)
        case .symbol: return Type.of(Symbol.self)
        case .version: return Type.of(Version.self)
        case .str: return Type.of(Str.self)
        case .bytes: return Type.of(Bytes.self)
        case .label: return Type.of(Label.self)
        case .datetime: return Type.of(Datetime.self)
        case .decimal: return Type.of(Decimal.self)
        case .duration: return Type.of(Duration.self)
        case .content: return Type.of(Content.self)
        case .styles: return Type.of(Styles.self)
        case .array: return Type.of(ArrayValue.self)
        case .dict: return Type.of(Dict.self)
        case .function: return Type.of(Func.self)
        case .arguments: return Type.of(Args.self)
        case .type: return Type.of(Type.self)
        case .module: return Type.of(Module.self)
        case let .dynamic(v): return v.type
        }
    }

    /// Cast this value to a Swift type.
    public func cast<T: FromValue>(_ type: T.Type = T.self) -> HintedStrResult<T> {
        T.fromValue(self)
    }

    /// Access a field on this value.
    public func field(_ field: String, guard access: any BindingGuard) -> HintedStrResult<Value> {
        switch self {
        case let .symbol(symbol):
            return symbol.modified(field, guard: access).map { .symbol($0) }
        case let .version(version):
            return version.component(field)
                .map { .int($0) }
                .mapError { HintedString($0.message) }
        case let .dict(dict):
            guard let value = dict.get(field) else {
                return .failure(HintedString("dictionary does not contain key \(Str(field).repr())"))
            }
            return .success(value)
        case let .arguments(args):
            return args.field(field)
                .map { $0 }
                .mapError { HintedString($0.message) }
        case let .content(content):
            return content.fieldByName(field)
                .map { $0 }
                .mapError { HintedString($0.message) }
        case let .type(ty):
            return ty.field(field, guard: access)
        case let .function(f):
            return f.field(field, guard: access)
        case let .module(module):
            return module.field(field, guard: access)
        default:
            return fields_field(self, field)
        }
    }

    /// The associated scope, if this value has one.
    public var scope: Scope? {
        switch self {
        case let .function(f): return f.scope
        case let .type(ty): return ty.scope()
        case let .module(module): return module.scope
        default: return nil
        }
    }

    /// Documentation string, if available.
    public var docs: String? {
        switch self {
        case let .function(f): return f.docs
        case let .type(ty): return ty.docs
        default: return nil
        }
    }

    /// Display this value as content (for `#value` interpolation).
    public var display: Content {
        switch self {
        case .none: return .empty
        case let .int(v): return TextElem.packed(formatIntWithBase(v, base: 10))
        case let .float(v): return TextElem.packed(displayFloat(v))
        case let .decimal(v): return TextElem.packed("\(v)")
        case let .str(v): return TextElem.packed(v.value)
        case let .version(v): return TextElem.packed("\(v)")
        case let .symbol(v): return SymbolElem.packed(v.get)
        case let .content(v): return v
        case let .module(module): return module.content
        default:
            return RawElem(
                RawContentValue.text(Str(self.repr())),
                lang: "typc",
                block: false
            ).pack()
        }
    }

    /// Attach a span to content/function values.
    public func spanned(_ span: Span) -> Value {
        switch self {
        case let .content(v): return .content(v.spanned(span))
        case let .function(v): return .function(v.spanned(span))
        default: return self
        }
    }
}

// MARK: - Equatable / Hashable / Comparable

extension Value: Equatable {
    public static func == (lhs: Value, rhs: Value) -> Bool {
        ops_equal(lhs, rhs)
    }
}

extension Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(discriminant)
        switch self {
        case .none, .auto: break
        case let .bool(v): hasher.combine(v)
        case let .int(v): hasher.combine(v)
        case let .float(v): hasher.combine(v.bitPattern)
        case let .length(v): hasher.combine(v)
        case let .angle(v): hasher.combine(v)
        case let .ratio(v): hasher.combine(v)
        case let .relative(v): hasher.combine(v)
        case let .fraction(v): hasher.combine(v)
        case let .color(v): hasher.combine(v)
        case let .gradient(v): hasher.combine(v)
        case let .tiling(v): hasher.combine(v)
        case let .symbol(v): hasher.combine(v)
        case let .version(v): hasher.combine(v)
        case let .str(v): hasher.combine(v)
        case let .bytes(v): hasher.combine(v)
        case let .label(v): hasher.combine(v)
        case let .content(v): hasher.combine(v)
        case let .styles(v): hasher.combine(v)
        case let .datetime(v): hasher.combine(v)
        case let .decimal(v): hasher.combine(v)
        case let .duration(v): hasher.combine(v)
        case let .array(v): hasher.combine(v)
        case let .dict(v): hasher.combine(v)
        case let .function(v): hasher.combine(v)
        case let .arguments(v): hasher.combine(v)
        case let .type(v): hasher.combine(v)
        case let .module(v): hasher.combine(v)
        case let .dynamic(v): hasher.combine(v)
        }
    }

    /// A stable discriminant for hashing.
    var discriminant: Int {
        switch self {
        case .none: return 0
        case .auto: return 1
        case .bool: return 2
        case .int: return 3
        case .float: return 4
        case .length: return 5
        case .angle: return 6
        case .ratio: return 7
        case .relative: return 8
        case .fraction: return 9
        case .color: return 10
        case .gradient: return 11
        case .tiling: return 12
        case .symbol: return 13
        case .version: return 14
        case .str: return 15
        case .bytes: return 16
        case .label: return 17
        case .datetime: return 18
        case .decimal: return 19
        case .duration: return 20
        case .content: return 21
        case .styles: return 22
        case .array: return 23
        case .dict: return 24
        case .function: return 25
        case .arguments: return 26
        case .type: return 27
        case .module: return 28
        case .dynamic: return 29
        }
    }
}

extension Value: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .none: return "None"
        case .auto: return "Auto"
        case let .bool(v): return "\(v)"
        case let .int(v): return "\(v)"
        case let .float(v): return "\(v)"
        case let .length(v): return "\(v)"
        case let .angle(v): return "\(v)"
        case let .ratio(v): return "\(v)"
        case let .relative(v): return "\(v)"
        case let .fraction(v): return "\(v)"
        case let .color(v): return "\(v)"
        case let .gradient(v): return "\(v)"
        case let .tiling(v): return "\(v)"
        case let .symbol(v): return "\(v)"
        case let .version(v): return "\(v)"
        case let .str(v): return "\(v.value.debugDescription)"
        case let .bytes(v): return "\(v)"
        case let .label(v): return "\(v)"
        case let .datetime(v): return "\(v)"
        case let .decimal(v): return "\(v)"
        case let .duration(v): return "\(v)"
        case let .content(v): return "\(v)"
        case let .styles(v): return "\(v)"
        case let .array(v): return "\(v.items)"
        case let .dict(v): return "\(v)"
        case let .function(v): return "Func(\(v.name ?? ".."))"
        case let .arguments(v): return v.debugDescription
        case let .type(v): return "Type(\(v.longName))"
        case let .module(v): return "\(v)"
        case let .dynamic(v): return "\(v)"
        }
    }
}

extension Value: Repr {
    public func repr() -> String {
        switch self {
        case .none: return "none"
        case .auto: return "auto"
        case let .bool(v): return v.repr()
        case let .int(v): return v.repr()
        case let .float(v): return v.repr()
        case let .length(v): return v.repr()
        case let .angle(v): return v.repr()
        case let .ratio(v): return v.repr()
        case let .relative(v): return v.repr()
        case let .fraction(v): return v.repr()
        case let .color(v): return v.repr()
        case let .gradient(v): return v.repr()
        case let .tiling(v): return v.repr()
        case let .symbol(v): return v.repr()
        case let .version(v): return v.repr()
        case let .str(v): return v.repr()
        case let .bytes(v): return v.repr()
        case let .label(v): return v.repr()
        case let .datetime(v): return v.repr()
        case let .decimal(v): return v.repr()
        case let .duration(v): return v.repr()
        case let .content(v): return v.repr()
        case let .styles(v): return v.repr()
        case let .array(v): return v.repr()
        case let .dict(v): return v.repr()
        case let .function(v): return v.repr()
        case let .arguments(v): return v.repr()
        case let .type(v): return v.repr()
        case let .module(v): return v.repr()
        case let .dynamic(v): return v.repr()
        }
    }
}

// MARK: - Dynamic

/// Bounds for dynamic values. Port of upstream's `Dynamic` bounds.
public protocol DynamicBounds: CustomDebugStringConvertible, Repr, NativeType,
    Equatable, Hashable, Sendable {}

/// A dynamically-typed native value. Port of `Dynamic` in `value.rs`.
public struct Dynamic: Sendable {
    /// The boxed value.
    let box: any DynamicBox

    init<T: DynamicBounds>(_ value: T) {
        box = DynamicBoxImpl(value: value)
    }

    /// Whether the value is of type `T`.
    public func `is`<T>(_ type: T.Type) -> Bool {
        box.`is`(T.self)
    }

    /// Downcast to `T`.
    public func downcast<T>(_ type: T.Type) -> T? {
        box.downcast(type)
    }

    /// The value's Typst type.
    public var type: Type { box.typstType }
}

/// Type-erased dynamic value storage.
protocol DynamicBox: CustomDebugStringConvertible, Repr, Sendable {
    var typstType: Type { get }
    func `is`<T>(_ type: T.Type) -> Bool
    func downcast<T>(_ type: T.Type) -> T?
    func equals(_ other: Dynamic) -> Bool
    func hash(into hasher: inout Hasher)
}

struct DynamicBoxImpl<T: DynamicBounds>: DynamicBox {
    let value: T

    var typstType: Type { Type(T.typeInfo) }

    var debugDescription: String { value.debugDescription }
    func repr() -> String { value.repr() }

    func `is`<P>(_ type: P.Type) -> Bool {
        value is P
    }

    func downcast<P>(_ type: P.Type) -> P? {
        value as? P
    }

    func equals(_ other: Dynamic) -> Bool {
        guard let otherValue = other.downcast(T.self) else { return false }
        return value == otherValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(T.self))
        hasher.combine(value)
    }
}

extension Dynamic: CustomDebugStringConvertible {
    public var debugDescription: String { box.debugDescription }
}

extension Dynamic: Repr {
    public func repr() -> String { box.repr() }
}

extension Dynamic: Equatable {
    public static func == (lhs: Dynamic, rhs: Dynamic) -> Bool {
        lhs.box.equals(rhs)
    }
}

extension Dynamic: Hashable {
    public func hash(into hasher: inout Hasher) {
        box.hash(into: &hasher)
    }
}
