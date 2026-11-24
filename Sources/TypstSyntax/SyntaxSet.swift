/// A set of syntax kinds, backed by a 128-bit mask.
/// Port of `typst-syntax/src/set.rs` (rust-analyzer `TokenSet` design).
struct SyntaxSet: Sendable, Hashable {
    private var lo: UInt64 = 0
    private var hi: UInt64 = 0

    init() {}

    init(_ kinds: SyntaxKind...) {
        for kind in kinds { self = self.adding(kind) }
    }

    func adding(_ kind: SyntaxKind) -> SyntaxSet {
        var copy = self
        let bit = UInt64(1) << UInt64(kind.rawValue & 63)
        if kind.rawValue < 64 {
            copy.lo |= bit
        } else {
            copy.hi |= bit
        }
        return copy
    }

    func removing(_ kind: SyntaxKind) -> SyntaxSet {
        var copy = self
        let bit = ~(UInt64(1) << UInt64(kind.rawValue & 63))
        if kind.rawValue < 64 {
            copy.lo &= bit
        } else {
            copy.hi &= bit
        }
        return copy
    }

    func union(_ other: SyntaxSet) -> SyntaxSet {
        SyntaxSet(lo: lo | other.lo, hi: hi | other.hi)
    }

    func contains(_ kind: SyntaxKind) -> Bool {
        let bit = UInt64(1) << UInt64(kind.rawValue & 63)
        return kind.rawValue < 64 ? (lo & bit) != 0 : (hi & bit) != 0
    }

    private init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
    }
}

extension SyntaxSet {
    /// Syntax kinds that can start a statement.
    static let stmt = SyntaxSet(.let, .set, .show, .import, .include, .return)

    /// Syntax kinds that can start a math expression.
    static let mathExpr = SyntaxSet(
        .hash, .mathIdent, .mathFieldAccess, .comma, .semicolon,
        .leftParen, .rightParen, .mathOpening, .mathClosing,
        .mathLetter, .mathSymbol, .mathNumber, .mathShorthand,
        .linebreak, .mathAlignPoint, .mathPrimes, .escape, .str,
        .root, .bang
    )

    /// Syntax kinds that can start a code expression.
    static let codeExpr = Self.atomicCodeExpr
        .union(.unaryOp)
        .adding(.underscore)

    /// Syntax kinds that can start an atomic code expression.
    static let atomicCodeExpr = SyntaxSet(
        .ident, .leftBrace, .leftBracket, .leftParen, .dollar,
        .let, .set, .show, .context, .if, .while, .for, .import,
        .include, .break, .continue, .return, .none, .auto, .int,
        .float, .bool, .numeric, .str, .label, .raw
    )

    /// Syntax kinds that are unary operators.
    static let unaryOp = SyntaxSet(.plus, .minus, .not)

    /// Syntax kinds that are binary operators.
    static let binaryOp = SyntaxSet(
        .plus, .minus, .star, .slash, .and, .or, .eqEq, .exclEq,
        .lt, .ltEq, .gt, .gtEq, .eq, .in, .plusEq, .hyphEq, .starEq,
        .slashEq
    )

    /// Syntax kinds that can start an argument in an array or dictionary.
    static let arrayOrDictItem = Self.codeExpr.adding(.dots)

    /// Syntax kinds that can start an argument in a function call.
    static let arg = Self.codeExpr.adding(.dots)

    /// Syntax kinds that can start a parameter in a parameter list.
    static let param = Self.pattern.adding(.dots)

    /// Syntax kinds that can start a destructuring item.
    static let destructuringItem = Self.pattern.adding(.dots)

    /// Syntax kinds that can start a pattern.
    static let pattern = Self.patternLeaf
        .adding(.leftParen)
        .adding(.underscore)

    /// Syntax kinds that can start a pattern leaf.
    static let patternLeaf = Self.atomicCodeExpr
}
