import Foundation
import TypstSyntax
import TypstUtils

// The `array` type's associated scope — port of the `#[scope] impl Array`
// block in upstream `foundations/array.rs`.
//
// Callback-taking methods (`find`, `position`, `filter`, `map`, `fold`,
// `any`, `all`, `sorted`, `dedup`, `reduce`) call `Func.call`, which
// already dispatches native functions; closures error until the eval
// milestone installs `evalClosure`.
//
// Mutating methods (`push`, `pop`, `insert`, `remove`) take `&mut self`
// upstream; the evaluator's `call_method_mut` performs the real mutation.
// As first-class functions they operate on a copy — matching upstream,
// where the scope entries exist for signatures.

// MARK: - Constructor

/// `array(..)` — port of `Array::construct`.
let arrayConstruct = nativeFunc(
    "array",
    title: "Array",
    since: .version([0, 7, 0]),
    docs: """
        Converts a value to an array.

        Note that this function is only intended for conversion of a \
        collection-like value to an array, not for creation of an array \
        from individual items. Use the array syntax `(1, 2, 3)` (or `(1,)` \
        for a single-element array) instead.
        """,
    params: [
        NativeParamInfo(
            name: "value",
            input: ToArray.input,
            required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let value: ToArray = try args.expectT("value")
    try args.finishT()
    return value.array
}

// MARK: - Simple accessors

/// `array.len` — port of `Array::len`.
let arrayLen = nativeFunc(
    "len",
    title: "Length",
    since: .forever,
    docs: "The number of values in the array.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true)
    ],
    returns: Int64.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    try args.finishT()
    return Int64(array.count)
}

/// Shared `default:` named param info (upstream `#[named] default: Option<Value>`).
private let arrayDefaultParam = NativeParamInfo(
    name: "default",
    input: Value.input,
    defaultValue: { .none },
    positional: false,
    named: true)

/// `array.first` — port of `Array::first`.
let arrayFirst = nativeFunc(
    "first",
    since: .forever,
    docs: """
        Returns the first item in the array. May be used on the left-hand \
        side of an assignment. Returns the default value if the array is \
        empty or fails with an error if no default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()
    return try unwrap(array.first(default: defaultValue))
}

/// `array.last` — port of `Array::last`.
let arrayLast = nativeFunc(
    "last",
    since: .forever,
    docs: """
        Returns the last item in the array. May be used on the left-hand \
        side of an assignment. Returns the default value if the array is \
        empty or fails with an error if no default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()
    return try unwrap(array.last(default: defaultValue))
}

/// The out-of-bounds-without-default error (upstream `out_of_bounds_no_default`).
private func arrayOutOfBoundsNoDefault(_ index: Int64, _ len: Int) -> HintedString {
    HintedString(
        "array index out of bounds (index: \(index), len: \(len)) " +
        "and no default value was specified")
}

/// `array.at` — port of `Array::at`.
let arrayAt = nativeFunc(
    "at",
    since: .forever,
    docs: """
        Returns the item at the specified index in the array. May be used \
        on the left-hand side of an assignment. Returns the default value \
        if the index is out of bounds or fails with an error if no \
        default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "index", input: Int64.input, required: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let index: Int64 = try args.expectT("index")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()

    if let i = array.locate(index) {
        return array.items[i]
    }
    if let defaultValue { return defaultValue }
    throw arrayOutOfBoundsNoDefault(index, array.count)
}

// MARK: - Mutating methods

/// `array.push` — port of `Array::push`.
let arrayPush = nativeFunc(
    "push",
    since: .forever,
    docs: "Adds a value to the end of the array.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "value", input: Value.input, required: true),
    ],
    returns: Value.output
) { _, _, args in
    var array: ArrayValue = try args.expectT("self")
    let value: Value = try args.expectT("value")
    try args.finishT()
    array.push(value)
    return Value.none
}

/// `array.pop` — port of `Array::pop`.
let arrayPop = nativeFunc(
    "pop",
    since: .forever,
    docs: "Removes the last item from the array and returns it. Fails with an error if the array is empty.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true)
    ],
    returns: Value.output
) { _, _, args in
    var array: ArrayValue = try args.expectT("self")
    try args.finishT()
    return try unwrap(array.pop())
}

/// `array.insert` — port of `Array::insert`.
let arrayInsert = nativeFunc(
    "insert",
    since: .forever,
    docs: """
        Inserts a value into the array at the specified index, shifting \
        all subsequent elements to the right. Fails with an error if the \
        index is out of bounds.

        To replace an element of an array, use `array.at`.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "index", input: Int64.input, required: true),
        NativeParamInfo(name: "value", input: Value.input, required: true),
    ],
    returns: Value.output
) { _, _, args in
    var array: ArrayValue = try args.expectT("self")
    let index: Int64 = try args.expectT("index")
    let value: Value = try args.expectT("value")
    try args.finishT()
    try unwrap(array.insert(index, value))
    return Value.none
}

