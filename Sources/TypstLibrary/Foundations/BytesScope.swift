import Foundation
import TypstSyntax
import TypstUtils

// The `bytes` type's associated scope — port of the `#[scope] impl Bytes`
// block in upstream `foundations/bytes.rs`.

/// The out-of-bounds-without-default error (upstream `out_of_bounds_no_default`).
private func bytesOutOfBoundsNoDefault(_ index: Int64, _ len: Int) -> HintedString {
    HintedString(
        "byte index out of bounds (index: \(index), len: \(len)) " +
        "and no default value was specified")
}

/// `bytes(..)` — port of `Bytes::construct`.
let bytesConstruct = nativeFunc(
    "bytes",
    title: "Bytes",
    since: .version([0, 7, 0]),
    docs: """
        Converts a value to bytes.

        - Strings are encoded in UTF-8.
        - Arrays of integers between `{0}` and `{255}` are converted \
          directly. The dedicated byte representation is much more \
          efficient than the array representation and thus typically used \
          for large byte buffers (e.g. image data).
        """,
    params: [
        NativeParamInfo(
            name: "value",
            input: ToBytes.input,
            required: true)
    ],
    returns: Bytes.output
) { _, _, args in
    let value: ToBytes = try args.expectT("value")
    try args.finishT()
    return value.bytes
}

/// `bytes.len` — port of `Bytes::len`.
let bytesLen = nativeFunc(
    "len",
    title: "Length",
    since: .version([0, 7, 0]),
    docs: "The length in bytes.",
    params: [
        NativeParamInfo(name: "self", input: Bytes.input, required: true)
    ],
    returns: Int64.output
) { _, _, args in
    let bytes: Bytes = try args.expectT("self")
    try args.finishT()
    return Int64(bytes.count)
}

/// `bytes.at` — port of `Bytes::at`.
let bytesAt = nativeFunc(
    "at",
    since: .version([0, 7, 0]),
    docs: """
        Returns the byte at the specified index. Returns the default \
        value if the index is out of bounds or fails with an error if no \
        default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: Bytes.input, required: true),
        NativeParamInfo(name: "index", input: Int64.input, required: true),
        NativeParamInfo(
            name: "default",
            input: Value.input,
            defaultValue: { .none },
            positional: false,
            named: true)
    ],
    returns: Value.output
) { _, _, args in
    let bytes: Bytes = try args.expectT("self")
    let index: Int64 = try args.expectT("index")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()

    var i = index
    if i < 0 { i += Int64(bytes.count) }
    if i >= 0, let idx = Int(exactly: i), idx < bytes.count {
        return Value.int(Int64(bytes.storage[idx]))
    }
    if let defaultValue { return defaultValue }
    throw bytesOutOfBoundsNoDefault(index, bytes.count)
}

/// `bytes.slice` — port of `Bytes::slice`.
let bytesSlice = nativeFunc(
    "slice",
    since: .version([0, 7, 0]),
    docs: """
        Extracts a subslice of the bytes. Fails with an error if the \
        start or end index is out of bounds.
        """,
    params: [
        NativeParamInfo(name: "self", input: Bytes.input, required: true),
        NativeParamInfo(name: "start", input: Int64.input, required: true),
        NativeParamInfo(name: "end", input: Int64.input),
        NativeParamInfo(
            name: "count",
            input: Int64.input,
            positional: false,
            named: true)
    ],
    returns: Bytes.output
) { _, _, args in
    let bytes: Bytes = try args.expectT("self")
    let startArg: Int64 = try args.expectT("start")
    let endArg: Int64? = try args.eatOpt()
    let count: Int64? = try args.namedOpt("count")
    try args.finishT()

    // Upstream `locate`: negative indexes wrap; bounds are `0...=len`.
    func locate(_ index: Int64) -> Int? {
        var i = index
        if i < 0 { i += Int64(bytes.count) }
        guard i >= 0, let idx = Int(exactly: i), idx <= bytes.count else {
            return nil
        }
        return idx
    }

    if endArg != nil && count != nil {
        throw StrError("`end` and `count` are mutually exclusive")
    }
    guard let start = locate(startArg) else {
        throw StrError(
            "byte index out of bounds (index: \(startArg), len: \(bytes.count))")
    }
    let endIndex = endArg ?? count.map { Int64(start) + $0 }
    let endValue = endIndex ?? Int64(bytes.count)
    guard let end0 = locate(endValue) else {
        throw StrError(
            "byte index out of bounds (index: \(endValue), len: \(bytes.count))")
    }
    let end = Swift.max(end0, start)
    return Bytes(Array(bytes.storage[start..<end]))
}

/// Build the scope containing all `bytes` methods.
func bytesScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(bytesConstruct)
    scope.defineFunc(bytesLen)
    scope.defineFunc(bytesAt)
    scope.defineFunc(bytesSlice)
    return scope
}
