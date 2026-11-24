import Foundation

/// The contents of a mathematical equation: `x^2 + 1`.
public struct Math: SingleKindAstNode {
    public static let kind: SyntaxKind = .math
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The expressions the mathematical content consists of.
    public func exprs() -> [Expr] {
        node.children.compactMap { Expr.castWithSpace($0) }
    }

    /// Whether this `Math` node was originally parenthesized.
    public func wasDeparenthesized() -> Bool {
        let children = node.children
        guard children.count >= 2 else { return false }
        return children.first?.kind == .leftParen
            && children.last?.kind == .rightParen
    }
}

/// A single letter in math, may be exactly one grapheme cluster: `x`, `π`,
/// `ℱ`, `ℱ︀`.
public struct MathLetter: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathLetter
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Return the underlying text.
    public func get() -> String { node.leafText }
}

/// A non-letter symbol in math, may be exactly one grapheme cluster: `+`,
/// `=`, `∅`, `∅︀`, `🏳️‍🌈`.
public struct MathSymbol: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathSymbol
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Return the underlying text.
    public func get() -> String { node.leafText }
}

/// A number in math: `25`, `2.718`.
public struct MathNumber: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathNumber
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Return the underlying text.
    public func get() -> String { node.leafText }
}

/// An identifier in math: `pi`.
public struct MathIdent: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathIdent
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the identifier.
    public func get() -> String { node.leafText }

    /// Get the identifier as a string.
    public func asStr() -> String { get() }
}

/// A field access in math: `arrow.r.long.double.bar`.
public struct MathFieldAccess: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathFieldAccess
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The expression to access the field on.
    public func target() -> MathAccess { node.castFirst() }

    /// The name of the field.
    public func field() -> MathIdent { node.castLast() }
}

/// A variable or field access in math.
public enum MathAccess: AstNode {
    case mathIdent(MathIdent)
    case mathFieldAccess(MathFieldAccess)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .mathIdent: self = .mathIdent(MathIdent(unchecked: node))
        case .mathFieldAccess: self = .mathFieldAccess(MathFieldAccess(unchecked: node))
        default: return nil
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .mathIdent(let n): return n.node
        case .mathFieldAccess(let n): return n.node
        }
    }

    public static var placeholder: MathAccess {
        .mathIdent(MathIdent.placeholder)
    }
}

/// A shorthand for a unicode codepoint in math: `a <= b`.
public struct MathShorthand: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathShorthand
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// A list of all shorthands in math mode.
    public static let list: [(String, Unicode.Scalar)] = [
        ("...", "…"),
        ("-", "−"),
        ("*", "∗"),
        ("~", "∼"),
        ("!=", "≠"),
        (":=", "≔"),
        ("::=", "⩴"),
        ("=:", "≕"),
        ("<<", "≪"),
        ("<<<", "⋘"),
        (">>", "≫"),
        (">>>", "⋙"),
        ("<=", "≤"),
        (">=", "≥"),
        ("->", "→"),
        ("-->", "⟶"),
        ("|->", "↦"),
        (">->", "↣"),
        ("->>", "↠"),
        ("<-", "←"),
        ("<--", "⟵"),
        ("<-<", "↢"),
        ("<<-", "↞"),
        ("<->", "↔"),
        ("<-->", "⟷"),
        ("~>", "⇝"),
        ("~~>", "⟿"),
        ("<~", "⇜"),
        ("<~~", "⬳"),
        ("=>", "⇒"),
        ("|=>", "⤇"),
        ("==>", "⟹"),
        ("<==", "⟸"),
        ("<=>", "⇔"),
        ("<==>", "⟺"),
        ("[|", "⟦"),
        ("|]", "⟧"),
        ("||", "‖"),
    ]

    /// Get the shorthanded character.
    public func get() -> Unicode.Scalar {
        let text = node.leafText
        for (s, c) in Self.list where s == text { return c }
        return Unicode.Scalar(0)!
    }
}

/// A function call in math: `mat(delim: "[", a, b; ..#($c$,), d)`.
public struct MathCall: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathCall
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The function to call. If not actually a function, will be rendered as
    /// content next to its arguments.
    public func callee() -> MathAccess { node.castFirst() }

    /// The arguments to the function.
    public func args() -> MathArgs { node.castLast() }
}

/// Function arguments in math: `(delim: "[", a, b; ..#($c$,), d)`.
public struct MathArgs: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathArgs
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Arguments for actual function calls in math.
    public func argItems() -> [MathArg] {
        let items = contentItems()
        var result: [MathArg] = []
        var i = 0
        while i < items.count {
            // Advance to the next argument (upstream `find_map`).
            var found: Arg? = nil
            while i < items.count {
                if case .arg(let a) = items[i] {
                    found = a
                    i += 1
                    break
                }
                i += 1
            }
            guard let arg = found else { break }

            // Peek ahead: a semicolon before the next argument or the end
            // marks this argument as two-dimensional. Non-matching items are
            // consumed; `.arg` and `.semicolon` are only peeked at.
            var endsInSemicolon = false
            scan: while i < items.count {
                switch items[i] {
                case .arg:
                    break scan
                case .semicolon:
                    endsInSemicolon = true
                    break scan
                default:
                    i += 1
                }
            }
            result.append(MathArg(arg: arg, endsInSemicolon: endsInSemicolon))
        }
        return result
    }

    /// Items at the top-level of the argument list that will be rendered into
    /// content if unparsing for a non-function.
    public func contentItems() -> [MathArgItem] {
        var result: [MathArgItem] = []
        var prevHash = false
        for child in node.children {
            if let arg = child.cast(Arg.self) {
                result.append(.arg(arg))
                continue
            }
            let semicolonEndsCode = prevHash
            prevHash = false
            switch child.kind {
            case .spaceNoNewline, .spaceWithNewline:
                result.append(.space(Space(unchecked: child)))
            case .comma:
                result.append(.comma(",", child))
            case .leftParen:
                result.append(.leftParen("(", child))
            case .rightParen:
                result.append(.rightParen(")", child))
            case .semicolon where !semicolonEndsCode:
                result.append(.semicolon(";", child))
            case .hash:
                prevHash = true
            default:
                continue
            }
        }
        return result
    }
}