/// `array.remove` — port of `Array::remove`.
let arrayRemove = nativeFunc(
    "remove",
    since: .forever,
    docs: "Removes the value at the specified index from the array and return it.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "index", input: Int64.input, required: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    var array: ArrayValue = try args.expectT("self")
    let index: Int64 = try args.expectT("index")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()

    if let i = array.locate(index) {
        return array.items.remove(at: i)
    }
    if let defaultValue { return defaultValue }
    throw arrayOutOfBoundsNoDefault(index, array.count)
}

// MARK: - slice / contains

/// `array.slice` — port of `Array::slice`.
let arraySlice = nativeFunc(
    "slice",
    since: .forever,
    docs: """
        Extracts a subslice of the array. Fails with an error if the \
        start or end index is out of bounds.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "start", input: Int64.input, required: true),
        NativeParamInfo(name: "end", input: Int64.input),
        NativeParamInfo(
            name: "count",
            input: Int64.input,
            positional: false,
            named: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let start: Int64 = try args.expectT("start")
    let end: Int64? = try args.eatOpt()
    let count: Int64? = try args.namedOpt("count")
    try args.finishT()
    return try unwrap(array.slice(start: start, end: end, count: count))
}

/// `array.contains` — port of `Array::contains`.
let arrayContains = nativeFunc(
    "contains",
    since: .forever,
    docs: """
        Whether the array contains the specified value.

        This method also has dedicated syntax: You can write `{2 in (1, 2, 3)}` \
        instead of `{(1, 2, 3).contains(2)}`.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "value", input: Value.input, required: true),
    ],
    returns: Bool.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let value: Value = try args.expectT("value")
    try args.finishT()
    return array.contains(value)
}

// MARK: - Callback helpers

/// Call `f` with positional arguments, casting the result to `T`.
private func callArrayFunc<T: FromValue>(
    _ f: Func,
    engine: inout Engine,
    context: Context,
    _ values: [Value],
    span: Span
) throws -> T {
    let args = Args(span: .detached, values: values)
    return try unwrap(f.call(engine: &engine, context: context, args: args, span: span))
}

// MARK: - find / position / filter / map

/// `array.find` — port of `Array::find`.
let arrayFind = nativeFunc(
    "find",
    since: .forever,
    docs: """
        Searches for an item for which the given function returns `{true}` \
        and returns the first match or `{none}` if there is no match.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "searcher", input: Func.input, required: true)
    ],
    returns: Optional<Value>.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let searcher: Func = try args.expectT("searcher")
    try args.finishT()

    for item in array.items {
        let found: Bool = try callArrayFunc(
            searcher, engine: &engine, context: context,
            [item], span: args.span)
        if found { return item }
    }
    return Value.none
}

/// `array.position` — port of `Array::position`.
let arrayPosition = nativeFunc(
    "position",
    since: .forever,
    docs: """
        Searches for an item for which the given function returns `{true}` \
        and returns the index of the first match or `{none}` if there is no \
        match.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "searcher", input: Func.input, required: true)
    ],
    returns: Optional<Int64>.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let searcher: Func = try args.expectT("searcher")
    try args.finishT()

    for (i, item) in array.items.enumerated() {
        let found: Bool = try callArrayFunc(
            searcher, engine: &engine, context: context,
            [item], span: args.span)
        if found { return Value.int(Int64(i)) }
    }
    return Value.none
}

