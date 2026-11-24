import Foundation
import TypstSyntax
import TypstUtils

// The `symbol` type's associated scope — port of the `#[scope] impl Symbol`
// block in upstream `foundations/symbol.rs`.

/// A single symbol variant argument to `symbol()`: a modifiers string
/// (dot-separated) plus the variant's single-grapheme value.
/// Port of upstream's `SymbolVariant` cast.
struct SymbolVariant: Sendable, Hashable {
    /// Raw dot-separated modifiers (empty = default variant).
    var modifiers: Str
    /// The variant's value — exactly one grapheme cluster.
    var value: Str
}

extension SymbolVariant: Castable, IntoValue, FromValue {
    static var input: CastInfo { Str.input + ArrayValue.input }
    static var output: CastInfo { input }

    static func castable(_ value: Value) -> Bool {
        switch value {
        case .str, .array: return true
        default: return false
        }
    }

    func intoValue() -> Value {
        if modifiers.value.isEmpty {
            return .str(value)
        }
        return .array(ArrayValue(items: [
            .str(modifiers), .str(value),
        ]))
    }

    static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case .str(let s):
            return .success(SymbolVariant(modifiers: Str(""), value: s))
        case .array(let array):
            guard array.items.count == 2 else {
                return .failure(HintedString(
                    "variant array must contain exactly two entries"))
            }
            let modifiers: Str
            switch Str.fromValue(array.items[0]) {
            case let .success(s): modifiers = s
            case let .failure(e): return .failure(e)
            }
            let variant: Str
            switch Str.fromValue(array.items[1]) {
            case let .success(s): variant = s
            case let .failure(e): return .failure(e)
            }
            return .success(SymbolVariant(modifiers: modifiers, value: variant))
        default:
            return .failure(error(value))
        }
    }
}

/// `symbol(..)` — port of `Symbol::construct`.
let symbolConstruct = nativeFunc(
    "symbol",
    title: "Symbol",
    since: .forever,
    docs: """
        Create a custom symbol with modifiers.

        Can be a just a string consisting of a single character for the \
        modifierless variant or an array with two strings specifying the \
        modifiers and the symbol. Individual modifiers should be separated \
        by dots.
        """,
    params: [
        NativeParamInfo(
            name: "variants",
            input: SymbolVariant.input,
            variadic: true),
    ],
    returns: Symbol.output
) { _, _, args in
    let callSpan = args.span
    let variants: [Spanned<SymbolVariant, Span>] = try args.allT()
    try args.finishT()

    guard !variants.isEmpty else {
        throw bailSpan(callSpan, "expected at least one variant")
    }

    // Dedup key: the sorted modifier set joined unambiguously; the value
    // is the first-seen raw modifier string (upstream compares `v.0`).
    var seen = [String: String]()
    var errors: [SourceDiagnostic] = []

    for v in variants {
        let raw = v.value.modifiers.value
        let text = v.value.value.value

        // The variant value must be exactly one grapheme cluster
        // (`String.count` counts extended grapheme clusters).
        if text.isEmpty || text.count > 1 {
            var diag = SourceDiagnostic.error(
                v.span, "invalid variant value: \(Str(text).repr())")
            diag.hint("variant value must be exactly one grapheme cluster")
            errors.append(diag)
        }

        var modifiers: [String] = []
        var skip = false
        if !raw.isEmpty {
            for modifier in raw.split(separator: ".", omittingEmptySubsequences: false) {
                let m = String(modifier)
                guard isIdent(m) else {
                    errors.append(SourceDiagnostic.error(
                        v.span, "invalid symbol modifier: \(Str(m).repr())"))
                    skip = true
                    break
                }
                modifiers.append(m)
            }
        }
        if skip { continue }

        // Canonicalize the modifier order and reject duplicates.
        modifiers.sort()
        if let dup = zip(modifiers, modifiers.dropFirst())
            .first(where: { $0.0 == $0.1 })?.0 {
            var diag = SourceDiagnostic.error(
                v.span, "duplicate modifier within variant: \(Str(dup).repr())")
            diag.hint("modifiers are not ordered, so each one may appear only once")
            errors.append(diag)
            continue
        }

        let key = modifiers.joined(separator: "\u{1}")
        if let firstRaw = seen[key] {
            if raw.isEmpty {
                errors.append(SourceDiagnostic.error(
                    v.span, "duplicate default variant"))
            } else if raw == firstRaw {
                errors.append(SourceDiagnostic.error(
                    v.span, "duplicate variant: \(Str(raw).repr())"))
            } else {
                var diag = SourceDiagnostic.error(
                    v.span, "duplicate variant: \(Str(raw).repr())")
                diag.hint("variants with the same modifiers are identical, " +
                          "regardless of their order")
                errors.append(diag)
            }
            continue
        }
        seen[key] = raw
    }

    guard errors.isEmpty else {
        throw SourceDiagnostics(errors)
    }

    let list = variants.map {
        (ModifierSet(rawDotted: $0.value.modifiers.value),
         $0.value.value.value, nil as String?)
    }
    return Symbol(variants: list)
}
