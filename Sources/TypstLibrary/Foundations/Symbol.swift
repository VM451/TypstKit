import Foundation
import TypstSyntax

/// A set of dot-separated symbol modifiers.
///
/// Port of `codex::ModifierSet`. The ordering of modifiers matters for
/// equality/hashing (unlike a true set).
public struct ModifierSet: Sendable, Hashable {
    /// The modifiers joined with `.` (empty string = empty set).
    var raw: String

    public init() { raw = "" }

    /// Creates a modifier set from a dot-separated string.
    public init(rawDotted s: String) {
        assert(!s.contains(".."), "ModifierSet::from_raw_dotted called with empty modifier")
        raw = s
    }

    public var isEmpty: Bool { raw.isEmpty }
    public var asStr: String { raw }

    /// The individual modifiers.
    public var modifiers: [String] {
        raw.isEmpty ? [] : raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    public mutating func insertRaw(_ m: String) {
        if !raw.isEmpty { raw += "." }
        raw += m
    }

    public func contains(_ m: String) -> Bool {
        modifiers.contains(m)
    }

    public func isSubset(of other: ModifierSet) -> Bool {
        modifiers.allSatisfy { other.contains($0) }
    }

    /// Finds the best match: variants that are supersets of `self`,
    /// scored by (more shared modifiers, fewer total modifiers),
    /// first wins on ties.
    public func bestMatch<T>(in variants: [(ModifierSet, T)]) -> T? {
        var best: T?
        var bestScore: (Int, Int)?
        for (set, value) in variants where isSubset(of: set) {
            var matching = 0
            var total = 0
            for modifier in set.modifiers {
                if contains(modifier) { matching += 1 }
                total += 1
            }
            let score = (matching, -total)
            if bestScore == nil || score > bestScore! {
                best = value
                bestScore = score
            }
        }
        return best
    }
}

/// A named symbol with selectable variants.
///
/// Port of `Symbol` in `symbol.rs`. Static symbol tables from the `codex`
/// crate are ported separately; this type supports both single-value and
/// variant-list symbols.
public struct Symbol: Sendable, Hashable {
    /// A single symbol variant (boxed: tuples are not `Hashable`).
    struct Variant: Sendable, Hashable {
        var modifiers: ModifierSet
        var value: String
        var description: String?
    }

    enum Inner: Sendable, Hashable {
        case single(String)
        case variants([Variant])
    }

    var inner: Inner

    /// A symbol with a single fixed value.
    public init(single value: String) { inner = .single(value) }

    /// A symbol with named variants: `(modifiers, value, description)`.
    public init(variants: [(ModifierSet, String, String?)]) {
        inner = .variants(variants.map {
            Variant(modifiers: $0.0, value: $0.1, description: $0.2)
        })
    }

    /// A runtime symbol from a single grapheme.
    public static func runtimeChar(_ c: Character) -> Symbol {
        Symbol(single: String(c))
    }

    /// The symbol's resolved string value.
    public var get: String {
        switch inner {
        case let .single(value): return value
        case let .variants(list):
            return ModifierSet().bestMatch(in: list.map { ($0.modifiers, $0.value) }) ?? ""
        }
    }

    /// Apply a modifier, returning a new symbol or an error.
    public func modified(_ modifier: String, guard access: any BindingGuard) -> HintedStrResult<Symbol> {
        // Check the modifier is known.
        guard availableModifiers.contains(modifier) else {
            return .failure(HintedString("unknown symbol modifier: \(modifier.typstRepr)"))
        }
        var set = ModifierSet()
        set.insertRaw(modifier)
        // Resolve best match against the modifier set.
        switch inner {
        case .single:
            return .success(self)
        case let .variants(list):
            guard let value = set.bestMatch(in: list.map {
                ($0.modifiers, $0.value)
            }) else {
                return .failure(HintedString("no variant of symbol matches modifier \(modifier.typstRepr)"))
            }
            return .success(Symbol(single: value))
        }
    }

    /// All modifiers available across variants (excluding already-applied).
    public var availableModifiers: Set<String> {
        switch inner {
        case .single: return []
        case let .variants(list):
            var result = Set<String>()
            for variant in list {
                for m in variant.modifiers.modifiers { result.insert(m) }
            }
            return result
        }
    }

    /// All variants with their modifiers, values, and descriptions.
    public var variants: [(ModifierSet, String, String?)] {
        switch inner {
        case .single: return [(ModifierSet(), get, nil)]
        case let .variants(list):
            return list.map { ($0.modifiers, $0.value, $0.description) }
        }
    }
}

extension Symbol: CustomDebugStringConvertible {
    public var debugDescription: String { "Symbol(\(get.typstRepr))" }
}

extension Symbol: Repr {
    public func repr() -> String { get.typstRepr }
}
