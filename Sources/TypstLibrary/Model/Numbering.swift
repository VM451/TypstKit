import Foundation
import TypstSyntax
import TypstUtils

// Numbering from upstream `model/numbering.rs`. Depends on the codex port
// in `Foundations/NumeralSystems.swift`.

/// Applies a numbering to a sequence of numbers.
///
/// Port of `numbering` (`#[func]`) and the `Numbering`/`NumberingPattern`
/// types in `model/numbering.rs`.
public enum Numbering: Sendable, Hashable {
    /// A pattern with prefix, numbering, lower/upper case and suffix.
    case pattern(NumberingPattern)
    /// A closure mapping from an item's number to content.
    case function(Func)

    /// Apply the numbering to the given numbers.
    /// Port of `Numbering::apply`.
    public func apply(engine: inout Engine, context: Context, span: Span,
                      numbers: [UInt64]) -> SourceResult<Value> {
        switch self {
        case let .pattern(pattern):
            return pattern.applyWithFallback(engine: &engine, span: span,
                                             numbers: numbers)
                .map { .str(Str($0)) }
                .mapError { SourceDiagnostics(
                    SourceDiagnostic.error(span, $0.message)) }
        case let .function(f):
            let args = Args(span: span,
                            values: numbers.map { u64Value($0) })
            return f.callValue(engine: &engine, context: context,
                                  args: args, span: span)
        }
    }

    /// Trim the prefix suffix if this is a pattern.
    /// Port of `Numbering::trimmed`.
    public func trimmed() -> Numbering {
        switch self {
        case var .pattern(pattern):
            pattern.trimmed = true
            return .pattern(pattern)
        case .function:
            return self
        }
    }
}

/// u64 → Value like upstream's `unsigned_int!` cast: `Int` when it fits,
/// `Float` otherwise.
private func u64Value(_ n: UInt64) -> Value {
    if let i = Int64(exactly: n) { return .int(i) }
    return .float(Double(n))
}

extension Numbering: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([NumberingPattern.input, .type(Type.of(Func.self))])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        NumberingPattern.castable(value) || Func.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .pattern(p): return p.intoValue()
        case let .function(f): return f.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if let p = try? NumberingPattern.fromValue(value).get() {
            return .success(.pattern(p))
        }
        return Func.fromValue(value).map { .function($0) }
    }
}

/// How to turn a number into text.
///
/// A pattern consists of a prefix, followed by one of the counter symbols,
/// and then a suffix. Port of `NumberingPattern` in `model/numbering.rs`.
public struct NumberingPattern: Sendable {
    /// `(prefix, numeral system)` pairs, one per counting symbol.
    public var pieces: [(prefix: String, system: NamedNumeralSystem)]
    /// Everything after the last counting symbol.
    public var suffix: String
    /// Whether to skip the first prefix and the suffix (internal `trimmed`).
    public var trimmed: Bool

    public init(pieces: [(prefix: String, system: NamedNumeralSystem)],
                suffix: String, trimmed: Bool = false) {
        self.pieces = pieces
        self.suffix = suffix
        self.trimmed = trimmed
    }

    /// Parse a numbering pattern from a string.
    /// Port of `FromStr for NumberingPattern`.
    public init(parsing pattern: String) throws {
        var pieces: [(prefix: String, system: NamedNumeralSystem)] = []
        var handled = pattern.startIndex
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let c = pattern[i]
            let next = pattern.index(after: i)
            if let system = NamedNumeralSystem.fromShorthand(String(c)) {
                pieces.append((String(pattern[handled..<i]), system))
                handled = next
            }
            i = next
        }

        guard !pieces.isEmpty else {
            throw HintedString("invalid numbering pattern")
        }

        self.init(pieces: pieces,
                  suffix: String(pattern[handled...]),
                  trimmed: false)
    }

    /// Apply the pattern to the given numbers.
    ///
    /// Port of `NumberingPattern::apply` — without a warning context this is
    /// the pure path; errors are returned.
    public func apply(numbers: [UInt64]) -> HintedStrResult<String> {
        applyWith(numbers: numbers) { system, n -> HintedStrResult<String> in
            switch system.represent(n) {
            case let .success(s): return .success(s)
            case let .failure(e): return .failure(applySystemError(system, n, e))
            }
        }
    }

    /// Apply the pattern, emitting a warning and falling back to Arabic
    /// numerals on representation errors.
    /// Port of `NumberingPattern::apply` with `warning_context = Some(..)`.
    public func applyWithFallback(engine: inout Engine, span: Span,
                                  numbers: [UInt64]) -> HintedStrResult<String> {
        applyWith(numbers: numbers) { system, n -> HintedStrResult<String> in
            switch system.represent(n) {
            case let .success(s):
                return .success(s)
            case let .failure(e):
                var diagnostic = SourceDiagnostic.warning(
                    span, applySystemError(system, n, e).message)
                diagnostic.hint("this will become a hard error in the future")
                engine.sink.warn(diagnostic)
                switch NamedNumeralSystem.arabic.represent(n) {
                case let .success(s): return .success(s)
                case .failure:
                    preconditionFailure("`arabic` should be able to represent \(n)")
                }
            }
        }
    }

    /// Auxiliary method for `apply`. Port of `apply_with`.
    private func applyWith<D: StringProtocol>(
        numbers: [UInt64],
        applySystem: (NamedNumeralSystem, UInt64) -> HintedStrResult<D>
    ) -> HintedStrResult<String> {
        var fmt = ""
        var iter = numbers.makeIterator()
        var index = 0

        for (prefix, system) in pieces {
            guard let n = iter.next() else { break }
            if index > 0 || !trimmed {
                fmt += prefix
            }
            switch applySystem(system, n) {
            case let .success(d): fmt += String(d)
            case let .failure(e): return .failure(e)
            }
            index += 1
        }

        // Remaining numbers repeat the last piece with its prefix
        // (`pieces.last().into_iter().cycle()`).
        if let last = pieces.last {
            while let n = iter.next() {
                if last.prefix.isEmpty {
                    fmt += suffix
                } else {
                    fmt += last.prefix
                }
                switch applySystem(last.system, n) {
                case let .success(d): fmt += String(d)
                case let .failure(e): return .failure(e)
                }
            }
        }

        if !trimmed {
            fmt += suffix
        }
        return .success(fmt)
    }

    /// Apply only the k-th segment of the pattern to a number.
    /// Port of `apply_kth` — `pieces.iter().chain(last.cycle()).nth(k)`.
    public func applyKth(engine: inout Engine, span: Span, k: Int,
                         number: UInt64) -> String {
        var fmt = ""
        if let first = pieces.first {
            fmt += first.prefix
        }
        guard let system = k < pieces.count
            ? pieces[k].system
            : pieces.last?.system else {
            return fmt + suffix
        }
        switch system.represent(number) {
        case let .success(s):
            fmt += s
        case let .failure(e):
            var diagnostic = SourceDiagnostic.warning(
                span, applySystemError(system, number, e).message)
            diagnostic.hint("this will become a hard error in the future")
            engine.sink.warn(diagnostic)
            if case let .success(s) = NamedNumeralSystem.arabic.represent(number) {
                fmt += s
            }
        }
        return fmt + suffix
    }

    /// How many counting symbols this pattern has.
    public var pieceCount: Int { pieces.count }
}