/// `array.filter` — port of `Array::filter`.
let arrayFilter = nativeFunc(
    "filter",
    since: .forever,
    docs: """
        Produces a new array with only the items from the original one for \
        which the given function returns `{true}`.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "test", input: Func.input, required: true)
    ],
    returns: ArrayValue.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let test: Func = try args.expectT("test")
    try args.finishT()

    var kept: [Value] = []
    for item in array.items {
        let keep: Bool = try callArrayFunc(
            test, engine: &engine, context: context,
            [item], span: args.span)
        if keep { kept.append(item) }
    }
    return ArrayValue(items: kept)
}

/// `array.map` — port of `Array::map`.
let arrayMap = nativeFunc(
    "map",
    since: .version([0, 2, 0]),
    docs: """
        Produces a new array in which all items from the original one were \
        transformed with the given function.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "mapper", input: Func.input, required: true)
    ],
    returns: ArrayValue.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let mapper: Func = try args.expectT("mapper")
    try args.finishT()

    var out: [Value] = []
    out.reserveCapacity(array.items.count)
    for item in array.items {
        let mapped: Value = try callArrayFunc(
            mapper, engine: &engine, context: context,
            [item], span: args.span)
        out.append(mapped)
    }
    return ArrayValue(items: out)
}

// MARK: - enumerate / zip

