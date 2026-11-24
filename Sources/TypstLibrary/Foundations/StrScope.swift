import Foundation
import TypstSyntax
import TypstUtils

// The `str` type's associated scope — port of the `#[scope] impl Str`
// block in upstream `str.rs`. Each entry wraps the corresponding `Str`
// method (already ported in `Str.swift`) as a `NativeFuncData`, with
// `self` as the first positional parameter like upstream's `#[func]`
// method expansion.

/// Build the scope containing all `str` methods.
func strScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(strLen)
    scope.defineFunc(strFirst)
    scope.defineFunc(strLast)
    scope.defineFunc(strAt)
    scope.defineFunc(strSlice)
    scope.defineFunc(strClusters)
    scope.defineFunc(strCodepoints)
    scope.defineFunc(strToUnicode)
    scope.defineFunc(strFromUnicode)
    scope.defineFunc(strNormalize)
    scope.defineFunc(strContains)
    scope.defineFunc(strStartsWith)
    scope.defineFunc(strEndsWith)
    scope.defineFunc(strFind)
    scope.defineFunc(strPosition)
    scope.defineFunc(strMatch)
    scope.defineFunc(strMatches)
    scope.defineFunc(strReplace)
    scope.defineFunc(strTrim)
    scope.defineFunc(strSplit)
    scope.defineFunc(strRev)
    return scope
}

/// `str` constructor — port of `Str::construct`.
let strConstruct = nativeFunc(
    "str",
    title: "String",
    since: .forever,
    docs: """
        Converts a value to a string.

        - Integers are formatted in base 10. This can be overridden with \
        the optional `base` parameter.
        - Floats are formatted in base 10 and never in exponential notation.
        - Negative integers and floats are formatted with the Unicode minus \
        sign ("−" U+2212) instead of the ASCII minus sign ("-" U+002D).
        - From labels the name is extracted.
        - Bytes are decoded as UTF-8.
        """,
    params: [
        NativeParamInfo(name: "value", input: ToStr.input, required: true),
        NativeParamInfo(name: "base", input: Base.input),
    ],
    returns: Str.output
) { _, _, args in
    let value: ToStr = try args.expectT("value")
    let base: Spanned<Base, Span> = try args.namedT("base") ?? .detached(Base.`default`)
    try args.finishT()

    switch value {
    case .str(let s):
        if case .user = base.value {
            throw bailSpan(base.span, "base is only supported for integers")
        }
        return s
    case .int(let n):
        let b = base.value.value
        if b == 1 && n > 0 {
            var diagnostic = SourceDiagnostic.error(
                base.span, "base must be between 2 and 36")
            diagnostic.hint("generate a unary representation with `\"1\" * \(n)`")
            throw SourceDiagnostics(diagnostic)
        }
        if b < 2 || b > 36 {
            throw bailSpan(base.span, "base must be between 2 and 36")
        }
        return Str(formatIntWithBase(n, base: b))
    }
}

/// `len` — the length of the string in UTF-8 encoded bytes.
let strLen = nativeFunc(
    "len",
    title: "Length",
    since: .forever,
    docs: "The length of the string in UTF-8 encoded bytes.",
    params: [NativeParamInfo(name: "self", input: Str.input, required: true)],
    returns: Int64.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    try args.finishT()
    return Int64(s.len)
}

/// Shared `default:` named parameter for `first`/`last`.
private let strDefaultParam = NativeParamInfo(name: "default", input: Str.input)

let strFirst = nativeFunc(
    "first",
    since: .forever,
    docs: """
        Extracts the first grapheme cluster of the string.

        Returns the provided default value if the string is empty or fails \
        with an error if no default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strDefaultParam,
    ],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let defaultValue: Str? = try args.namedOpt("default")
    try args.finishT()
    return try unwrap(s.first(default: defaultValue))
}

let strLast = nativeFunc(
    "last",
    since: .forever,
    docs: """
        Extracts the last grapheme cluster of the string.

        Returns the provided default value if the string is empty or fails \
        with an error if no default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strDefaultParam,
    ],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let defaultValue: Str? = try args.namedOpt("default")
    try args.finishT()
    return try unwrap(s.last(default: defaultValue))
}

