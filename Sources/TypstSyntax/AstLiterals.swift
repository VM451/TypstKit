import Foundation

/// An identifier: `it`.
public struct Ident: SingleKindAstNode {
    public static let kind: SyntaxKind = .ident
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the identifier.
    public func get() -> String { node.leafText }

    /// Get the identifier as a string.
    public func asStr() -> String { get() }
}

/// The `none` literal.
public struct NoneExpr: SingleKindAstNode {
    public static let kind: SyntaxKind = .none
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// The `auto` literal.
public struct AutoExpr: SingleKindAstNode {
    public static let kind: SyntaxKind = .auto
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// A boolean: `true`, `false`.
public struct BoolExpr: SingleKindAstNode {
    public static let kind: SyntaxKind = .bool
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the boolean value.
    public func get() -> Bool { node.leafText == "true" }
}

/// An integer: `120`.
public struct IntExpr: SingleKindAstNode {
    public static let kind: SyntaxKind = .int
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the integer value.
    ///
    /// We return a result because we still want to highlight and treat invalid
    /// values like `9223372036854775808` as integers in the IDE.
    ///
    /// The lexer guarantees digits-only text, so sign handling from upstream's
    /// `from_str_radix`/`parse` is not needed; error precedence still mirrors
    /// upstream: the first invalid digit or overflow encountered while
    /// scanning left to right wins.
    public func get() -> Result<Int64, IntLiteralError> {
        let (base, digits) = NonDecimalBase.stripPrefix(node.leafText)
        let radix = base?.radix ?? 10

        if digits.isEmpty {
            // `Empty` maps to the overflow arm upstream.
            return .failure(.posOverflow(base: base, maxPlusOne: false))
        }

        var magnitude: UInt64 = 0
        var overflowed = false
        for scalar in digits.unicodeScalars {
            guard let digit = Self.digitValue(scalar), digit < radix else {
                // Upstream reports the hex base for decimal literals here.
                return .failure(.invalidDigit(base: base ?? .hex, digits: digits))
            }
            let (m, o1) = magnitude.multipliedReportingOverflow(by: UInt64(radix))
            let (a, o2) = m.addingReportingOverflow(UInt64(digit))
            if o1 || o2 {
                overflowed = true
                break
            }
            magnitude = a
            if magnitude > UInt64(Int64.max) {
                overflowed = true
                break
            }
        }

        if overflowed {
            // `max_plus_one`: the full digit string parses as u64 and equals
            // exactly i64::MAX + 1 (2^63).
            var full: UInt64 = 0
            var fullOK = true
            for scalar in digits.unicodeScalars {
                guard let d = Self.digitValue(scalar), d < radix else {
                    fullOK = false
                    break
                }
                let (m, o1) = full.multipliedReportingOverflow(by: UInt64(radix))
                let (a, o2) = m.addingReportingOverflow(UInt64(d))
                if o1 || o2 {
                    fullOK = false
                    break
                }
                full = a
            }
            return .failure(.posOverflow(
                base: base, maxPlusOne: fullOK && full == (UInt64(1) << 63)))
        }

        return .success(Int64(magnitude))
    }

    /// The value of an ASCII hex digit, or `nil`.
    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value - 0x30)
        case 0x41...0x46: return Int(scalar.value - 0x41) + 10
        case 0x61...0x66: return Int(scalar.value - 0x61) + 10
        default: return nil
        }
    }
}

/// Possible errors for integer literals in the AST. Other integer errors are
/// handled in the lexer.
public enum IntLiteralError: Error, Hashable {
    case posOverflow(base: NonDecimalBase?, maxPlusOne: Bool)
    case invalidDigit(base: NonDecimalBase, digits: String)
}

/// Non-decimal bases available for integer syntax: hexadecimal, octal, or
/// binary.
public enum NonDecimalBase: Sendable, Hashable {
    case hex
    case octal
    case binary

    /// The value of the base.
    public var radix: Int {
        switch self {
        case .hex: return 16
        case .octal: return 8
        case .binary: return 2
        }
    }

