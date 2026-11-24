import Foundation

// MARK: - Collections

/// An array: `(1, "hi", 12cm)`.
public struct ArrayExpr: SingleKindAstNode {
    public static let kind: SyntaxKind = .array
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The array's items.
    public func items() -> [ArrayItem] {
        node.children.compactMap { $0.cast(ArrayItem.self) }
    }
}

/// An item in an array.
public enum ArrayItem: AstNode {
    /// A bare expression: `12`.
    case pos(Expr)
    /// A spread expression: `..things`.
    case spread(Spread)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .spread: self = .spread(Spread(unchecked: node))
        default:
            guard let expr = node.cast(Expr.self) else { return nil }
            self = .pos(expr)
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .pos(let n): return n.node
        case .spread(let n): return n.node
        }
    }

    public static var placeholder: ArrayItem { .pos(Expr.placeholder) }
}

/// A dictionary: `(thickness: 3pt, dash: "solid")`.
public struct Dict: SingleKindAstNode {
    public static let kind: SyntaxKind = .dict
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The dictionary's items.
    public func items() -> [DictItem] {
        node.children.compactMap { $0.cast(DictItem.self) }
    }
}

/// An item in a dictionary expression.
public enum DictItem: AstNode {
    /// A named pair: `thickness: 3pt`.
    case named(Named)
    /// A keyed pair: `"spacy key": true`.
    case keyed(Keyed)
    /// A spread expression: `..things`.
    case spread(Spread)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .named: self = .named(Named(unchecked: node))
        case .keyed: self = .keyed(Keyed(unchecked: node))
        case .spread: self = .spread(Spread(unchecked: node))
        default: return nil
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .named(let n): return n.node
        case .keyed(let n): return n.node
        case .spread(let n): return n.node
        }
    }

    public static var placeholder: DictItem { .spread(Spread.placeholder) }
}

/// A named pair: `thickness: 3pt`.
public struct Named: SingleKindAstNode {
    public static let kind: SyntaxKind = .named
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The name: `thickness`.
    public func name() -> Ident { node.castFirst() }

    /// The right-hand side of the pair: `3pt`.
    ///
    /// This should only be accessed if this `Named` is contained in a
    /// `DictItem`, `Arg`, or `Param`.
    public func expr() -> Expr { node.castLast() }

    /// The right-hand side of the pair as a pattern.
    ///
    /// This should only be accessed if this `Named` is contained in a
    /// `Destructuring`.
    public func pattern() -> Pattern { node.castLast() }
}

/// A keyed pair: `"spacy key": true`.
public struct Keyed: SingleKindAstNode {
    public static let kind: SyntaxKind = .keyed
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The key: `"spacy key"`.
    public func key() -> Expr { node.castFirst() }

    /// The right-hand side of the pair: `true`.
    ///
    /// This should only be accessed if this `Keyed` is contained in a
    /// `DictItem`.
    public func expr() -> Expr { node.castLast() }
}

/// A spread: `..x` or `..x.at(0)`.
public struct Spread: SingleKindAstNode {
    public static let kind: SyntaxKind = .spread
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The spread expression.
    ///
    /// This should only be accessed if this `Spread` is contained in an
    /// `ArrayItem`, `DictItem`, or `Arg`.
    public func expr() -> Expr { node.castFirst() }

    /// The sink identifier, if present.
    ///
    /// This should only be accessed if this `Spread` is contained in a
    /// `Param` or binding `DestructuringItem`.
    public func sinkIdent() -> Ident? { node.tryCastFirst(Ident.self) }

    /// The sink expressions, if present.
    ///
    /// This should only be accessed if this `Spread` is contained in a
    /// `DestructuringItem`.
    public func sinkExpr() -> Expr? { node.tryCastFirst(Expr.self) }
}

// MARK: - Operators

/// A unary operation: `-x`.
public struct Unary: SingleKindAstNode {
    public static let kind: SyntaxKind = .unary
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The operator: `-`.
    public func op() -> UnOp {
        node.children.lazy
            .compactMap { UnOp(kind: $0.kind) }
            .first ?? .pos
    }

    /// The expression to operate on: `x`.
    public func expr() -> Expr { node.castLast() }
}

/// A binary operation: `a + b`.
public struct Binary: SingleKindAstNode {
    public static let kind: SyntaxKind = .binary
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The binary operator: `+`.
    public func op() -> BinOp {
        var not = false
        for child in node.children {
            switch child.kind {
            case .not:
                not = true
            case .in where not:
                return .notIn
            default:
                if let op = BinOp(kind: child.kind) { return op }
            }
        }
        return .add
    }

