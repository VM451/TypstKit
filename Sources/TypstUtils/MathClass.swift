import Foundation

/// Classification of a mathematical character.
/// Port of `unicode_math_class::MathClass`.
public enum MathClass: Sendable, Hashable {
    case normal
    case alphabetic
    case binary
    case closing
    case diacritic
    case fence
    case glyphPart
    case large
    case opening
    case punctuation
    case relation
    case space
    case unary
    case vary
    case special
}

/// Returns the default math class of a character in Typst, if it has one.
/// Port of `typst-utils/src/math.rs::default_math_class`.
public func defaultMathClass(_ c: Unicode.Scalar) -> MathClass? {
    switch c {
    // Better spacing.
    case ":": return .relation

    // Better spacing when used alongside + PLUS SIGN.
    case "⋯", "⋱", "⋰", "⋮": return .normal

    // Better spacing.
    case ".", "/": return .normal

    // ⊥ UP TACK should not be a relation, contrary to ⟂ PERPENDICULAR.
    case "\u{22A5}": return .normal

    // Used as a binary connector in linear logic, where it is referred to
    // as "par".
    case "⅋": return .binary

    // Those overrides should become the default in the next revision of
    // MathClass.txt.
    case "⎰", "⟅": return .opening
    case "⎱", "⟆": return .closing

    // Both ∨ and ⟑ are classified as Binary.
    case "⟇": return .binary

    // Arabic comma.
    case "،": return .punctuation

    default:
        return unicodeMathClass(c)
    }
}

/// Binary search over the generated MathClass-15 table.
private func unicodeMathClass(_ c: Unicode.Scalar) -> MathClass? {
    let entries = MathClassTable.entries
    var lo = 0
    var hi = entries.count
    while lo < hi {
        let mid = (lo + hi) / 2
        let (cp, cls) = entries[mid]
        if cp == c.value { return cls }
        if cp < c.value { lo = mid + 1 } else { hi = mid }
    }
    return nil
}
