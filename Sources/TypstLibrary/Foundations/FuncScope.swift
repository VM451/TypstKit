import Foundation
import TypstSyntax
import TypstUtils

// The `function` type's associated scope — port of the `#[scope] impl Func`
// block in upstream `foundations/func.rs`.

/// `func.with(..args)` — port of `Func::with`: pre-applies arguments.
let funcWith = nativeFunc(
    "with",
    since: .forever,
    docs: "Returns a new function that has the given arguments pre-applied.",
    params: [
        NativeParamInfo(name: "self", input: Func.input, required: true),
        NativeParamInfo(
            name: "arguments",
            input: .any,
            variadic: true),
    ],
    returns: Func.output
) { _, _, args in
    let selfValue: Func = try args.expectT("self")
    return selfValue.with(args.take())
}

/// `func.where(..fields)` — port of `Func::where_`: builds an element
/// selector filtered by field values.
let funcWhere = nativeFunc(
    "where",
    since: .forever,
    docs: """
        Returns a selector that filters for elements belonging to this \
        function whose fields have the values of the given arguments.
        """,
    params: [
        NativeParamInfo(name: "self", input: Func.input, required: true),
        NativeParamInfo(
            name: "fields",
            input: .any,
            variadic: true),
    ],
    returns: Selector.output
) { _, _, args in
    let selfValue: Func = try args.expectT("self")

    // Upstream passes the remaining args to `Func::where_`, which collects
    // the named ones as fields; leftover positional args then fail `finish`.
    var rest = args
    let selector = try selfValue.where_(rest).get()
    rest.items.removeAll { $0.name != nil }
    try rest.finishT()
    return selector
}

/// Build the scope containing all `function` methods.
func funcScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(funcWith)
    scope.defineFunc(funcWhere)
    return scope
}