extension NumberingPattern: Equatable {
    public static func == (lhs: NumberingPattern, rhs: NumberingPattern) -> Bool {
        lhs.suffix == rhs.suffix && lhs.trimmed == rhs.trimmed
            && lhs.pieces.count == rhs.pieces.count
            && zip(lhs.pieces, rhs.pieces).allSatisfy {
                $0.prefix == $1.prefix && $0.system == $1.system
            }
    }
}

extension NumberingPattern: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(suffix)
        hasher.combine(trimmed)
        hasher.combine(pieces.count)
        for (prefix, system) in pieces {
            hasher.combine(prefix)
            hasher.combine(system)
        }
    }
}

/// Error message for `apply_system` failures.
private func applySystemError(_ system: NamedNumeralSystem, _ number: UInt64,
                              _ error: RepresentationError) -> HintedString {
    switch error {
    case .zero:
        return HintedString(
            "the numeral system `\(system.name)` cannot represent zero")
    case .tooLarge:
        return HintedString(
            "the number \(number) is too large to be represented with the `\(system.name)` numeral system")
    }
}

extension NumberingPattern: CustomStringConvertible {
    /// Reconstruct the pattern string (the `into_value` cast).
    public var description: String {
        var pat = ""
        for (prefix, system) in pieces {
            pat += prefix
            if let shorthand = system.shorthand {
                pat += shorthand
            }
        }
        return pat + suffix
    }
}

extension NumberingPattern: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return (try? NumberingPattern(parsing: s.value)) != nil
    }
    public func intoValue() -> Value { .str(Str(description)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value else { return .failure(error(value)) }
        do {
            return .success(try NumberingPattern(parsing: s.value))
        } catch let error as HintedString {
            return .failure(error)
        } catch {
            return .failure(HintedString("invalid numbering pattern"))
        }
    }
}

// MARK: - numbering() function

/// `numbering(..)` — port of the `#[func] numbering` in `model/numbering.rs`.
let numberingFunc = nativeFunc(
    "numbering",
    title: "Numbering",
    docs: """
        Applies a numbering to a sequence of numbers.

        A numbering defines how a sequence of numbers should be displayed as
        content. It is defined either through a pattern string or an arbitrary
        function.

        A numbering pattern consists of counting symbols, for which the actual
        number is substituted, their prefixes, and one suffix. The prefixes
        and the suffix are displayed as-is.
        """,
    params: [
        NativeParamInfo(
            name: "numbering",
            docs: """
                Defines how the numbering works.

                *Counting symbols* are `1`, `a`, `A`, `i`, `I`, `α`, `Α`, `一`,
                `壹`, `あ`, `い`, `ア`, `イ`, `א`, `가`, `ㄱ`, `*`, `١`, `۱`,
                `१`, `১`, `ক`, `①`, and `⓵`. They are replaced by the number
                in the sequence, preserving the original case.

                The `*` character means that symbols should be used to count,
                in the order of `*`, `†`, `‡`, `§`, `¶`, `‖`. If there are
                more than six items, the number is represented using repeated
                symbols.

                *Suffixes* are all characters after the last counting symbol.
                They are displayed as-is at the end of any rendered number.

                *Prefixes* are all characters that are neither counting
                symbols nor suffixes. They are displayed as-is at in front of
                their rendered equivalent of their counting symbol.
                """,
            input: Numbering.input),
        NativeParamInfo(
            name: "numbers",
            docs: """
                The numbers to apply the numbering to. Must be non-negative.

                In general, numbers are counted from one. A number of zero
                indicates that the first element has not yet appeared.

                If `numbering` is a pattern and more numbers than counting
                symbols are given, the last counting symbol with its prefix
                is repeated.
                """,
            input: .type(Type.of(Int64.self)),
            variadic: true),
    ],
    returns: .any
) { engine, context, args in
    let numbering: Numbering = try args.expectT("numbering")
    let numbers: [UInt64] = try args.allT()
    return try unwrap(numbering.apply(engine: &engine, context: context,
                                     span: args.span, numbers: numbers))
}