    /// The left-hand side of the operation: `a`.
    public func lhs() -> Expr { node.castFirst() }

    /// The right-hand side of the operation: `b`.
    public func rhs() -> Expr { node.castLast() }
}

// MARK: - Calls & closures

/// A field access: `properties.age`.
public struct FieldAccess: SingleKindAstNode {
    public static let kind: SyntaxKind = .fieldAccess
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The expression to access the field on.
    public func target() -> Expr { node.castFirst() }

    /// The name of the field.
    public func field() -> Ident { node.castLast() }
}

/// An invocation of a function or method: `f(x, y)`.
public struct FuncCall: SingleKindAstNode {
    public static let kind: SyntaxKind = .funcCall
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The function to call.
    public func callee() -> Expr { node.castFirst() }

    /// The arguments to the function.
    public func args() -> Args { node.castLast() }
}

/// A function call's argument list: `(12pt, y)`.
public struct Args: SingleKindAstNode {
    public static let kind: SyntaxKind = .args
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The positional and named arguments.
    public func items() -> [Arg] {
        node.children.compactMap { $0.cast(Arg.self) }
    }

    /// Whether there is a comma at the end.
    public func trailingComma() -> Bool {
        let children = node.children
        // Skip the last child (the closing paren), then find the first
        // non-trivia node scanning backwards.
        var i = children.count - 2
        while i >= 0 {
            let child = children[i]
            if !child.kind.isTrivia { return child.kind == .comma }
            i -= 1
        }
        return false
    }
}

/// An argument to a function call.
public enum Arg: AstNode {
    /// A positional argument: `12`.
    case pos(Expr)
    /// A named argument: `draw: false`.
    case named(Named)
    /// A spread argument: `..things`.
    case spread(Spread)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .named: self = .named(Named(unchecked: node))
        case .spread: self = .spread(Spread(unchecked: node))
        default:
            guard let expr = node.cast(Expr.self) else { return nil }
            self = .pos(expr)
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .pos(let n): return n.node
        case .named(let n): return n.node
        case .spread(let n): return n.node
        }
    }

    public static var placeholder: Arg { .pos(Expr.placeholder) }
}

/// A closure: `(x, y) => z`.
public struct Closure: SingleKindAstNode {
    public static let kind: SyntaxKind = .closure
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The name of the closure.
    ///
    /// This only exists if you use the function syntax sugar: `let f(x) = y`.
    public func name() -> Ident? {
        node.children.first.flatMap { $0.cast(Ident.self) }
    }

    /// The parameter bindings.
    public func params() -> Params { node.castFirst() }

    /// The body of the closure.
    public func body() -> Expr { node.castLast() }
}

/// A closure's parameters: `(x, y)`.
public struct Params: SingleKindAstNode {
    public static let kind: SyntaxKind = .params
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The parameter bindings.
    public func items() -> [Param] {
        node.children.compactMap { $0.cast(Param.self) }
    }
}

/// A parameter to a closure.
public enum Param: AstNode {
    /// A positional parameter: `x`.
    case pos(Pattern)
    /// A named parameter with a default value: `draw: false`.
    case named(Named)
    /// An argument sink: `..args` or `..`.
    case spread(Spread)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .named: self = .named(Named(unchecked: node))
        case .spread: self = .spread(Spread(unchecked: node))
        default:
            guard let pattern = node.cast(Pattern.self) else { return nil }
            self = .pos(pattern)
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .pos(let n): return n.node
        case .named(let n): return n.node
        case .spread(let n): return n.node
        }
    }

    public static var placeholder: Param { .pos(Pattern.placeholder) }
}

// MARK: - Patterns & destructuring

/// The kind of a pattern.
public enum Pattern: AstNode {
    /// A single expression: `x`.
    case normal(Expr)
    /// A placeholder: `_`.
    case placeholder(Underscore)
    /// A parenthesized pattern.
    case parenthesized(Parenthesized)
    /// A destructuring pattern: `(x, _, ..y)`.
    case destructuring(Destructuring)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .underscore: self = .placeholder(Underscore(unchecked: node))
        case .parenthesized: self = .parenthesized(Parenthesized(unchecked: node))
        case .destructuring: self = .destructuring(Destructuring(unchecked: node))
        default:
            guard let expr = node.cast(Expr.self) else { return nil }
            self = .normal(expr)
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .normal(let n): return n.node
        case .placeholder(let n): return n.node
        case .parenthesized(let n): return n.node
        case .destructuring(let n): return n.node
        }
    }

    public static var placeholder: Pattern { .normal(Expr.placeholder) }

    /// Returns a list of all new bindings introduced by the pattern.
    public func bindings() -> [Ident] {
        switch self {
        case .normal(.ident(let ident)):
            return [ident]
        case .parenthesized(let v):
            return v.pattern().bindings()
        case .destructuring(let v):
            return v.bindings()
        default:
            return []
        }
    }
}

