import Foundation
import TypstSyntax
import TypstUtils

// The `dictionary` type's associated scope — port of the `#[scope] impl
// Dict` block in upstream `foundations/dict.rs`.

/// `dictionary(..)` — port of `Dict::construct`.
///
/// Converts a module into a dictionary of its scope's bindings.
/// Upstream's `ToDict` cast only accepts modules.
let dictionaryConstruct = nativeFunc(
    "dictionary",
    title: "Dictionary",
    since: .forever,
    docs: """
        Converts a value into a dictionary.

        Note that this function is only intended for conversion of a \
        dictionary-like value to a dictionary, not for creation of a \
        dictionary from individual pairs. Use the dictionary syntax \
        `(key: value)` instead. Also see `array.to-dict` for converting \
        arrays to dictionaries.
        """,
    params: [
        NativeParamInfo(
            name: "value",
            input: Module.input,
            positional: true,
            required: true)
    ],
    returns: Dict.output
) { engine, _, args in
    let module: Module = try args.expectT("value")
    try args.finishT()

    // Upstream filters bindings through a silent guard, discarding
    // feature/deprecation failures.
    let guard_ = SilentBindingGuard(
        features: Features(
            Set(engine.world.library.value.features.enabled.compactMap {
                Feature(rawValue: $0)
            })))
    var pairs: [(Str, Value)] = []
    for (key, binding) in module.scope.bindings {
        if case let .success(value) = binding.read(guard_) {
            pairs.append((Str(key), value))
        }
    }
    return Dict(pairs)
}

/// `dictionary.len` — port of `Dict::len`.
let dictLen = nativeFunc(
    "len",
    title: "Length",
    since: .forever,
    docs: "The number of pairs in the dictionary.",
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true)
    ],
    returns: Int64.output
) { _, _, args in
    let dict: Dict = try args.expectT("self")
    try args.finishT()
    return Int64(dict.count)
}

/// `dictionary.at` — port of `Dict::at`.
let dictAt = nativeFunc(
    "at",
    since: .forever,
    docs: """
        Returns the value associated with the specified key in the \
        dictionary.

        May be used on the left-hand side of an assignment if the key is \
        already present in the dictionary. Returns the default value if \
        the key is not part of the dictionary or fails with an error if \
        no default value was specified.

        Values may also be accessed with field syntax (e.g. `{(key: 42).key}`) \
        if no default is needed.
        """,
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true),
        NativeParamInfo(name: "key", input: Str.input, required: true),
        NativeParamInfo(
            name: "default",
            input: Value.input,
            defaultValue: { .none },
            positional: false,
            named: true)
    ],
    returns: Value.output
) { _, _, args in
    let dict: Dict = try args.expectT("self")
    let key: Str = try args.expectT("key")
    let defaultValue: Value? = try args.namedT("default")
    try args.finishT()

    if let value = dict.get(key.value) {
        return value
    }
    if let defaultValue { return defaultValue }
    throw bailHint(
        "dictionary does not contain key \(key.repr()) " +
        "and no default value was specified")
}

/// `dictionary.insert` — port of `Dict::insert`.
///
/// Upstream declares this `&mut self`; mutation is dispatched by the
/// evaluator's `call_method_mut`, while this scope entry provides the
/// signature (calling it as a plain function mutates a copy, like
/// upstream).
let dictInsert = nativeFunc(
    "insert",
    since: .forever,
    docs: """
        Inserts a new pair into the dictionary. If the dictionary already \
        contains this key, the value is updated.

        To insert multiple pairs at once, you can alternatively add another \
        dictionary with the `+=` operator.
        """,
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true),
        NativeParamInfo(name: "key", input: Str.input, required: true),
        NativeParamInfo(name: "value", input: Value.input, required: true),
    ],
    returns: Value.output
) { _, _, args in
    var dict: Dict = try args.expectT("self")
    let key: Str = try args.expectT("key")
    let value: Value = try args.expectT("value")
    try args.finishT()
    dict.insert(key, value)
    return Value.none
}

/// `dictionary.remove` — port of `Dict::remove`.
let dictRemove = nativeFunc(
    "remove",
    since: .forever,
    docs: "Removes a pair from the dictionary by key and return the value.",
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true),
        NativeParamInfo(name: "key", input: Str.input, required: true),
        NativeParamInfo(
            name: "default",
            input: Value.input,
            defaultValue: { .none },
            positional: false,
            named: true)
    ],
    returns: Value.output
) { _, _, args in
    var dict: Dict = try args.expectT("self")
    let key: Str = try args.expectT("key")
    let defaultValue: Value? = try args.namedT("default")
    try args.finishT()

    if let value = dict.remove(key.value) {
        return value
    }
    if let defaultValue { return defaultValue }
    throw bailHint("dictionary does not contain key \(key.repr())")
}

/// `dictionary.keys` — port of `Dict::keys`.
let dictKeys = nativeFunc(
    "keys",
    since: .forever,
    docs: "Returns the keys of the dictionary as an array in insertion order.",
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let dict: Dict = try args.expectT("self")
    try args.finishT()
    return ArrayValue(items: dict.keys.map { .str($0) })
}

/// `dictionary.values` — port of `Dict::values`.
let dictValues = nativeFunc(
    "values",
    since: .forever,
    docs: "Returns the values of the dictionary as an array in insertion order.",
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let dict: Dict = try args.expectT("self")
    try args.finishT()
    return ArrayValue(items: dict.values)
}

/// `dictionary.pairs` — port of `Dict::pairs`.
let dictPairs = nativeFunc(
    "pairs",
    since: .forever,
    docs: """
        Returns the keys and values of the dictionary as an array of \
        pairs. Each pair is represented as an array of length two.
        """,
    params: [
        NativeParamInfo(name: "self", input: Dict.input, required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let dict: Dict = try args.expectT("self")
    try args.finishT()
    return ArrayValue(items: zip(dict.keys, dict.values).map { key, value in
        .array(ArrayValue(items: [.str(key), value]))
    })
}

// MARK: - `filter` / `map` (upstream `Dict::filter`/`Dict::map`)
//
// Deferred to the eval milestone: these take user callbacks. `Func.call`
// already routes native functions, so they can be enabled once closure
// evaluation lands.

/// Build the scope containing all `dictionary` methods.
func dictScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(dictionaryConstruct)
    scope.defineFunc(dictLen)
    scope.defineFunc(dictAt)
    scope.defineFunc(dictInsert)
    scope.defineFunc(dictRemove)
    scope.defineFunc(dictKeys)
    scope.defineFunc(dictValues)
    scope.defineFunc(dictPairs)
    return scope
}
