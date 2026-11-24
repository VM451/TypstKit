import Foundation

/// A syntax highlighting tag.
///
/// Port of `typst_syntax::highlight::Tag`. Raw values match upstream's
/// declaration order (`tag as usize` compatibility via `Tag.LIST`).
public enum HighlightTag: UInt8, Hashable, Sendable, CaseIterable {
    /// A line or block comment.
    case comment
    /// Punctuation in code.
    case punctuation
    /// An escape sequence or shorthand.
    case escape
    /// Strong markup.
    case strong
    /// Emphasized markup.
    case emph
    /// A hyperlink.
    case link
    /// Raw text.
    case raw
    /// A label.
    case label
    /// A reference to a label.
    case ref
    /// A section heading.
    case heading
    /// A marker of a list, enumeration, or term list.
    case listMarker
    /// A term in a term list.
    case listTerm
    /// The delimiters of an equation.
    case mathDelimiter
    /// An operator with special meaning in an equation.
    case mathOperator
    /// Parentheses used for grouping in an equation.
    case mathGroupingParens
    /// A keyword.
    case keyword
    /// An operator in code.
    case `operator`
    /// A numeric literal.
    case number
    /// A string literal.
    case string
    /// A function or method name.
    case function
    /// An interpolated variable in markup or math.
    case interpolated
    /// A syntax error.
    case error

    /// The list of all tags, in the same order as they are defined.
    ///
    /// Can be used as the counter-part to `tag.rawValue`.
    public static let list: [HighlightTag] = allCases

    /// The recommended TextMate grammar scope for the given highlighting
    /// tag.
    public var tmScope: String {
        switch self {
        case .comment: return "comment.typst"
        case .punctuation: return "punctuation.typst"
        case .escape: return "constant.character.escape.typst"
        case .strong: return "markup.bold.typst"
        case .emph: return "markup.italic.typst"
        case .link: return "markup.underline.link.typst"
        case .raw: return "markup.raw.typst"
        case .mathDelimiter: return "punctuation.definition.math.typst"
        case .mathOperator: return "keyword.operator.math.typst"
        case .mathGroupingParens: return "punctuation.math.typst"
        case .heading: return "markup.heading.typst"
        case .listMarker: return "punctuation.definition.list.typst"
        case .listTerm: return "markup.list.term.typst"
        case .label: return "entity.name.label.typst"
        case .ref: return "markup.other.reference.typst"
        case .keyword: return "keyword.typst"
        case .operator: return "keyword.operator.typst"
        case .number: return "constant.numeric.typst"
        case .string: return "string.quoted.double.typst"
        case .function: return "entity.name.function.typst"
        case .interpolated: return "meta.interpolation.typst"
        case .error: return "invalid.typst"
        }
    }

    /// The recommended CSS class for the highlighting tag.
    public var cssClass: String {
        switch self {
        case .comment: return "typ-comment"
        case .punctuation: return "typ-punct"
        case .escape: return "typ-escape"
        case .strong: return "typ-strong"
        case .emph: return "typ-emph"
        case .link: return "typ-link"
        case .raw: return "typ-raw"
        case .label: return "typ-label"
        case .ref: return "typ-ref"
        case .heading: return "typ-heading"
        case .listMarker: return "typ-marker"
        case .listTerm: return "typ-term"
        case .mathDelimiter: return "typ-math-delim"
        case .mathOperator: return "typ-math-op"
        case .mathGroupingParens: return "typ-math-group"
        case .keyword: return "typ-key"
        case .operator: return "typ-op"
        case .number: return "typ-num"
        case .string: return "typ-str"
        case .function: return "typ-func"
        case .interpolated: return "typ-pol"
        case .error: return "typ-error"
        }
    }
}

