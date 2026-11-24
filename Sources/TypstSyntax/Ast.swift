import Foundation

/// A typed AST node: a lazy, typed view over the untyped [`SyntaxNode`] CST.
///
/// Port of the `AstNode` trait and `node!` macro in
/// `typst-syntax/src/ast.rs`. Most nodes are thin wrappers around a
/// `SyntaxNode`; the only way to obtain one is the failable `init(node:)`,
/// which checks the node's kind first.
///
/// Differences from upstream:
/// - No lifetimes: `SyntaxNode` is a class, so wrappers hold a strong
///   reference instead of `&'a SyntaxNode`.
/// - Iterators are returned as `[T]` arrays (eager but semantically
///   identical — AST accessors have no side effects).
/// - Types colliding with Swift stdlib/Foundation names are suffixed:
///   `ArrayExpr`, `IntExpr`, `FloatExpr`, `BoolExpr`, `NumericUnit`.
public protocol AstNode {
    /// Attempt to view `node` as this AST type, checking its kind.
    init?(node: SyntaxNode)

    /// The underlying syntax node.
    var node: SyntaxNode { get }

    /// A placeholder node of this type, used when the CST is malformed.
    static var placeholder: Self { get }

    /// The source code location.
    var span: Span { get }
}

/// An [`AstNode`] that wraps exactly one [`SyntaxKind`].
public protocol SingleKindAstNode: AstNode {
    /// The syntax kind this node wraps.
    static var kind: SyntaxKind { get }

    /// Wrap the node without checking its kind.
    init(unchecked node: SyntaxNode)
}

public extension SingleKindAstNode {
    init?(node: SyntaxNode) {
        guard node.kind == Self.kind else { return nil }
        self.init(unchecked: node)
    }

    static var placeholder: Self {
        Self(unchecked: .placeholder(Self.kind))
    }
}

public extension AstNode {
    /// Convert a node into its typed variant (upstream `from_untyped`).
    static func fromUntyped(_ node: SyntaxNode) -> Self? {
        Self(node: node)
    }

    /// The source code location (upstream `span()`).
    var span: Span { node.span }
}

extension SyntaxNode {
    /// Whether the node can be cast to the given AST node type.
    public func `is`<T: AstNode>(_ type: T.Type = T.self) -> Bool {
        cast(type) != nil
    }

    /// Try to view this node as typed AST node `T`.
    public func cast<T: AstNode>(_ type: T.Type = T.self) -> T? {
        T(node: self)
    }

    /// Find the first child that can cast to the AST type `T`.
    func tryCastFirst<T: AstNode>(_ type: T.Type = T.self) -> T? {
        children.lazy.compactMap { $0.cast(type) }.first
    }

    /// Find the last child that can cast to the AST type `T`.
    func tryCastLast<T: AstNode>(_ type: T.Type = T.self) -> T? {
        children.reversed().lazy.compactMap { $0.cast(type) }.first
    }

    /// Get the first child of AST type `T` or a placeholder if none.
    func castFirst<T: AstNode>(_ type: T.Type = T.self) -> T {
        tryCastFirst(type) ?? T.placeholder
    }

    /// Get the last child of AST type `T` or a placeholder if none.
    func castLast<T: AstNode>(_ type: T.Type = T.self) -> T {
        tryCastLast(type) ?? T.placeholder
    }
}

// MARK: - Markup & Expr

/// The syntactical root capable of representing a full parsed document.
public struct Markup: SingleKindAstNode {
    public static let kind: SyntaxKind = .markup
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The expressions.
    public func exprs() -> [Expr] {
        var wasStmt = false
        var result: [Expr] = []
        for child in node.children {
            let kind = child.kind
            let isSpace = kind == .spaceNoNewline || kind == .spaceWithNewline
            // Ignore newline directly after statements without semicolons.
            let keep = !wasStmt || !isSpace
            wasStmt = kind.isStmt
            if keep, let expr = Expr.castWithSpace(child) {
                result.append(expr)
            }
        }
        return result
    }
}