/// `array.enumerate` — port of `Array::enumerate`.
let arrayEnumerate = nativeFunc(
    "enumerate",
    since: .version([0, 2, 0]),
    docs: """
        Returns a new array with the values alongside their indices.

        The returned array consists of `(index, value)` pairs in the form \
        of length-2 arrays.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(
            name: "start",
            input: Int64.input,
            defaultValue: { .int(0) },
            positional: false,
            named: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let start: Int64 = try args.namedT("start") ?? 0
    try args.finishT()

    var out: [Value] = []
    out.reserveCapacity(array.items.count)
    for (i, value) in array.items.enumerated() {
        let (index, overflow) = start.addingReportingOverflow(Int64(i))
        guard !overflow else {
            throw StrError("array index is too large")
        }
        out.append(.array(ArrayValue(items: [.int(index), value])))
    }
    return ArrayValue(items: out)
}

/// `array.zip` — port of `Array::zip`.
let arrayZip = nativeFunc(
    "zip",
    since: .version([0, 3, 0]),
    docs: """
        Zips the array with other arrays.

        Returns an array of arrays, where the `i`th inner array contains \
        all the `i`th elements from each original array.

        If the arrays to be zipped have different lengths, they are zipped \
        up to the last element of the shortest array and all remaining \
        elements are ignored.

        This function is variadic, meaning that you can zip multiple \
        arrays together at once.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(
            name: "exact",
            input: Bool.input,
            defaultValue: { .bool(false) },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "others",
            input: Spanned<ArrayValue, Span>.input,
            positional: true,
            variadic: true,
            required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let exact: Bool = try args.namedT("exact") ?? false

    // Fast path for one array.
    if args.remaining == 0 {
        try args.finishT()
        return ArrayValue(items: array.items.map {
            .array(ArrayValue(items: [$0]))
        })
    }

    // Fast path for just two arrays.
    if args.remaining == 1 {
        let other: Spanned<ArrayValue, Span> = try args.expectT("others")
        try args.finishT()
        if exact && array.count != other.value.count {
            throw bailSpan(
                other.span,
                "second array has different length (\(other.value.count)) " +
                "from first array (\(array.count))")
        }
        var out: [Value] = []
        for (first, second) in zip(array.items, other.value.items) {
            out.append(.array(ArrayValue(items: [first, second])))
        }
        return ArrayValue(items: out)
    }

    // More than one array: consume all remaining positionals.
    let others: [Spanned<ArrayValue, Span>] = try args.allT()
    try args.finishT()

    if exact {
        var errors: [SourceDiagnostic] = []
        for sp in others where sp.value.count != array.count {
            errors.append(SourceDiagnostic.error(
                sp.span,
                "array has different length (\(sp.value.count)) " +
                "from first array (\(array.count))"))
        }
        if !errors.isEmpty {
            throw SourceDiagnostics(errors)
        }
    }

    var iterators = others.map { $0.value.items.makeIterator() }
    var out: [Value] = []
    out.reserveCapacity(array.count)
    for this in array.items {
        var row: [Value] = [this]
        row.reserveCapacity(1 + iterators.count)
        var exhausted = false
        for i in iterators.indices {
            guard let item = iterators[i].next() else {
                exhausted = true
                break
            }
            row.append(item)
        }
        if exhausted { break }
        out.append(.array(ArrayValue(items: row)))
    }
    return ArrayValue(items: out)
}

// MARK: - fold / sum / product

/// `array.fold` — port of `Array::fold`.
let arrayFold = nativeFunc(
    "fold",
    since: .forever,
    docs: """
        Folds all items into a single value using an accumulator function.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "init", input: Value.input, required: true),
        NativeParamInfo(name: "folder", input: Func.input, required: true)
    ],
    returns: Value.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let initial: Value = try args.expectT("init")
    let folder: Func = try args.expectT("folder")
    try args.finishT()

    var acc = initial
    for item in array.items {
        acc = try callArrayFunc(
            folder, engine: &engine, context: context,
            [acc, item], span: args.span)
    }
    return acc
}

/// `array.sum` — port of `Array::sum`.
let arraySum = nativeFunc(
    "sum",
    since: .version([0, 3, 0]),
    docs: "Sums all items (works for all types that can be added).",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()

    var iter = array.items.makeIterator()
    guard var acc = iter.next() ?? defaultValue else {
        throw StrError("cannot calculate sum of empty array with no default")
    }
    for item in iter {
        acc = try unwrap(ops_add(acc, item))
    }
    return acc
}

/// `array.product` — port of `Array::product`.
let arrayProduct = nativeFunc(
    "product",
    since: .version([0, 3, 0]),
    docs: "Calculates the product of all items (works for all types that can be multiplied).",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()

    var iter = array.items.makeIterator()
    guard var acc = iter.next() ?? defaultValue else {
        throw StrError("cannot calculate product of empty array with no default")
    }
    for item in iter {
        acc = try unwrap(ops_mul(acc, item))
    }
    return acc
}

// MARK: - any / all

/// `array.any` — port of `Array::any`.
let arrayAny = nativeFunc(
    "any",
    since: .forever,
    docs: "Whether the given function returns `{true}` for any item in the array.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "test", input: Func.input, required: true)
    ],
    returns: Bool.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let test: Func = try args.expectT("test")
    try args.finishT()

    for item in array.items {
        let result: Bool = try callArrayFunc(
            test, engine: &engine, context: context,
            [item], span: args.span)
        if result { return true }
    }
    return false
}

/// `array.all` — port of `Array::all`.
let arrayAll = nativeFunc(
    "all",
    since: .forever,
    docs: "Whether the given function returns `{true}` for all items in the array.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "test", input: Func.input, required: true)
    ],
    returns: Bool.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let test: Func = try args.expectT("test")
    try args.finishT()

    for item in array.items {
        let result: Bool = try callArrayFunc(
            test, engine: &engine, context: context,
            [item], span: args.span)
        if !result { return false }
    }
    return true
}

// MARK: - flatten / rev / split / join / intersperse / chunks / windows

/// Recursively flatten nested arrays (upstream `Array::flatten` body).
private func flattenArrayItems(_ items: [Value]) -> [Value] {
    var flat: [Value] = []
    flat.reserveCapacity(items.count)
    for item in items {
        if case let .array(nested) = item {
            flat.append(contentsOf: flattenArrayItems(nested.items))
        } else {
            flat.append(item)
        }
    }
    return flat
}

/// `array.flatten` — port of `Array::flatten`.
let arrayFlatten = nativeFunc(
    "flatten",
    since: .forever,
    docs: "Combine all nested arrays into a single flat one.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    try args.finishT()
    return ArrayValue(items: flattenArrayItems(array.items))
}

/// `array.rev` — port of `Array::rev`.
let arrayRev = nativeFunc(
    "rev",
    title: "Reverse",
    since: .forever,
    docs: "Return a new array with the same items, but in reverse order.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    try args.finishT()
    return ArrayValue(items: array.items.reversed())
}

/// `array.split` — port of `Array::split`.
let arraySplit = nativeFunc(
    "split",
    since: .forever,
    docs: """
        Split the array at occurrences of the specified value.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "at", input: Value.input, required: true),
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let at: Value = try args.expectT("at")
    try args.finishT()

    var out: [Value] = []
    var current: [Value] = []
    for item in array.items {
        if item == at {
            out.append(.array(ArrayValue(items: current)))
            current = []
        } else {
            current.append(item)
        }
    }
    out.append(.array(ArrayValue(items: current)))
    return ArrayValue(items: out)
}