/// An underscore: `_`
public struct Underscore: SingleKindAstNode {
    public static let kind: SyntaxKind = .underscore
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// A destructuring pattern: `x` or `(x, _, ..y)`.
public struct Destructuring: SingleKindAstNode {
    public static let kind: SyntaxKind = .destructuring
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The items of the destructuring.
    public func items() -> [DestructuringItem] {
        node.children.compactMap { $0.cast(DestructuringItem.self) }
    }

    /// Returns a list of all new bindings introduced by the destructuring.
    public func bindings() -> [Ident] {
        items().flatMap { item -> [Ident] in
            switch item {
            case .pattern(let pattern): return pattern.bindings()
            case .named(let named): return named.pattern().bindings()
            case .spread(let spread):
                return spread.sinkIdent().map { [$0] } ?? []
            }
        }
    }
}

/// The kind of an element in a destructuring pattern.
public enum DestructuringItem: AstNode {
    /// A sub-pattern: `x`.
    case pattern(Pattern)
    /// A renamed destructuring: `x: y`.
    case named(Named)
    /// A destructuring sink: `..y` or `..`.
    case spread(Spread)

    public init?(node: SyntaxNode) {
        switch node.kind {
        case .named: self = .named(Named(unchecked: node))
        case .spread: self = .spread(Spread(unchecked: node))
        default:
            guard let pattern = node.cast(Pattern.self) else { return nil }
            self = .pattern(pattern)
        }
    }

    public var node: SyntaxNode {
        switch self {
        case .pattern(let n): return n.node
        case .named(let n): return n.node
        case .spread(let n): return n.node
        }
    }

    public static var placeholder: DestructuringItem { .pattern(Pattern.placeholder) }
}

// MARK: - Bindings & control flow

/// A let binding: `let x = 1`.
public struct LetBinding: SingleKindAstNode {
    public static let kind: SyntaxKind = .letBinding
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The kind of the let binding.
    public func kind() -> LetBindingKind {
        let pattern: Pattern = node.castFirst()
        if case .normal(.closure(let closure)) = pattern {
            return .closure(closure.name() ?? Ident.placeholder)
        }
        return .normal(pattern)
    }

    /// The expression the binding is initialized with.
    /// (upstream `init()` — renamed to avoid the `init` keyword)
    public func initExpr() -> Expr? {
        switch kind() {
        case .normal(.normal), .normal(.parenthesized):
            let exprs = node.children.compactMap { $0.cast(Expr.self) }
            return exprs.count > 1 ? exprs[1] : nil
        case .normal, .closure:
            return node.tryCastFirst(Expr.self)
        }
    }
}

/// The kind of a let binding, either a normal one or a closure.
public enum LetBindingKind {
    /// A normal binding: `let x = 1`.
    case normal(Pattern)
    /// A closure binding: `let f(x) = 1`.
    case closure(Ident)

    /// Returns a list of all new bindings introduced by the let binding.
    public func bindings() -> [Ident] {
        switch self {
        case .normal(let pattern): return pattern.bindings()
        case .closure(let ident): return [ident]
        }
    }
}

/// An assignment expression `(x, y) = (1, 2)`.
public struct DestructAssignment: SingleKindAstNode {
    public static let kind: SyntaxKind = .destructAssignment
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The pattern of the assignment.
    public func pattern() -> Pattern { node.castFirst() }

    /// The expression that is assigned.
    public func value() -> Expr { node.castLast() }
}

/// A set rule: `set text(...)`.
public struct SetRule: SingleKindAstNode {
    public static let kind: SyntaxKind = .setRule
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The function to set style properties for.
    public func target() -> Expr { node.castFirst() }

    /// The style properties to set.
    public func args() -> Args { node.castLast() }