/// An expression in markup, math or code.
public enum Expr: AstNode {
    // Markup
    case text(Text)
    case space(Space)
    case linebreak(Linebreak)
    case parbreak(Parbreak)
    case escape(Escape)
    case shorthand(Shorthand)
    case smartQuote(SmartQuote)
    case strong(Strong)
    case emph(Emph)
    case raw(Raw)
    case link(Link)
    case label(Label)
    case ref(Ref)
    case heading(Heading)
    case listItem(ListItem)
    case enumItem(EnumItem)
    case termItem(TermItem)
    case equation(Equation)
    case math(Math)
    // Math
    case mathLetter(MathLetter)
    case mathSymbol(MathSymbol)
    case mathNumber(MathNumber)
    case mathIdent(MathIdent)
    case mathFieldAccess(MathFieldAccess)
    case mathShorthand(MathShorthand)
    case mathAlignPoint(MathAlignPoint)
    case mathCall(MathCall)
    case mathOpening(MathOpening)
    case mathClosing(MathClosing)
    case mathDelimited(MathDelimited)
    case mathAttach(MathAttach)
    case mathPrimes(MathPrimes)
    case mathFrac(MathFrac)
    case mathRoot(MathRoot)
    // Code
    case ident(Ident)
    case none(NoneExpr)
    case auto(AutoExpr)
    case bool(BoolExpr)
    case int(IntExpr)
    case float(FloatExpr)
    case numeric(Numeric)
    case str(Str)
    case codeBlock(CodeBlock)
    case contentBlock(ContentBlock)
    case parenthesized(Parenthesized)
    case array(ArrayExpr)
    case dict(Dict)
    case unary(Unary)
    case binary(Binary)
    case fieldAccess(FieldAccess)
    case funcCall(FuncCall)
    case closure(Closure)
    case letBinding(LetBinding)
    case destructAssignment(DestructAssignment)
    case setRule(SetRule)
    case showRule(ShowRule)
    case contextual(Contextual)
    case conditional(Conditional)
    case whileLoop(WhileLoop)
    case forLoop(ForLoop)
    case moduleImport(ModuleImport)
    case moduleInclude(ModuleInclude)
    case loopBreak(LoopBreak)
    case loopContinue(LoopContinue)
    case funcReturn(FuncReturn)