/// `array.join` — port of `Array::join`.
let arrayJoin = nativeFunc(
    "join",
    since: .forever,
    docs: "Combine all items in the array into one.",
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(
            name: "separator",
            input: Value.input,
            defaultValue: { .none }),
        NativeParamInfo(
            name: "last",
            input: Value.input,
            defaultValue: { .none },
            positional: false,
            named: true),
        arrayDefaultParam
    ],
    returns: Value.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let separator: Value? = try args.eatOpt()
    let lastOpt: Value? = try args.namedOpt("last")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()

    let len = array.items.count
    if len == 0, let defaultValue {
        return defaultValue
    }

    let sep = separator ?? .none
    var lastRemaining = lastOpt
    var result: Value = .none
    for (i, value) in array.items.enumerated() {
        if i > 0 {
            if i + 1 == len, let l = lastRemaining {
                lastRemaining = nil
                result = try unwrap(ops_join(result, l))
            } else {
                result = try unwrap(ops_join(result, sep))
            }
        }
        result = try unwrap(ops_join(result, value))
    }
    return result
}

/// `array.intersperse` — port of `Array::intersperse`.
let arrayIntersperse = nativeFunc(
    "intersperse",
    since: .version([0, 8, 0]),
    docs: """
        Returns an array with a copy of the separator value placed between \
        adjacent elements.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "separator", input: Value.input, required: true),
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let separator: Value = try args.expectT("separator")
    try args.finishT()

    guard !array.items.isEmpty else { return ArrayValue() }
    var out: [Value] = []
    out.reserveCapacity(2 * array.items.count - 1)
    for (i, item) in array.items.enumerated() {
        if i > 0 { out.append(separator) }
        out.append(item)
    }
    return ArrayValue(items: out)
}

/// `array.chunks` — port of `Array::chunks`.
let arrayChunks = nativeFunc(
    "chunks",
    since: .version([0, 11, 0]),
    docs: """
        Splits an array into non-overlapping chunks, starting at the \
        beginning, ending with a single remainder chunk.

        All chunks but the last have `chunk-size` elements. If `exact` is \
        set to `{true}`, the remainder is dropped if it contains less than \
        `chunk-size` elements.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "chunk-size", input: NonZeroUsize.input, required: true),
        NativeParamInfo(
            name: "exact",
            input: Bool.input,
            defaultValue: { .bool(false) },
            positional: false,
            named: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let chunkSize: NonZeroUsize = try args.expectT("chunk-size")
    let exact: Bool = try args.namedT("exact") ?? false
    try args.finishT()

    let size = chunkSize.value
    var out: [Value] = []
    if exact {
        var i = 0
        while i + size <= array.items.count {
            out.append(.array(ArrayValue(
                items: Array(array.items[i..<(i + size)]))))
            i += size
        }
    } else {
        var i = 0
        while i < array.items.count {
            let end = Swift.min(i + size, array.items.count)
            out.append(.array(ArrayValue(items: Array(array.items[i..<end]))))
            i = end
        }
    }
    return ArrayValue(items: out)
}