    /// A condition under which the set rule applies.
    public func condition() -> Expr? {
        guard let idx = node.children.firstIndex(where: { $0.kind == .if })
        else { return nil }
        return node.children[idx...]
            .lazy.compactMap { $0.cast(Expr.self) }
            .first
    }
}

/// A show rule: `show heading: it => emph(it.body)`.
public struct ShowRule: SingleKindAstNode {
    public static let kind: SyntaxKind = .showRule
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Defines which nodes the show rule applies to.
    public func selector() -> Expr? {
        guard let idx = node.children.lastIndex(where: { $0.kind == .colon })
        else { return nil }
        var i = idx
        while i >= 0 {
            if let expr = node.children[i].cast(Expr.self) { return expr }
            i -= 1
        }
        return nil
    }

    /// The transformation recipe.
    public func transform() -> Expr { node.castLast() }
}

/// A contextual expression: `context text.lang`.
public struct Contextual: SingleKindAstNode {
    public static let kind: SyntaxKind = .contextual
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The expression which depends on the context.
    public func body() -> Expr { node.castFirst() }
}

/// An if-else conditional: `if x { y } else { z }`.
public struct Conditional: SingleKindAstNode {
    public static let kind: SyntaxKind = .conditional
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The condition which selects the body to evaluate.
    public func condition() -> Expr { node.castFirst() }

    /// The expression to evaluate if the condition is true.
    public func ifBody() -> Expr {
        let exprs = node.children.compactMap { $0.cast(Expr.self) }
        return exprs.count > 1 ? exprs[1] : Expr.placeholder
    }

    /// The expression to evaluate if the condition is false.
    public func elseBody() -> Expr? {
        let exprs = node.children.compactMap { $0.cast(Expr.self) }
        return exprs.count > 2 ? exprs[2] : nil
    }
}

/// A while loop: `while x { y }`.
public struct WhileLoop: SingleKindAstNode {
    public static let kind: SyntaxKind = .whileLoop
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The condition which selects whether to evaluate the body.
    public func condition() -> Expr { node.castFirst() }

    /// The expression to evaluate while the condition is true.
    public func body() -> Expr { node.castLast() }
}

/// A for loop: `for x in y { z }`.
public struct ForLoop: SingleKindAstNode {
    public static let kind: SyntaxKind = .forLoop
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The pattern to assign to.
    public func pattern() -> Pattern { node.castFirst() }

    /// The expression to iterate over.
    public func iterable() -> Expr {
        guard let idx = node.children.firstIndex(where: { $0.kind == .in })
        else { return Expr.placeholder }
        return node.children[idx...]
            .lazy.compactMap { $0.cast(Expr.self) }
            .first ?? Expr.placeholder
    }

    /// The expression to evaluate for each iteration.
    public func body() -> Expr { node.castLast() }
}

// MARK: - Imports

/// A module import: `import "utils.typ": a, b, c`.
public struct ModuleImport: SingleKindAstNode {
    public static let kind: SyntaxKind = .moduleImport
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The module or path from which the items should be imported.
    public func source() -> Expr { node.castFirst() }

    /// The items to be imported.
    public func imports() -> Imports? {
        for child in node.children {
            switch child.kind {
            case .star: return .wildcard
            case .importItems:
                if let items = child.cast(ImportItems.self) {
                    return .items(items)
                }
            default: continue
            }
        }
        return nil
    }

    /// The name that will be bound for a bare import. This name must be
    /// statically known. It can come from:
    /// - an identifier
    /// - a field access
    /// - a string that is a valid file path where the file stem is a valid
    ///   identifier
    /// - a string that is a valid package spec
    public func bareName() -> Result<String, BareImportError> {
        switch source() {
        case .ident(let ident):
            return .success(ident.get())
        case .fieldAccess(let access):
            return .success(access.field().get())
        case .str(let string):
            let string = string.get()
            let name: String
            if string.hasPrefix("@") {
                guard let spec = try? PackageSpec.parse(string) else {
                    return .failure(.packageInvalid)
                }
                name = spec.name
            } else {
                guard let stem = Self.fileStem(string), !stem.isEmpty else {
                    return .failure(.pathInvalid)
                }
                name = stem
            }
            guard isIdent(name) else { return .failure(.pathInvalid) }
            return .success(name)
        default:
            return .failure(.dynamic)
        }
    }

    /// `std::path::Path::file_stem` for a `/`-separated path string.
    private static func fileStem(_ path: String) -> String? {
        var s = path
        while s.hasSuffix("/") && s.count > 1 { s.removeLast() }
        if s.isEmpty || s == "/" { return nil }
        let name = s.split(separator: "/", omittingEmptySubsequences: false)
            .last.map(String.init) ?? s
        if name == "." || name == ".." { return nil }
        guard let dot = name.lastIndex(of: ".") else { return name }
        if dot == name.startIndex { return name }
        return String(name[..<dot])
    }