    /// Cast including space nodes (upstream `cast_with_space`). Spaces are
    /// skipped by `init(node:)` unless using this method.
    static func castWithSpace(_ node: SyntaxNode) -> Expr? {
        switch node.kind {
        case .spaceNoNewline, .spaceWithNewline:
            return .space(Space(unchecked: node))
        default:
            return Expr(node: node)
        }
    }

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .linebreak: self = .linebreak(Linebreak(unchecked: node))
        case .parbreak: self = .parbreak(Parbreak(unchecked: node))
        case .text: self = .text(Text(unchecked: node))
        case .escape: self = .escape(Escape(unchecked: node))
        case .shorthand: self = .shorthand(Shorthand(unchecked: node))
        case .smartQuote: self = .smartQuote(SmartQuote(unchecked: node))
        case .strong: self = .strong(Strong(unchecked: node))
        case .emph: self = .emph(Emph(unchecked: node))
        case .raw: self = .raw(Raw(unchecked: node))
        case .link: self = .link(Link(unchecked: node))
        case .label: self = .label(Label(unchecked: node))
        case .ref: self = .ref(Ref(unchecked: node))
        case .heading: self = .heading(Heading(unchecked: node))
        case .listItem: self = .listItem(ListItem(unchecked: node))
        case .enumItem: self = .enumItem(EnumItem(unchecked: node))
        case .termItem: self = .termItem(TermItem(unchecked: node))
        case .equation: self = .equation(Equation(unchecked: node))
        case .math: self = .math(Math(unchecked: node))
        case .mathLetter: self = .mathLetter(MathLetter(unchecked: node))
        case .mathSymbol: self = .mathSymbol(MathSymbol(unchecked: node))
        case .mathNumber: self = .mathNumber(MathNumber(unchecked: node))
        case .mathIdent: self = .mathIdent(MathIdent(unchecked: node))
        case .mathFieldAccess: self = .mathFieldAccess(MathFieldAccess(unchecked: node))
        case .mathShorthand: self = .mathShorthand(MathShorthand(unchecked: node))
        case .mathAlignPoint: self = .mathAlignPoint(MathAlignPoint(unchecked: node))
        case .mathCall: self = .mathCall(MathCall(unchecked: node))
        case .mathOpening: self = .mathOpening(MathOpening(unchecked: node))
        case .mathClosing: self = .mathClosing(MathClosing(unchecked: node))
        case .mathDelimited: self = .mathDelimited(MathDelimited(unchecked: node))
        case .mathAttach: self = .mathAttach(MathAttach(unchecked: node))
        case .mathPrimes: self = .mathPrimes(MathPrimes(unchecked: node))
        case .mathFrac: self = .mathFrac(MathFrac(unchecked: node))
        case .mathRoot: self = .mathRoot(MathRoot(unchecked: node))
        case .ident: self = .ident(Ident(unchecked: node))
        case .none: self = .none(NoneExpr(unchecked: node))
        case .auto: self = .auto(AutoExpr(unchecked: node))
        case .bool: self = .bool(BoolExpr(unchecked: node))
        case .int: self = .int(IntExpr(unchecked: node))
        case .float: self = .float(FloatExpr(unchecked: node))
        case .numeric: self = .numeric(Numeric(unchecked: node))
        case .str: self = .str(Str(unchecked: node))
        case .codeBlock: self = .codeBlock(CodeBlock(unchecked: node))
        case .contentBlock: self = .contentBlock(ContentBlock(unchecked: node))
        case .parenthesized: self = .parenthesized(Parenthesized(unchecked: node))
        case .array: self = .array(ArrayExpr(unchecked: node))
        case .dict: self = .dict(Dict(unchecked: node))
        case .unary: self = .unary(Unary(unchecked: node))
        case .binary: self = .binary(Binary(unchecked: node))
        case .fieldAccess: self = .fieldAccess(FieldAccess(unchecked: node))
        case .funcCall: self = .funcCall(FuncCall(unchecked: node))
        case .closure: self = .closure(Closure(unchecked: node))
        case .letBinding: self = .letBinding(LetBinding(unchecked: node))
        case .destructAssignment: self = .destructAssignment(DestructAssignment(unchecked: node))
        case .setRule: self = .setRule(SetRule(unchecked: node))
        case .showRule: self = .showRule(ShowRule(unchecked: node))
        case .contextual: self = .contextual(Contextual(unchecked: node))
        case .conditional: self = .conditional(Conditional(unchecked: node))
        case .whileLoop: self = .whileLoop(WhileLoop(unchecked: node))
        case .forLoop: self = .forLoop(ForLoop(unchecked: node))
        case .moduleImport: self = .moduleImport(ModuleImport(unchecked: node))
        case .moduleInclude: self = .moduleInclude(ModuleInclude(unchecked: node))
        case .loopBreak: self = .loopBreak(LoopBreak(unchecked: node))
        case .loopContinue: self = .loopContinue(LoopContinue(unchecked: node))
        case .funcReturn: self = .funcReturn(FuncReturn(unchecked: node))
        default: return nil
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .text(let n): return n.node
        case .space(let n): return n.node
        case .linebreak(let n): return n.node
        case .parbreak(let n): return n.node
        case .escape(let n): return n.node
        case .shorthand(let n): return n.node
        case .smartQuote(let n): return n.node
        case .strong(let n): return n.node
        case .emph(let n): return n.node
        case .raw(let n): return n.node
        case .link(let n): return n.node
        case .label(let n): return n.node
        case .ref(let n): return n.node
        case .heading(let n): return n.node
        case .listItem(let n): return n.node
        case .enumItem(let n): return n.node
        case .termItem(let n): return n.node
        case .equation(let n): return n.node
        case .math(let n): return n.node
        case .mathLetter(let n): return n.node
        case .mathSymbol(let n): return n.node
        case .mathNumber(let n): return n.node
        case .mathIdent(let n): return n.node
        case .mathFieldAccess(let n): return n.node
        case .mathShorthand(let n): return n.node
        case .mathAlignPoint(let n): return n.node
        case .mathCall(let n): return n.node
        case .mathOpening(let n): return n.node
        case .mathClosing(let n): return n.node
        case .mathDelimited(let n): return n.node
        case .mathAttach(let n): return n.node
        case .mathPrimes(let n): return n.node
        case .mathFrac(let n): return n.node
        case .mathRoot(let n): return n.node
        case .ident(let n): return n.node
        case .none(let n): return n.node
        case .auto(let n): return n.node
        case .bool(let n): return n.node
        case .int(let n): return n.node
        case .float(let n): return n.node
        case .numeric(let n): return n.node
        case .str(let n): return n.node
        case .codeBlock(let n): return n.node
        case .contentBlock(let n): return n.node
        case .parenthesized(let n): return n.node
        case .array(let n): return n.node
        case .dict(let n): return n.node
        case .unary(let n): return n.node
        case .binary(let n): return n.node
        case .fieldAccess(let n): return n.node
        case .funcCall(let n): return n.node
        case .closure(let n): return n.node
        case .letBinding(let n): return n.node
        case .destructAssignment(let n): return n.node
        case .setRule(let n): return n.node
        case .showRule(let n): return n.node
        case .contextual(let n): return n.node
        case .conditional(let n): return n.node
        case .whileLoop(let n): return n.node
        case .forLoop(let n): return n.node
        case .moduleImport(let n): return n.node
        case .moduleInclude(let n): return n.node
        case .loopBreak(let n): return n.node
        case .loopContinue(let n): return n.node
        case .funcReturn(let n): return n.node
        }
    }

    public static var placeholder: Expr {
        .none(NoneExpr.placeholder)
    }

    /// Can this expression be embedded into markup with a hash?
    /// (upstream `Expr::hash`)
    public var needsHashInMarkup: Bool {
        switch self {
        case .ident, .none, .auto, .bool, .int, .float, .numeric, .str,
             .codeBlock, .contentBlock, .parenthesized, .array, .dict,
             .fieldAccess, .funcCall, .letBinding, .setRule, .showRule,
             .contextual, .conditional, .whileLoop, .forLoop, .moduleImport,
             .moduleInclude, .loopBreak, .loopContinue, .funcReturn:
            return true
        default:
            return false
        }
    }

    /// Is this a literal? (upstream `Expr::is_literal`)
    public var isLiteral: Bool {
        switch self {
        case .none, .auto, .bool, .int, .float, .numeric, .str:
            return true
        default:
            return false
        }
    }
}