/// `array.windows` — port of `Array::windows`.
let arrayWindows = nativeFunc(
    "windows",
    since: .version([0, 12, 0]),
    docs: """
        Returns sliding windows of `window-size` elements over an array.

        If the array length is less than `window-size`, this will return an \
        empty array.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "window-size", input: NonZeroUsize.input, required: true),
    ],
    returns: ArrayValue.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    let windowSize: NonZeroUsize = try args.expectT("window-size")
    try args.finishT()

    let size = windowSize.value
    var out: [Value] = []
    if array.items.count >= size {
        for i in 0...(array.items.count - size) {
            out.append(.array(ArrayValue(
                items: Array(array.items[i..<(i + size)]))))
        }
    }
    return ArrayValue(items: out)
}

// MARK: - sorted / dedup / to_dict / reduce

/// A stable merge sort (upstream uses `glidesort`, which is stable).
private func stableSortedMerge<T>(_ items: [T], _ areInOrder: (T, T) -> ComparisonResult) -> [T] {
    if items.count <= 1 { return items }
    let mid = items.count / 2
    let left = stableSortedMerge(Array(items[..<mid]), areInOrder)
    let right = stableSortedMerge(Array(items[mid...]), areInOrder)
    var out: [T] = []
    out.reserveCapacity(items.count)
    var i = 0, j = 0
    while i < left.count && j < right.count {
        // Stable: take left when equal or when left should precede right.
        if areInOrder(left[i], right[j]) != .orderedDescending {
            out.append(left[i]); i += 1
        } else {
            out.append(right[j]); j += 1
        }
    }
    out.append(contentsOf: left[i...])
    out.append(contentsOf: right[j...])
    return out
}

/// `array.sorted` — port of `Array::sorted`.
let arraySorted = nativeFunc(
    "sorted",
    since: .forever,
    docs: """
        Return a sorted version of this array, optionally by a given key \
        function. The sorting algorithm used is stable.

        Returns an error if a pair of values selected for comparison could \
        not be compared, or if the key or comparison function (if given) \
        yield an error.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(
            name: "key",
            input: Spanned<Func, Span>.input,
            defaultValue: { .none },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "by",
            input: Spanned<Func, Span>.input,
            defaultValue: { .none },
            positional: false,
            named: true)
    ],
    returns: ArrayValue.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let key: Spanned<Func, Span>? = try args.namedOpt("key")
    let by: Spanned<Func, Span>? = try args.namedOpt("by")
    try args.finishT()
    let span = args.span

    if let by {
        // Boolean-comparator path: `by(x, y)` true = in order.
        var result: SourceResult<Void> = .success(())
        func areInOrder(_ x: Value, _ y: Value) -> ComparisonResult {
            do {
                var kx = x, ky = y
                if let key {
                    kx = try callArrayFunc(
                        key.value, engine: &engine, context: context,
                        [x], span: span)
                    ky = try callArrayFunc(
                        key.value, engine: &engine, context: context,
                        [y], span: span)
                }
                let b: Bool = try callArrayFunc(
                    by.value, engine: &engine, context: context,
                    [kx, ky], span: span)
                // `by(x, y)` true means x belongs before y; a stable merge
                // sort preserves the original order for equal elements,
                // matching upstream's unspecified-order contract for
                // inconsistent comparators.
                return b ? .orderedAscending : .orderedDescending
            } catch {
                if case .success = result {
                    result = sourceFailure(error, span: span)
                }
                return .orderedSame
            }
        }
        let sorted = stableSortedMerge(array.items, areInOrder)
        try unwrap(result)
        return ArrayValue(items: sorted)
    }

    // Key/compare path.
    var result: SourceResult<Void> = .success(())
    func keyOf(_ x: Value) throws -> Value {
        if let key {
            return try callArrayFunc(
                key.value, engine: &engine, context: context,
                [x], span: span)
        }
        return x
    }
    let sorted = stableSortedMerge(array.items) { a, b in
        do {
            let ka = try keyOf(a)
            let kb = try keyOf(b)
            switch ops_compare(ka, kb) {
            case let .success(order): return order
            case let .failure(error):
                if case .success = result {
                    var diagnostic = SourceDiagnostic.error(span, error.message)
                    diagnostic.hint(key == nil
                        ? "consider choosing a `key` or defining the comparison with `by`"
                        : "consider defining the comparison with `by` or choosing a different `key`")
                    result = .failure(SourceDiagnostics(diagnostic))
                }
                return .orderedSame
            }
        } catch {
            if case .success = result {
                result = sourceFailure(error, span: span)
            }
            return .orderedSame
        }
    }
    try unwrap(result)
    return ArrayValue(items: sorted)
}