/// An argument in a [`MathCall`] for an actual function and whether it ends in
/// a semicolon.
public struct MathArg {
    /// The argument.
    public var arg: Arg
    /// Whether the argument ends with a semicolon and should create
    /// two-dimensional args. This excludes semicolons that end embedded code
    /// expressions.
    public var endsInSemicolon: Bool

    public init(arg: Arg, endsInSemicolon: Bool) {
        self.arg = arg
        self.endsInSemicolon = endsInSemicolon
    }
}

/// Items at the top-level of a [`MathArgs`] argument list that will be
/// rendered into content if unparsing for a non-function.
///
/// This enum does not conform to [`AstNode`] because the `semicolon` variant
/// requires extra context to convert correctly making it a likely footgun.
public enum MathArgItem {
    /// A normal argument.
    case arg(Arg)
    /// A space between arguments and other punctuation.
    case space(Space)
    /// A comma separating arguments.
    case comma(Unicode.Scalar, SyntaxNode)
    /// A semicolon separating arguments. This excludes semicolons that end
    /// embedded code expressions.
    case semicolon(Unicode.Scalar, SyntaxNode)
    /// The left paren at the start of the arguments.
    case leftParen(Unicode.Scalar, SyntaxNode)
    /// The right paren at the end of the arguments.
    case rightParen(Unicode.Scalar, SyntaxNode)
}

/// An alignment point in math: `&`.
public struct MathAlignPoint: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathAlignPoint
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// An opening delimiter in math: `(`, `{`.
///
/// Also wraps the opening double square bracket shorthand: `[|`.
public struct MathOpening: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathOpening
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the opening delimiter character. May be computed from an inner
    /// [`MathShorthand`] if this is not a leaf node.
    public func get() -> Unicode.Scalar {
        if let first = node.leafText.unicodeScalars.first {
            return first
        }
        return node.castFirst(MathShorthand.self).get()
    }
}

/// A closing delimiter in math: `)`, `}`.
///
/// Also wraps the closing double square bracket shorthand: `|]`.
public struct MathClosing: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathClosing
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the closing delimiter character. May be computed from an inner
    /// [`MathShorthand`] if this is not a leaf node.
    public func get() -> Unicode.Scalar {
        if let first = node.leafText.unicodeScalars.first {
            return first
        }
        return node.castFirst(MathShorthand.self).get()
    }
}

/// Matched delimiters in math: `[x + y]`.
public struct MathDelimited: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathDelimited
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The opening delimiter.
    public func open() -> MathOpening { node.castFirst() }

    /// The contents, including the delimiters.
    public func body() -> Math { node.castFirst() }

    /// The closing delimiter.
    public func close() -> MathClosing { node.castLast() }
}

/// A base with optional attachments in math: `a_1^2`.
public struct MathAttach: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathAttach
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The base, to which things are attached.
    public func base() -> Expr { node.castFirst() }

    /// The bottom attachment.
    public func bottom() -> Expr? {
        var pastUnderscore = false
        for child in node.children {
            if child.kind == .underscore {
                pastUnderscore = true
            } else if pastUnderscore, let expr = child.cast(Expr.self) {
                return expr
            }
        }
        return nil
    }

    /// The top attachment.
    public func top() -> Expr? {
        var pastHat = false
        for child in node.children {
            if child.kind == .hat {
                pastHat = true
            } else if pastHat, let expr = child.cast(Expr.self) {
                return expr
            }
        }
        return nil
    }

    /// Extract attached primes if present.
    public func primes() -> MathPrimes? {
        guard let baseIndex = node.children.firstIndex(where: { $0.is(Expr.self) }),
              baseIndex + 1 < node.children.count
        else { return nil }
        return node.children[baseIndex + 1].cast(MathPrimes.self)
    }
}

/// Grouped primes in math: `a'''`.
public struct MathPrimes: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathPrimes
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The number of grouped primes.
    public func count() -> Int {
        // We can use byte length since single quotes are one byte.
        node.leafText.utf8.count
    }
}

/// A fraction in math: `x/2`.
public struct MathFrac: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathFrac
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The numerator.
    public func num() -> Expr { node.castFirst() }

    /// The denominator.
    public func denom() -> Expr { node.castLast() }
}

/// A root in math: `√x`, `∛x` or `∜x`.
public struct MathRoot: SingleKindAstNode {
    public static let kind: SyntaxKind = .mathRoot
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The index of the root.
    public func index() -> UInt8? {
        guard let text = node.children.first?.leafText else { return nil }
        switch text {
        case "∜": return 4
        case "∛": return 3
        default: return nil
        }
    }

    /// The radicand.
    public func radicand() -> Expr { node.castFirst() }
}