// MARK: - Comments

/// A line comment: `// ...`.
public struct LineComment: SingleKindAstNode {
    public static let kind: SyntaxKind = .lineComment
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contents of the line comment.
    public func text() -> String {
        let text = node.leafText
        return text.hasPrefix("//") ? String(text.dropFirst(2)) : text
    }
}

/// A block comment: `/* ... */`.
public struct BlockComment: SingleKindAstNode {
    public static let kind: SyntaxKind = .blockComment
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contents of the block comment.
    public func text() -> String {
        let text = node.leafText
        if text.hasPrefix("/*") {
            let inner = text.dropFirst(2)
            if inner.hasSuffix("*/") {
                return String(inner.dropLast(2))
            }
        }
        return text
    }
}

// MARK: - Simple markup nodes

/// Plain text without markup.
public struct Text: SingleKindAstNode {
    public static let kind: SyntaxKind = .text
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the text.
    public func get() -> String { node.leafText }
}

/// Whitespace in markup or math. Has at most one newline in markup, as more
/// indicate a paragraph break.
public struct Space: AstNode {
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .spaceNoNewline, .spaceWithNewline: self.init(unchecked: node)
        default: return nil
        }
    }

    public static var placeholder: Space {
        Space(unchecked: .placeholder(.spaceNoNewline))
    }

    /// Whether the Space contains a newline.
    public var hadNewline: Bool { node.kind == .spaceWithNewline }
}