/// `array.dedup` — port of `Array::dedup`.
let arrayDedup = nativeFunc(
    "dedup",
    title: "Deduplicate",
    since: .version([0, 7, 0]),
    docs: """
        Deduplicates all items in the array.

        Returns a new array with all duplicate items removed. Only the \
        first element of each duplicate is kept.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(
            name: "key",
            input: Spanned<Func, Span>.input,
            defaultValue: { .none },
            positional: false,
            named: true)
    ],
    returns: ArrayValue.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let key: Spanned<Func, Span>? = try args.namedOpt("key")
    try args.finishT()

    func keyOf(_ x: Value) throws -> Value {
        if let key {
            return try callArrayFunc(
                key.value, engine: &engine, context: context,
                [x], span: args.span)
        }
        return x
    }

    var out: [Value] = []
    out.reserveCapacity(array.items.count)
    outerLoop: for value in array.items {
        let k = try keyOf(value)
        if out.isEmpty {
            out.append(value)
            continue
        }
        for second in out {
            if ops_equal(k, try keyOf(second)) {
                continue outerLoop
            }
        }
        out.append(value)
    }
    return ArrayValue(items: out)
}

/// `array.to-dict` — port of `Array::to_dict`.
let arrayToDict = nativeFunc(
    "to-dict",
    since: .version([0, 12, 0]),
    docs: """
        Converts an array of pairs into a dictionary. The first value of \
        each pair is the key, the second the value.

        If the same key occurs multiple times, the last value is selected.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true)
    ],
    returns: Dict.output
) { _, _, args in
    let array: ArrayValue = try args.expectT("self")
    try args.finishT()

    var pairs: [(Str, Value)] = []
    pairs.reserveCapacity(array.items.count)
    for value in array.items {
        guard case let .array(pair) = value else {
            throw StrError(
                "expected (str, any) pairs, found \(value.type)")
        }
        guard pair.items.count == 2 else {
            throw StrError(
                "expected pairs of length 2, found length \(pair.items.count)")
        }
        let keyValue = pair.items[0]
        let val = pair.items[1]
        guard case let .str(key) = keyValue else {
            throw StrError(
                "expected key of type string, found \(keyValue.type)")
        }
        pairs.append((key, val))
    }
    return Dict(pairs)
}

/// `array.reduce` — port of `Array::reduce`.
let arrayReduce = nativeFunc(
    "reduce",
    since: .version([0, 12, 0]),
    docs: """
        Reduces the elements to a single one, by repeatedly applying a \
        reducing operation.

        If the array is empty, returns `{none}`, otherwise, returns the \
        result of the reduction.
        """,
    params: [
        NativeParamInfo(name: "self", input: ArrayValue.input, required: true),
        NativeParamInfo(name: "reducer", input: Func.input, required: true)
    ],
    returns: Value.output
) { engine, context, args in
    let array: ArrayValue = try args.expectT("self")
    let reducer: Func = try args.expectT("reducer")
    try args.finishT()

    var iter = array.items.makeIterator()
    var acc = iter.next() ?? .none
    for item in iter {
        acc = try callArrayFunc(
            reducer, engine: &engine, context: context,
            [acc, item], span: args.span)
    }
    return acc
}