    /// The name of the non-decimal base.
    public var name: String {
        switch self {
        case .hex: return "hexadecimal"
        case .octal: return "octal"
        case .binary: return "binary"
        }
    }

    /// Try to strip a base prefix (`0x`, `0o`, `0b`) from the integer literal
    /// and return the base and the remaining digits.
    static func stripPrefix(_ text: String) -> (NonDecimalBase?, String) {
        if text.hasPrefix("0x") {
            return (.hex, String(text.dropFirst(2)))
        } else if text.hasPrefix("0o") {
            return (.octal, String(text.dropFirst(2)))
        } else if text.hasPrefix("0b") {
            return (.binary, String(text.dropFirst(2)))
        }
        return (nil, text)
    }
}

/// A floating-point number: `1.2`, `10e-4`.
public struct FloatExpr: SingleKindAstNode {
    public static let kind: SyntaxKind = .float
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the floating-point value.
    public func get() -> Double {
        Double(node.leafText) ?? 0
    }
}

/// A numeric value with a unit: `12pt`, `3cm`, `2em`, `90deg`, `50%`.
public struct Numeric: SingleKindAstNode {
    public static let kind: SyntaxKind = .numeric
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the numeric value and unit.
    public func get() -> (Double, NumericUnit) {
        let text = node.leafText
        // Upstream counts trailing ASCII `a-z`/`%` chars as the unit.
        let suffixCount = text.unicodeScalars.reversed()
            .prefix { scalar in
                (0x61...0x7A).contains(scalar.value) || scalar == "%"
            }
            .count

        let scalars = Array(text.unicodeScalars)
        let split = scalars.count - suffixCount
        let valueText = String(String.UnicodeScalarView(scalars[..<split]))
        let unitText = String(String.UnicodeScalarView(scalars[split...]))

        let value = Double(valueText) ?? 0
        let unit: NumericUnit
        switch unitText {
        case "pt": unit = .pt
        case "mm": unit = .mm
        case "cm": unit = .cm
        case "in": unit = .in_
        case "deg": unit = .deg
        case "rad": unit = .rad
        case "em": unit = .em
        case "fr": unit = .fr
        case "%": unit = .percent
        default: unit = .percent
        }
        return (value, unit)
    }
}

/// Unit of a numeric value.
public enum NumericUnit: Sendable, Hashable {
    /// Points.
    case pt
    /// Millimeters.
    case mm
    /// Centimeters.
    case cm
    /// Inches.
    case in_
    /// Radians.
    case rad
    /// Degrees.
    case deg
    /// Font-relative: `1em` is the same as the font size.
    case em
    /// Fractions: `fr`.
    case fr
    /// Percentage: `%`.
    case percent
}

/// A quoted string: `"..."`.
public struct Str: SingleKindAstNode {
    public static let kind: SyntaxKind = .str
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the string value with resolved escape sequences.
    public func get() -> String {
        let text = node.leafText
        let inner = String(text.dropFirst().dropLast())
        return unescapeTypstString(inner)
    }
}

/// A code block: `{ let x = 1; x + 2 }`.
public struct CodeBlock: SingleKindAstNode {
    public static let kind: SyntaxKind = .codeBlock
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contained code.
    public func body() -> Code { node.castFirst() }
}

/// The body of a code block.
public struct Code: SingleKindAstNode {
    public static let kind: SyntaxKind = .code
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The list of expressions contained in the code.
    public func exprs() -> [Expr] {
        node.children.compactMap { $0.cast(Expr.self) }
    }
}

/// A content block: `[*Hi* there!]`.
public struct ContentBlock: SingleKindAstNode {
    public static let kind: SyntaxKind = .contentBlock
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contained markup.
    public func body() -> Markup { node.castFirst() }
}

/// A grouped expression: `(1 + 2)`.
public struct Parenthesized: SingleKindAstNode {
    public static let kind: SyntaxKind = .parenthesized
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The wrapped expression.
    ///
    /// Should only be accessed if this is contained in an `Expr`.
    public func expr() -> Expr { node.castFirst() }

    /// The wrapped pattern.
    ///
    /// Should only be accessed if this is contained in a `Pattern`.
    public func pattern() -> Pattern { node.castFirst() }
}
