import Foundation
import TypstSyntax
import TypstUtils

// The `arguments` type's associated scope — port of the `#[scope] impl Args`
// block in upstream `foundations/args.rs` (callback methods `filter`/`map`
// deferred to the eval milestone). `Args::get`/`at`/`field` were already
// ported in `Args.swift`.

extension ArgumentKey: Castable, IntoValue, FromValue {
    public static var input: CastInfo { Int64.input + Str.input }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .str: return true
        default: return false
        }
    }

    public func intoValue() -> Value {
        switch self {
        case .index(let i): return .int(i)
        case .name(let s): return .str(s)
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .int(let i): return .success(.index(i))
        case .str(let s): return .success(.name(s))
        default: return .failure(error(value))
        }
    }
}

/// `arguments(..)` — port of `Args::construct`: takes all arguments and
/// returns them as an `arguments` value.
let argsConstruct = nativeFunc(
    "arguments",
    title: "Arguments",
    since: .version([0, 10, 0]),
    docs: """
        Constructs spreadable arguments in place.

        This function behaves like `{let arguments(..args) = args}`.
        """,
    params: [
        NativeParamInfo(
            name: "args",
            input: .any,
            variadic: true),
    ],
    returns: Args.output
) { _, _, args in
    return args.take()
}

/// `arguments.len()` — port of `Args::len`.
let argsLen = nativeFunc(
    "len",
    title: "Length",
    since: .version([0, 15, 0]),
    docs: "Returns the number of arguments, positional or named.",
    params: [
        NativeParamInfo(name: "self", input: Args.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let selfValue: Args = try args.expectT("self")
    try args.finishT()
    return Int64(selfValue.items.count)
}

/// `arguments.at(key, default:)` — port of `Args::at`.
let argsAt = nativeFunc(
    "at",
    since: .version([0, 12, 0]),
    docs: """
        Returns the positional argument at the specified index, or the \
        named argument with the specified name.
        """,
    params: [
        NativeParamInfo(name: "self", input: Args.input, required: true),
        NativeParamInfo(name: "key", input: ArgumentKey.input, required: true),
        NativeParamInfo(
            name: "default",
            input: Value.input,
            defaultValue: { .none },
            positional: false,
            named: true),
    ],
    returns: Value.output
) { _, _, args in
    let selfValue: Args = try args.expectT("self")
    let key: ArgumentKey = try args.expectT("key")
    let fallback: Value? = try args.namedT("default")
    try args.finishT()
    return try selfValue.at(key, default: fallback).get()
}

/// `arguments.pos()` — port of `Args::to_pos`.
let argsPos = nativeFunc(
    "pos",
    title: "Positional",
    since: .forever,
    docs: "Returns the positional arguments as an array.",
    params: [
        NativeParamInfo(name: "self", input: Args.input, required: true),
    ],
    returns: ArrayValue.output
) { _, _, args in
    let selfValue: Args = try args.expectT("self")
    try args.finishT()
    return selfValue.toPos
}

/// `arguments.named()` — port of `Args::to_named`.
let argsNamed = nativeFunc(
    "named",
    since: .forever,
    docs: "Returns the named arguments as a dictionary.",
    params: [
        NativeParamInfo(name: "self", input: Args.input, required: true),
    ],
    returns: Dict.output
) { _, _, args in
    let selfValue: Args = try args.expectT("self")
    try args.finishT()
    return selfValue.toNamed
}

/// Build the scope containing all `arguments` methods.
func argsScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(argsConstruct)
    scope.defineFunc(argsLen)
    scope.defineFunc(argsAt)
    scope.defineFunc(argsPos)
    scope.defineFunc(argsNamed)
    return scope
}