    /// The name this module was assigned to, if it was renamed with `as`
    /// (`renamed` in `import "..." as renamed`).
    public func newName() -> Ident? {
        guard let idx = node.children.firstIndex(where: { $0.kind == .as })
        else { return nil }
        return node.children[idx...]
            .lazy.compactMap { $0.cast(Ident.self) }
            .first
    }
}

/// Reasons why a bare name cannot be determined for an import source.
public enum BareImportError: Error, Hashable {
    /// There is no statically resolvable binding name.
    case dynamic
    /// The import source is not a valid path or the path stem not a valid
    /// identifier.
    case pathInvalid
    /// The import source is not a valid package spec.
    case packageInvalid
}

/// The items that ought to be imported from a file.
public enum Imports {
    /// All items in the scope of the file should be imported.
    case wildcard
    /// The specified items from the file should be imported.
    case items(ImportItems)
}

/// Items to import from a module: `a, b, c`.
public struct ImportItems: SingleKindAstNode {
    public static let kind: SyntaxKind = .importItems
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// Returns an iterator over the items to import from the module.
    public func items() -> [ImportItem] {
        node.children.compactMap { child in
            switch child.kind {
            case .renamedImportItem:
                return child.cast(RenamedImportItem.self).map(ImportItem.renamed)
            case .importItemPath:
                return child.cast(ImportItemPath.self).map(ImportItem.simple)
            default:
                return nil
            }
        }
    }
}

/// A path to a submodule's imported name: `a.b.c`.
public struct ImportItemPath: SingleKindAstNode {
    public static let kind: SyntaxKind = .importItemPath
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// An iterator over the path's components.
    public func components() -> [Ident] {
        node.children.compactMap { $0.cast(Ident.self) }
    }

    /// The name of the imported item. This is the last segment in the path.
    public func name() -> Ident { node.castLast() }
}

/// An imported item, potentially renamed to another identifier.
public enum ImportItem {
    /// A non-renamed import (the item's name in the scope is the same as its
    /// name).
    case simple(ImportItemPath)
    /// A renamed import (the item was bound to a different name in the scope
    /// than the one it was defined as).
    case renamed(RenamedImportItem)

    /// The path to the imported item.
    public func path() -> ImportItemPath {
        switch self {
        case .simple(let path): return path
        case .renamed(let renamed): return renamed.path()
        }
    }

    /// The original name of the imported item, at its source. This will be the
    /// equal to the bound name if the item wasn't renamed with 'as'.
    public func originalName() -> Ident {
        switch self {
        case .simple(let path): return path.name()
        case .renamed(let renamed): return renamed.originalName()
        }
    }

    /// The name which this import item was bound to. Corresponds to the new
    /// name, if it was renamed; otherwise, it's just its original name.
    public func boundName() -> Ident {
        switch self {
        case .simple(let path): return path.name()
        case .renamed(let renamed): return renamed.newName()
        }
    }
}

/// A renamed import item: `a as d`
public struct RenamedImportItem: SingleKindAstNode {
    public static let kind: SyntaxKind = .renamedImportItem
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The path to the imported item.
    public func path() -> ImportItemPath { node.castFirst() }

    /// The original name of the imported item (`a` in `a as d` or `c.b.a as d`).
    public func originalName() -> Ident { path().name() }

    /// The new name of the imported item (`d` in `a as d`).
    public func newName() -> Ident { node.castLast() }
}

/// A module include: `include "chapter1.typ"`.
public struct ModuleInclude: SingleKindAstNode {
    public static let kind: SyntaxKind = .moduleInclude
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The module or path from which the content should be included.
    public func source() -> Expr { node.castLast() }
}

/// A break from a loop: `break`.
public struct LoopBreak: SingleKindAstNode {
    public static let kind: SyntaxKind = .loopBreak
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// A continue in a loop: `continue`.
public struct LoopContinue: SingleKindAstNode {
    public static let kind: SyntaxKind = .loopContinue
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }
}

/// A return from a function: `return`, `return x + 1`.
public struct FuncReturn: SingleKindAstNode {
    public static let kind: SyntaxKind = .funcReturn
    public let node: SyntaxNode
    public init(unchecked node: SyntaxNode) { self.node = node }

    /// The expression to return.
    public func body() -> Expr? { node.tryCastLast(Expr.self) }
}