let strAt = nativeFunc(
    "at",
    since: .forever,
    docs: """
        Extracts the first grapheme cluster after the specified index. \
        Returns the default value if the index is out of bounds or fails \
        with an error if no default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        NativeParamInfo(name: "index", input: Int64.input, required: true),
        NativeParamInfo(name: "default", input: .any),
    ],
    returns: .any
) { _, _, args in
    let s: Str = try args.expectT("self")
    let index: Int64 = try args.expectT("index")
    let defaultValue: Value? = try args.namedOpt("default")
    try args.finishT()
    return try unwrap(s.at(index, default: defaultValue))
}

let strSlice = nativeFunc(
    "slice",
    since: .forever,
    docs: """
        Extracts a substring of the string. Fails with an error if the \
        start or end index is out of bounds.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        NativeParamInfo(name: "start", input: Int64.input, required: true),
        NativeParamInfo(name: "end", input: Int64.input),
        NativeParamInfo(name: "count", input: Int64.input),
    ],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let start: Int64 = try args.expectT("start")
    let end: Int64? = try args.eatOpt()
    let count: Int64? = try args.namedOpt("count")
    try args.finishT()
    return try unwrap(s.slice(start: start, end: end, count: count))
}

let strClusters = nativeFunc(
    "clusters",
    since: .forever,
    docs: "Returns the grapheme clusters of the string as an array of substrings.",
    params: [NativeParamInfo(name: "self", input: Str.input, required: true)],
    returns: ArrayValue.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    try args.finishT()
    return s.clusters
}

let strCodepoints = nativeFunc(
    "codepoints",
    since: .forever,
    docs: "Returns the Unicode codepoints of the string as an array of substrings.",
    params: [NativeParamInfo(name: "self", input: Str.input, required: true)],
    returns: ArrayValue.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    try args.finishT()
    return s.codepoints
}

let strToUnicode = nativeFunc(
    "to-unicode",
    since: .version([0, 5, 0]),
    docs: "Converts a character into its corresponding code point.",
    params: [NativeParamInfo(name: "character", input: Unicode.Scalar.input, required: true)],
    returns: UInt32.output
) { _, _, args in
    let character: Unicode.Scalar = try args.expectT("character")
    try args.finishT()
    return character.value
}

let strFromUnicode = nativeFunc(
    "from-unicode",
    since: .version([0, 5, 0]),
    docs: "Converts a unicode code point into its corresponding string.",
    params: [NativeParamInfo(name: "value", input: UInt32.input, required: true)],
    returns: Str.output
) { _, _, args in
    let value: UInt32 = try args.expectT("value")
    try args.finishT()
    return try unwrap(Str.fromUnicode(value))
}