/// A forced line break: `\`.
public struct Linebreak: SingleKindAstNode {
    public static let kind: SyntaxKind = .linebreak
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// A paragraph break, indicated by contiguous whitespace containing at
/// least two newlines. Only produced in Markup.
public struct Parbreak: SingleKindAstNode {
    public static let kind: SyntaxKind = .parbreak
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// An escape sequence: `\#`, `\u{1F5FA}`.
public struct Escape: SingleKindAstNode {
    public static let kind: SyntaxKind = .escape
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the escaped character.
    public func get() -> Unicode.Scalar {
        var s = Scanner(node.leafText)
        _ = s.eatIf("\\")
        if s.eatIf("u{") {
            let hex = s.eatWhile { scalar in
                switch scalar.value {
                case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
                default: return false
                }
            }
            if let value = UInt32(hex, radix: 16),
               let scalar = Unicode.Scalar(value) {
                return scalar
            }
            return Unicode.Scalar(0)!
        }
        return s.eat() ?? Unicode.Scalar(0)!
    }
}

/// A shorthand for a unicode codepoint. For example, `~` for a non-breaking
/// space or `-?` for a soft hyphen.
public struct Shorthand: SingleKindAstNode {
    public static let kind: SyntaxKind = .shorthand
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// A list of all shorthands in markup mode.
    public static let list: [(String, Unicode.Scalar)] = [
        ("...", "…"),
        ("~", "\u{00A0}"),
        ("-", "−"), // Only before a digit
        ("--", "–"),
        ("---", "—"),
        ("-?", "\u{00AD}"),
    ]

    /// Get the shorthanded character.
    public func get() -> Unicode.Scalar {
        let text = node.leafText
        for (s, c) in Self.list where s == text { return c }
        return Unicode.Scalar(0)!
    }
}

/// A smart quote: `'` or `"`.
public struct SmartQuote: SingleKindAstNode {
    public static let kind: SyntaxKind = .smartQuote
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Whether this is a double quote.
    public var isDouble: Bool { node.leafText == "\"" }
}

/// Strong content: `*Strong*`.
public struct Strong: SingleKindAstNode {
    public static let kind: SyntaxKind = .strong
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contents of the strong node.
    public func body() -> Markup { node.castFirst() }
}

/// Emphasized content: `_Emphasized_`.
public struct Emph: SingleKindAstNode {
    public static let kind: SyntaxKind = .emph
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contents of the emphasis node.
    public func body() -> Markup { node.castFirst() }
}

// MARK: - Raw

/// Raw text with optional syntax highlighting: `` `...` ``.
public struct Raw: SingleKindAstNode {
    public static let kind: SyntaxKind = .raw
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The lines in the raw block.
    public func lines() -> [Text] {
        node.children.compactMap { $0.cast(Text.self) }
    }

    /// An optional identifier specifying the language to syntax-highlight in.
    public func lang() -> RawLang? {
        // Only blocky literals are supposed to contain a language.
        guard let delim = node.tryCastFirst(RawDelim.self), delim.node.len >= 3
        else { return nil }
        return node.tryCastFirst(RawLang.self)
    }

