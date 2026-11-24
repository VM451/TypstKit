import Foundation

/// `NativeType` conformances for every Typst value type.
///
/// Upstream generates `NativeTypeData` per type via the `#[ty]` proc macro
/// (`ty.rs`). Here each type gets a `static let typeInfo` plus a
/// conformance; `Type.of(T.self)` resolves through it. Constructors and
/// associated scopes land with the stdlib scope port — `TypeInfo` builds
/// them lazily, so registering them later requires no signature changes.

extension NoneValue: NativeType {
    public static let typeInfo = TypeInfo(name: "none", longName: "none",
        title: "None", since: .forever)
}

extension AutoValue: NativeType {
    public static let typeInfo = TypeInfo(name: "auto", longName: "auto",
        title: "Auto", since: .forever)
}

extension Bool: NativeType {
    public static let typeInfo = TypeInfo(name: "bool", longName: "boolean",
        title: "Boolean", since: .forever)
}

extension Int64: NativeType {
    public static let typeInfo = TypeInfo(name: "int", longName: "integer",
        title: "Integer", since: .forever)
}

extension Double: NativeType {
    public static let typeInfo = TypeInfo(name: "float", longName: "float",
        title: "Float", since: .forever)
}

extension Decimal: NativeType {
    public static let typeInfo = TypeInfo(name: "decimal", longName: "decimal",
        title: "Decimal", since: .version([0, 12, 0]))
}

extension Length: NativeType {
    public static let typeInfo = TypeInfo(name: "length", longName: "length",
        title: "Length", since: .forever)
}

extension Angle: NativeType {
    public static let typeInfo = TypeInfo(name: "angle", longName: "angle",
        title: "Angle", since: .forever)
}

extension Ratio: NativeType {
    public static let typeInfo = TypeInfo(name: "ratio", longName: "ratio",
        title: "Ratio", since: .forever)
}

extension Rel: NativeType where T == Length {
    public static let typeInfo = TypeInfo(name: "relative",
        longName: "relative length", title: "Relative Length", since: .forever)
}

extension Fr: NativeType {
    public static let typeInfo = TypeInfo(name: "fraction", longName: "fraction",
        title: "Fraction", since: .forever)
}

extension Symbol: NativeType {
    public static let typeInfo = TypeInfo(name: "symbol", longName: "symbol",
        title: "Symbol", since: .forever)
}

extension Version: NativeType {
    public static let typeInfo = TypeInfo(name: "version", longName: "version",
        title: "Version", since: .version([0, 9, 0]))
}

extension Str: NativeType {
    public static let typeInfo = TypeInfo(name: "str", longName: "string",
        title: "String", since: .forever,
        constructor: { Func(native: strConstruct) },
        scope: { strScope() })
}

extension Bytes: NativeType {
    public static let typeInfo = TypeInfo(name: "bytes", longName: "bytes",
        title: "Bytes", since: .version([0, 7, 0]))
}

extension Label: NativeType {
    public static let typeInfo = TypeInfo(name: "label", longName: "label",
        title: "Label", since: .forever)
}

extension Datetime: NativeType {
    public static let typeInfo = TypeInfo(name: "datetime", longName: "datetime",
        title: "Datetime", since: .version([0, 5, 0]))
}

extension Duration: NativeType {
    public static let typeInfo = TypeInfo(name: "duration", longName: "duration",
        title: "Duration", since: .version([0, 8, 0]))
}

extension Content: NativeType {
    public static let typeInfo = TypeInfo(name: "content", longName: "content",
        title: "Content", since: .forever)
}

extension Styles: NativeType {
    public static let typeInfo = TypeInfo(name: "styles", longName: "styles",
        title: "Styles", since: .forever)
}

extension ArrayValue: NativeType {
    public static let typeInfo = TypeInfo(name: "array", longName: "array",
        title: "Array", since: .forever)
}

extension Dict: NativeType {
    public static let typeInfo = TypeInfo(name: "dictionary", longName: "dictionary",
        title: "Dictionary", since: .forever)
}

extension Func: NativeType {
    public static let typeInfo = TypeInfo(name: "function", longName: "function",
        title: "Function", since: .forever)
}

extension Args: NativeType {
    public static let typeInfo = TypeInfo(name: "arguments", longName: "arguments",
        title: "Arguments", since: .forever)
}

extension Type: NativeType {
    public static let typeInfo = TypeInfo(name: "type", longName: "type",
        title: "Type", since: .forever)
}

extension Module: NativeType {
    public static let typeInfo = TypeInfo(name: "module", longName: "module",
        title: "Module", since: .forever)
}

extension Regex: NativeType {
    public static let typeInfo = TypeInfo(name: "regex", longName: "regex",
        title: "Regex", since: .forever,
        constructor: { Func(native: regexConstruct) },
        scope: { regexScope() })
}

extension Selector: NativeType {
    public static let typeInfo = TypeInfo(name: "selector", longName: "selector",
        title: "Selector", since: .forever)
}