let strNormalize = nativeFunc(
    "normalize",
    since: .version([0, 14, 0]),
    docs: """
        Normalizes the string to the given Unicode normal form.

        This is useful when manipulating strings containing Unicode \
        combining characters.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        NativeParamInfo(name: "form", input: UnicodeNormalForm.input),
    ],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let form: UnicodeNormalForm = try args.namedT("form") ?? .nfc
    try args.finishT()
    return s.normalize(form)
}

/// Shared `pattern` parameter for the search methods.
private let strPatternParam = NativeParamInfo(name: "pattern", input: StrPattern.input, required: true)

let strContains = nativeFunc(
    "contains",
    since: .forever,
    docs: "Whether the string contains the specified pattern.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: Bool.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.contains(pattern)
}

let strStartsWith = nativeFunc(
    "starts-with",
    since: .forever,
    docs: "Whether the string starts with the specified pattern.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: Bool.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.startsWith(pattern)
}

let strEndsWith = nativeFunc(
    "ends-with",
    since: .forever,
    docs: "Whether the string ends with the specified pattern.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: Bool.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.endsWith(pattern)
}

let strFind = nativeFunc(
    "find",
    since: .forever,
    docs: "Returns the first match of the pattern in the string, if any.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.find(pattern)
}

let strPosition = nativeFunc(
    "position",
    since: .forever,
    docs: "Returns the byte position of the first match of the pattern.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: Int64.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.position(pattern).map { Int64($0) }
}

let strMatch = nativeFunc(
    "match",
    since: .forever,
    docs: "Returns the first match of the pattern as a dictionary, if any.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: Dict.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.match(pattern)
}

let strMatches = nativeFunc(
    "matches",
    since: .forever,
    docs: "Returns all matches of the pattern as an array of dictionaries.",
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        strPatternParam,
    ],
    returns: ArrayValue.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    try args.finishT()
    return s.matches(pattern)
}

let strReplace = nativeFunc(
    "replace",
    since: .forever,
    docs: """
        Replaces all matches of a pattern with a replacement string or the \
        result of a function applied to each match.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        NativeParamInfo(name: "pattern", input: StrPattern.input, required: true),
        NativeParamInfo(name: "replacement", input: Replacement.input, required: true),
        NativeParamInfo(name: "count", input: UInt64.input),
    ],
    returns: Str.output
) { engine, context, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern = try args.expectT("pattern")
    let replacement: Spanned<Replacement, Span> = try args.expectT("replacement")
    let count: UInt64? = try args.namedOpt("count")
    try args.finishT()

    return try unwrap(s.replace(
        pattern, replacement.value,
        count: count.map { Int(clamping: $0) },
        engine: &engine, context: context
    ))
}

let strTrim = nativeFunc(
    "trim",
    since: .forever,
    docs: """
        Trims matches of a pattern from the start and end of the string.

        If no pattern is specified, trims whitespace.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        NativeParamInfo(name: "pattern", input: StrPattern.input),
        NativeParamInfo(name: "at", input: StrSide.input),
        NativeParamInfo(name: "repeat", input: Bool.input),
    ],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern? = try args.eatOpt()
    let at: StrSide? = try args.namedOpt("at")
    let repeatMatch: Bool = try args.namedT("repeat") ?? true
    try args.finishT()
    return s.trim(pattern: pattern, at: at, repeat: repeatMatch)
}

let strSplit = nativeFunc(
    "split",
    since: .forever,
    docs: """
        Splits a string at matches of a specified pattern and returns an \
        array of the resulting parts.
        """,
    params: [
        NativeParamInfo(name: "self", input: Str.input, required: true),
        NativeParamInfo(name: "pattern", input: StrPattern.input),
    ],
    returns: ArrayValue.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    let pattern: StrPattern? = try args.eatOpt()
    try args.finishT()
    return s.split(pattern)
}

let strRev = nativeFunc(
    "rev",
    title: "Reverse",
    since: .version([0, 8, 0]),
    docs: """
        Reverses the string.

        More specifically, this returns a string with the same grapheme \
        clusters, in reversed order.
        """,
    params: [NativeParamInfo(name: "self", input: Str.input, required: true)],
    returns: Str.output
) { _, _, args in
    let s: Str = try args.expectT("self")
    try args.finishT()
    return s.rev()
}

// MARK: - regex

/// Build the scope containing the `regex` constructor.
func regexScope() -> Scope {
    let scope = Scope()
    return scope
}

/// `regex` constructor — port of `Regex::construct`.
let regexConstruct = nativeFunc(
    "regex",
    since: .forever,
    docs: """
        Create a regular expression from a string.

        Both Typst strings and regular expressions use backslashes for \
        escaping. To produce a regex escape sequence that is also valid in \
        Typst, you need to escape the backslash itself.
        """,
    params: [NativeParamInfo(name: "regex", input: Str.input, required: true)],
    returns: Regex.output
) { _, _, args in
    let regex: Spanned<Str, Span> = try args.expectT("regex")
    try args.finishT()
    do {
        return try Regex(regex.value.value)
    } catch {
        throw SourceDiagnostics(SourceDiagnostic.error(regex.span, "\(error)"))
    }
}