    /// Whether the raw text should be displayed in a separate block.
    public func block() -> Bool {
        let hasBlockDelim = node.tryCastFirst(RawDelim.self)
            .map { $0.node.len >= 3 } ?? false
        return hasBlockDelim && node.children.contains { child in
            child.kind == .rawTrimmed
                && child.leafText.unicodeScalars.contains(where: isNewline)
        }
    }
}

/// A language tag at the start of raw element: ``typ ``.
public struct RawLang: SingleKindAstNode {
    public static let kind: SyntaxKind = .rawLang
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the language tag.
    public func get() -> String { node.leafText }
}

/// A raw delimiter in single or 3+ backticks: `` ` ``.
public struct RawDelim: SingleKindAstNode {
    public static let kind: SyntaxKind = .rawDelim
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

// MARK: - Links, labels, references

/// A hyperlink: `https://typst.org`.
public struct Link: SingleKindAstNode {
    public static let kind: SyntaxKind = .link
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the URL.
    public func get() -> String { node.leafText }
}

/// A label: `<intro>`.
public struct Label: SingleKindAstNode {
    public static let kind: SyntaxKind = .label
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the label's text.
    public func get() -> String {
        var text = node.leafText
        while text.hasPrefix("<") { text.removeFirst() }
        while text.hasSuffix(">") { text.removeLast() }
        return text
    }
}

/// A reference: `@target`, `@target[..]`.
public struct Ref: SingleKindAstNode {
    public static let kind: SyntaxKind = .ref
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Get the target. Will not be empty.
    public func target() -> String {
        guard let marker = node.children.first(where: { $0.kind == .refMarker })
        else { return "" }
        var text = marker.leafText
        while text.hasPrefix("@") { text.removeFirst() }
        return text
    }

    /// Get the supplement.
    public func supplement() -> ContentBlock? {
        node.tryCastLast(ContentBlock.self)
    }
}

// MARK: - Lists & headings

/// A section heading: `= Introduction`.
public struct Heading: SingleKindAstNode {
    public static let kind: SyntaxKind = .heading
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contents of the heading.
    public func body() -> Markup { node.castFirst() }

    /// The section depth (number of equals signs).
    public func depth() -> Int {
        node.children
            .first { $0.kind == .headingMarker }
            .map { $0.len }
            ?? 1
    }
}

/// An item in a bullet list: `- ...`.
public struct ListItem: SingleKindAstNode {
    public static let kind: SyntaxKind = .listItem
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contents of the list item.
    public func body() -> Markup { node.castFirst() }
}

/// An item in an enumeration (numbered list): `+ ...` or `1. ...`.
public struct EnumItem: SingleKindAstNode {
    public static let kind: SyntaxKind = .enumItem
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The explicit numbering, if any: `23.`.
    public func number() -> UInt64? {
        for child in node.children where child.kind == .enumMarker {
            var text = child.leafText
            while text.hasSuffix(".") { text.removeLast() }
            if let n = UInt64(text) { return n }
        }
        return nil
    }

    /// The contents of the list item.
    public func body() -> Markup { node.castFirst() }
}

/// An item in a term list: `/ Term: Details`.
public struct TermItem: SingleKindAstNode {
    public static let kind: SyntaxKind = .termItem
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The term described by the item.
    public func term() -> Markup { node.castFirst() }

    /// The description of the term.
    public func description() -> Markup { node.castLast() }
}

/// A mathematical equation: `$x$`, `$ x^2 $`.
public struct Equation: SingleKindAstNode {
    public static let kind: SyntaxKind = .equation
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The contained math.
    public func body() -> Math { node.castFirst() }

    /// Whether the equation should be displayed as a separate block.
    public func block() -> Bool {
        func isSpace(_ child: SyntaxNode?) -> Bool {
            guard let kind = child?.kind else { return false }
            return kind == .spaceNoNewline || kind == .spaceWithNewline
        }
        let children = node.children
        return isSpace(children.count > 1 ? children[1] : nil)
            && isSpace(children.count > 1 ? children[children.count - 2] : nil)
    }
}