/// Determine the highlight tag of a linked syntax node.
///
/// Returns `nil` if the node should not be highlighted.
///
/// Port of `typst_syntax::highlight::highlight`.
public func highlight(_ node: LinkedNode) -> HighlightTag? {
    switch node.kind {
    case .markup:
        if node.parentKind() == .termItem,
           node.nextSiblingKind() == .colon {
            return .listTerm
        }
        return nil
    case .text, .spaceNoNewline, .spaceWithNewline, .parbreak,
         .smartQuote, .rawLang, .rawTrimmed, .rawDelim, .refMarker,
         .headingMarker, .listItem, .enumItem, .termItem, .equation,
         .math, .mathLetter, .mathSymbol, .mathNumber, .mathFieldAccess,
         .mathCall, .mathArgs, .mathOpening, .mathClosing, .mathDelimited,
         .mathAttach, .mathFrac, .mathRoot,
         .code, .codeBlock, .contentBlock, .parenthesized, .array, .dict,
         .named, .keyed, .unary, .binary, .fieldAccess, .funcCall, .args,
         .spread, .closure, .params, .letBinding, .setRule, .showRule,
         .contextual, .conditional, .whileLoop, .forLoop, .moduleImport,
         .importItems, .importItemPath, .renamedImportItem, .moduleInclude,
         .loopBreak, .loopContinue, .funcReturn, .destructuring,
         .destructAssignment:
        return nil

    case .linebreak, .escape, .shorthand, .mathShorthand:
        return .escape
    case .strong: return .strong
    case .emph: return .emph
    case .raw: return .raw
    case .link: return .link
    case .label: return .label
    case .ref: return .ref
    case .heading: return .heading
    case .listMarker, .enumMarker, .termMarker: return .listMarker
    case .mathAlignPoint, .mathPrimes: return .mathOperator
    case .hash: return highlightHash(node)
    case .leftBrace, .rightBrace, .leftBracket, .rightBracket,
         .comma, .semicolon, .colon, .dot:
        return .punctuation
    case .leftParen, .rightParen:
        return node.parentKind() == .math ? .mathGroupingParens : .punctuation
    case .star:
        return node.parentKind() == .strong ? nil : .`operator`
    case .underscore:
        return node.parentKind() == .mathAttach ? .mathOperator : nil
    case .dollar: return .mathDelimiter
    case .plus, .minus:
        return .`operator`
    case .slash:
        return node.parentKind() == .mathFrac ? .mathOperator : .`operator`
    case .hat, .root: return .mathOperator
    case .eq:
        return node.parentKind() == .heading ? nil : .`operator`
    case .eqEq, .exclEq, .lt, .ltEq, .gt, .gtEq, .plusEq, .hyphEq, .starEq,
         .slashEq, .dots, .arrow:
        return .`operator`
    case .bang: return nil

    case .not, .`and`, .`or`, .none, .auto, .`let`, .`set`, .`show`,
         .`context`, .`if`, .`else`, .`for`, .`in`, .`while`, .`break`,
         .`continue`, .`return`, .`import`, .`include`, .`as`, .bool:
        return .keyword

    case .int, .float, .numeric: return .number
    case .str: return .string
    case .ident, .mathIdent: return highlightIdent(node)

    case .shebang, .lineComment, .blockComment: return .comment
    case .error: return .error
    case .end: return nil
    }
}

/// Highlight an identifier based on context.
///
/// Port of `highlight_ident` in upstream `highlight.rs`.
private func highlightIdent(_ node: LinkedNode) -> HighlightTag? {
    // Are we directly before an argument list?
    if let next = node.nextLeaf(),
       node.range().upperBound == next.offset {
        if (next.kind == .leftParen
            && [.args, .mathArgs, .params].contains(next.parentKind() ?? .end))
            || (next.kind == .leftBracket
                && next.parentKind() == .contentBlock) {
            return .function
        }
    }

    // Are we in math?
    if node.kind == .mathIdent || node.kind == .mathFieldAccess {
        return .interpolated
    }

    // Find the first non-field access ancestor.
    var ancestor = node
    while ancestor.parentKind() == .fieldAccess {
        guard let parent = ancestor.parent else { return nil }
        ancestor = parent
    }

    // Are we directly before or behind a show rule colon?
    if ancestor.parentKind() == .showRule,
       (node.nextLeaf()?.kind == .colon
        || node.prevLeaf()?.kind == .colon) {
        return .function
    }

    // Are we (or an ancestor field access) directly after a hash.
    if ancestor.prevLeaf()?.kind == .hash {
        return .interpolated
    }

    // Are we behind a dot, that is behind another identifier?
    guard let prev = node.prevLeaf() else { return nil }
    if prev.kind == .dot {
        guard let prevPrev = prev.prevLeaf(), isIdentNode(prevPrev) else {
            return nil
        }
        return highlightIdent(prevPrev)
    }

    return nil
}

/// Whether the node is one of the two identifier nodes.
private func isIdentNode(_ node: LinkedNode) -> Bool {
    node.kind == .ident || node.kind == .mathIdent
}

/// Highlight a hash based on context.
///
/// Port of `highlight_hash` in upstream `highlight.rs`.
private func highlightHash(_ node: LinkedNode) -> HighlightTag? {
    guard let next = node.nextSibling(),
          let expr = next.node.cast(Expr.self),
          expr.needsHashInMarkup else {
        return nil
    }
    return next.leftmostLeaf().flatMap { highlight($0) }
}

/// Highlight a node to an HTML `code` element.
///
/// This uses these [CSS classes for categories](HighlightTag/cssClass).
///
/// Port of `highlight_html` in upstream `highlight.rs`.
public func highlightHTML(_ root: SyntaxNode) -> String {
    var buf = "<code>"
    highlightHTMLImpl(&buf, LinkedNode(root: root))
    buf += "</code>"
    return buf
}

/// Highlight one source node, emitting HTML.
private func highlightHTMLImpl(_ html: inout String, _ node: LinkedNode) {
    var span = false
    if let tag = highlight(node), tag != .error {
        span = true
        html += "<span class=\"\(tag.cssClass)\">"
    }

    let text = node.leafText
    if !text.isEmpty {
        for c in text {
            switch c {
            case "<": html += "&lt;"
            case ">": html += "&gt;"
            case "&": html += "&amp;"
            case "'": html += "&#39;"
            case "\"": html += "&quot;"
            default: html.append(c)
            }
        }
    } else {
        for child in node.children() {
            highlightHTMLImpl(&html, child)
        }
    }

    if span {
        html += "</span>"
    }
}
