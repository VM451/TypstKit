/// A unary operator.
/// Port of `UnOp` in `typst-syntax/src/ast.rs`.
public enum UnOp: Sendable, Hashable {
    /// The plus operator: `+`.
    case pos
    /// The negation operator: `-`.
    case neg
    /// The boolean `not`.
    case not

    /// Try to convert the token into a unary operation.
    public init?(kind: SyntaxKind) {
        switch kind {
        case .plus: self = .pos
        case .minus: self = .neg
        case .not: self = .not
        default: return nil
        }
    }

    /// The precedence of this operator.
    public var precedence: UInt8 {
        switch self {
        case .pos, .neg: return 7
        case .not: return 4
        }
    }

    /// The string representation of this operation.
    public var asStr: String {
        switch self {
        case .pos: return "+"
        case .neg: return "-"
        case .not: return "not"
        }
    }
}

/// A binary operator.
/// Port of `BinOp` in `typst-syntax/src/ast.rs`.
public enum BinOp: Sendable, Hashable {
    /// The addition operator: `+`.
    case add
    /// The subtraction operator: `-`.
    case sub
    /// The multiplication operator: `*`.
    case mul
    /// The division operator: `/`.
    case div
    /// The short-circuiting boolean `and`.
    case and
    /// The short-circuiting boolean `or`.
    case or
    /// The equality operator: `==`.
    case eq
    /// The inequality operator: `!=`.
    case neq
    /// The less-than operator: `<`.
    case lt
    /// The less-than or equal operator: `<=`.
    case leq
    /// The greater-than operator: `>`.
    case gt
    /// The greater-than or equal operator: `>=`.
    case geq
    /// The assignment operator: `=`.
    case assign
    /// The containment operator: `in`.
    case `in`
    /// The inverse containment operator: `not in`.
    case notIn
    /// The add-assign operator: `+=`.
    case addAssign
    /// The subtract-assign operator: `-=`.
    case subAssign
    /// The multiply-assign operator: `*=`.
    case mulAssign
    /// The divide-assign operator: `/=`.
    case divAssign

    /// Try to convert the token into a binary operation.
    public init?(kind: SyntaxKind) {
        switch kind {
        case .plus: self = .add
        case .minus: self = .sub
        case .star: self = .mul
        case .slash: self = .div
        case .and: self = .and
        case .or: self = .or
        case .eqEq: self = .eq
        case .exclEq: self = .neq
        case .lt: self = .lt
        case .ltEq: self = .leq
        case .gt: self = .gt
        case .gtEq: self = .geq
        case .eq: self = .assign
        case .in: self = .in
        case .plusEq: self = .addAssign
        case .hyphEq: self = .subAssign
        case .starEq: self = .mulAssign
        case .slashEq: self = .divAssign
        default: return nil
        }
    }

    /// The precedence of this operator.
    public var precedence: UInt8 {
        switch self {
        case .mul, .div: return 6
        case .add, .sub: return 5
        case .eq, .neq, .lt, .leq, .gt, .geq, .in, .notIn: return 4
        case .and: return 3
        case .or: return 2
        case .assign, .addAssign, .subAssign, .mulAssign, .divAssign: return 1
        }
    }

    /// The associativity of this operator.
    public var assoc: Assoc {
        switch self {
        case .assign, .addAssign, .subAssign, .mulAssign, .divAssign:
            return .right
        default:
            return .left
        }
    }

    /// The string representation of this operation.
    public var asStr: String {
        switch self {
        case .add: return "+"
        case .sub: return "-"
        case .mul: return "*"
        case .div: return "/"
        case .and: return "and"
        case .or: return "or"
        case .eq: return "=="
        case .neq: return "!="
        case .lt: return "<"
        case .leq: return "<="
        case .gt: return ">"
        case .geq: return ">="
        case .in: return "in"
        case .notIn: return "not in"
        case .assign: return "="
        case .addAssign: return "+="
        case .subAssign: return "-="
        case .mulAssign: return "*="
        case .divAssign: return "/="
        }
    }
}

/// The associativity of a binary operator.
public enum Assoc: Sendable, Hashable {
    /// Left-associative: `a + b + c` is equivalent to `(a + b) + c`.
    case left
    /// Right-associative: `a = b = c` is equivalent to `a = (b = c)`.
    case right
}
