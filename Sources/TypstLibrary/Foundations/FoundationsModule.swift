import TypstSyntax
import TypstUtils

// Port of `foundations/mod.rs` — registers the foundations types,
// functions, and the `calc` module into the global scope.
//
// `eval` and `plugin` are registered by later milestones (they depend on
// the evaluator and dynamic loading respectively).

/// Define all foundations in the global scope.
///
/// Port of `foundations::define` in `mod.rs`.
public func defineFoundations(_ global: Scope, inputs: Dict = Dict()) {
    global.defineType(Bool.self)
    global.defineType(Int64.self)
    global.defineType(Double.self)
    global.defineType(Str.self)
    global.defineType(Label.self)
    global.defineType(Bytes.self)
    global.defineType(Content.self)
    global.defineType(ArrayValue.self)
    global.defineType(Dict.self)
    global.defineType(Func.self)
    global.defineType(Args.self)
    global.defineType(Type.self)
    global.defineType(Module.self)
    global.defineType(Regex.self)
    global.defineType(Selector.self)
    global.defineType(Datetime.self)
    global.defineType(Decimal.self)
    global.defineType(Symbol.self)
    global.defineType(Duration.self)
    global.defineType(Version.self)
    global.defineType(RootedPath.self)

    global.defineFunc(reprFunc)
    global.defineFunc(panicFunc)
    global.defineFunc(assertFunc)
    global.defineFunc(targetFunc)

    // Upstream `lib.rs` defines `range` globally (also in `array`'s scope).
    global.defineFunc(arrayRange)

    global.define("calc", .module(calcModule()))
    global.define("sys", .module(sysModule(inputs: inputs)))

    // Data loading (`read`, `csv`, `json`) — port of upstream
    // `loading/mod.rs` global functions.
    defineDataLoading(into: global)

    // Elements — port of upstream `model/mod.rs`, `text/mod.rs`, and
    // `layout/mod.rs` `define_elem` calls for the ported elements.
    defineModelElements(into: global)
    defineLayoutElements(into: global)
    defineVisualizeElements(into: global)
    defineIntrospection(into: global)

    global.resetCategory()
}

// MARK: - repr

/// Returns the string representation of a value.
///
/// Port of `repr` in `repr.rs`.
let reprFunc = nativeFunc(
    "repr",
    title: "Representation",
    since: .forever,
    docs: """
        Returns the string representation of a value.

        When inserted into content, most values are displayed as this \
        representation in monospace with syntax-highlighting. The \
        exceptions are `{none}`, integers, floats, strings, content, and \
        functions.

        = #short-or-long[Debugging Only][For debugging purposes only]
        This function is for debugging purposes. Its output should not be \
        considered stable and may change at any time.
        """,
    params: [NativeParamInfo(name: "value", input: .any, required: true)],
    returns: Str.output
) { _, _, args in
    let value: Value = try args.expectT("value")
    try args.finishT()
    return Str(value.repr())
}

// MARK: - panic

/// Fails with an error.
///
/// Port of `panic` in `mod.rs`.
let panicFunc = nativeFunc(
    "panic",
    since: .forever,
    docs: """
        Fails with an error.

        Arguments are displayed to the user (not rendered in the document) \
        as strings, converting with `repr` if necessary.
        """,
    keywords: ["error"],
    params: [NativeParamInfo(name: "values", input: .any, variadic: true)],
    returns: Never.output
) { (_, _, args) throws -> Never in
    let values: [Value] = try args.allT()
    try args.finishT()

    var msg = "panicked"
    if !values.isEmpty {
        msg += " with: "
        for (i, value) in values.enumerated() {
            if i > 0 { msg += ", " }
            if case .str(let s) = value {
                msg += s.value
            } else {
                msg += value.repr()
            }
        }
    }
    throw StrError(msg)
}

// MARK: - assert

/// Ensures that a condition is fulfilled.
///
/// Port of `assert` in `mod.rs`.
let assertFunc = nativeFunc(
    "assert",
    since: .forever,
    docs: """
        Ensures that a condition is fulfilled.

        Fails with an error if the condition is not fulfilled. Does not \
        produce any output in the document.

        If you wish to test equality between two values, see `assert.eq` and \
        `assert.ne`.
        """,
    params: [
        NativeParamInfo(name: "condition", input: Bool.input, required: true),
        NativeParamInfo(name: "message", input: Str.input),
    ],
    returns: NoneValue.output,
    scope: {
        var scope = Scope()
        scope.defineFunc(assertEq)
        scope.defineFunc(assertNe)
        return scope
    }
) { _, _, args in
    let condition: Bool = try args.expectT("condition")
    let message: Str? = try args.namedT("message")
    try args.finishT()

    guard condition else {
        if let message {
            throw StrError("assertion failed: \(message.value)")
        } else {
            throw StrError("assertion failed")
        }
    }
    return NoneValue()
}

/// Ensures that two values are equal.
///
/// Port of `assert::eq` in `mod.rs`.
let assertEq = nativeFunc(
    "eq",
    title: "Assert Equal",
    since: .version([0, 4, 0]),
    docs: """
        Ensures that two values are equal.

        Fails with an error if the first value is not equal to the second. \
        Does not produce any output in the document.
        """,
    params: [
        NativeParamInfo(name: "left", input: .any, required: true),
        NativeParamInfo(name: "right", input: .any, required: true),
        NativeParamInfo(name: "message", input: Str.input),
    ],
    returns: NoneValue.output
) { _, _, args in
    let left: Value = try args.expectT("left")
    let right: Value = try args.expectT("right")
    let message: Str? = try args.namedT("message")
    try args.finishT()

    guard left != right else { return NoneValue() }
    if let message {
        throw StrError("equality assertion failed: \(message.value)")
    } else {
        throw StrError(
            "equality assertion failed: value \(left.repr()) was not equal to \(right.repr())")
    }
}

/// Ensures that two values are not equal.
///
/// Port of `assert::ne` in `mod.rs`.
let assertNe = nativeFunc(
    "ne",
    title: "Assert Not Equal",
    since: .version([0, 4, 0]),
    docs: """
        Ensures that two values are not equal.

        Fails with an error if the first value is equal to the second. Does \
        not produce any output in the document.
        """,
    params: [
        NativeParamInfo(name: "left", input: .any, required: true),
        NativeParamInfo(name: "right", input: .any, required: true),
        NativeParamInfo(name: "message", input: Str.input),
    ],
    returns: NoneValue.output
) { _, _, args in
    let left: Value = try args.expectT("left")
    let right: Value = try args.expectT("right")
    let message: Str? = try args.namedT("message")
    try args.finishT()

    guard left == right else { return NoneValue() }
    if let message {
        throw StrError("inequality assertion failed: \(message.value)")
    } else {
        throw StrError(
            "inequality assertion failed: value \(left.repr()) was equal to \(right.repr())")
    }
}