// MARK: - `range` (global + array scope)

/// `range(..)` — port of `Array::range`. Available both in the array
/// scope and globally (upstream `lib.rs` defines it globally).
let arrayRange = nativeFunc(
    "range",
    since: .forever,
    docs: """
        Create an array consisting of a sequence of numbers.

        If you pass just one positional parameter, it is interpreted as \
        the `end` of the range. If you pass two, they describe the `start` \
        and `end` of the range.
        """,
    params: [
        NativeParamInfo(
            name: "end",
            input: Int64.input,
            positional: true,
            required: true),
        NativeParamInfo(
            name: "start",
            input: Int64.input,
            positional: true),
        NativeParamInfo(
            name: "inclusive",
            input: Bool.input,
            defaultValue: { .bool(false) },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "step",
            input: NonZeroI64.input,
            defaultValue: { .int(1) },
            positional: false,
            named: true)
    ],
    returns: ArrayValue.output
) { _, _, args in
    // Upstream: first positional is labeled `end` in errors; an optional
    // second positional is `start`.
    let first: Int64 = try args.expectT("end")
    let (start, end): (Int64, Int64)
    if let second: Int64 = try args.eatT() {
        (start, end) = (first, second)
    } else {
        (start, end) = (0, first)
    }

    let inclusive: Bool = try args.namedT("inclusive") ?? false
    let step: NonZeroI64 = try args.namedT("step") ?? NonZeroI64(value: 1)
    try args.finishT()

    let stepValue = step.value
    // Upstream `step_dir = 0.cmp(&step)`: positive step → ascending.
    let ascending = stepValue > 0

    var x = start
    var array = ArrayValue()

    func inBounds(_ x: Int64) -> Bool {
        if inclusive {
            // `x` must not exceed `end`.
            return ascending ? x <= end : x >= end
        }
        // `x` must stay strictly before `end`.
        return ascending ? x < end : x > end
    }

    while inBounds(x) {
        array.push(.int(x))
        let (next, overflow) = x.addingReportingOverflow(stepValue)
        if overflow { break }
        x = next
    }
    return array
}

// MARK: - Scope

/// Build the scope containing all `array` methods.
func arrayScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(arrayConstruct)
    scope.defineFunc(arrayLen)
    scope.defineFunc(arrayFirst)
    scope.defineFunc(arrayLast)
    scope.defineFunc(arrayAt)
    scope.defineFunc(arrayPush)
    scope.defineFunc(arrayPop)
    scope.defineFunc(arrayInsert)
    scope.defineFunc(arrayRemove)
    scope.defineFunc(arraySlice)
    scope.defineFunc(arrayContains)
    scope.defineFunc(arrayFind)
    scope.defineFunc(arrayPosition)
    scope.defineFunc(arrayRange)
    scope.defineFunc(arrayFilter)
    scope.defineFunc(arrayMap)
    scope.defineFunc(arrayEnumerate)
    scope.defineFunc(arrayZip)
    scope.defineFunc(arrayFold)
    scope.defineFunc(arraySum)
    scope.defineFunc(arrayProduct)
    scope.defineFunc(arrayAny)
    scope.defineFunc(arrayAll)
    scope.defineFunc(arrayFlatten)
    scope.defineFunc(arrayRev)
    scope.defineFunc(arraySplit)
    scope.defineFunc(arrayJoin)
    scope.defineFunc(arrayIntersperse)
    scope.defineFunc(arrayChunks)
    scope.defineFunc(arrayWindows)
    scope.defineFunc(arraySorted)
    scope.defineFunc(arrayDedup)
    scope.defineFunc(arrayToDict)
    scope.defineFunc(arrayReduce)
    return scope
}
