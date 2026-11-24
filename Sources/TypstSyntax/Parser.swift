import Foundation

/// The maximum expression nesting depth before erroring out.
/// Port of `MAX_DEPTH` in `typst-syntax/src/parser.rs`.
private let maxDepth = 256

/// Parses a source file as top-level markup.
public func parse(_ text: String) -> SyntaxNode {
    let p = Parser(text: text, offset: 0, mode: .markup)
    markupExprs(p, atStart: true, stopSet: SyntaxSet(.end))
    return p.finishInto(.markup)
}

/// Parses top-level code.
public func parseCode(_ text: String) -> SyntaxNode {
    let p = Parser(text: text, offset: 0, mode: .code)
    codeExprs(p, stopSet: SyntaxSet(.end))
    return p.finishInto(.code)
}

/// Parses top-level math.
public func parseMath(_ text: String) -> SyntaxNode {
    let p = Parser(text: text, offset: 0, mode: .math)
    mathExprs(p, stopSet: SyntaxSet(.end))
    return p.finishInto(.math)
}

/// Parses markup expressions until a stop condition is met.
private func markup(
    _ p: Parser, atStart: Bool, wrapTrivia: Bool, stopSet: SyntaxSet
) {
    let m = wrapTrivia ? p.beforeTrivia() : p.marker()
    markupExprs(p, atStart: atStart, stopSet: stopSet)
    if wrapTrivia {
        p.flushTrivia()
    }
    p.wrap(m, kind: .markup)
}

/// Parses a sequence of markup expressions.
private func markupExprs(
    _ p: Parser, atStart: Bool, stopSet: SyntaxSet
) {
    guard p.checkDepthUntil(stopSet) else { return }

    var atStart = atStart || p.hadNewline()
    var nesting = 0
    // Keep going if we're at a nested right-bracket regardless of the stop set.
    while !p.atSet(stopSet) || (nesting > 0 && p.at(.rightBracket)) {
        markupExpr(p, atStart: atStart, nesting: &nesting)
        atStart = p.hadNewline()
    }
}

/// Reparses a subsection of markup incrementally.
func reparseMarkup(
    _ text: String,
    range: Range<Int>,
    atStart: inout Bool,
    nesting: inout Int,
    topLevel: Bool
) -> [SyntaxNode]? {
    let p = Parser(text: text, offset: range.lowerBound, mode: .markup)
    atStart = atStart || p.hadNewline()
    while !p.end() && p.currentStart() < range.upperBound {
        // If not top-level and at a new RightBracket, stop the reparse.
        if !topLevel && nesting == 0 && p.at(.rightBracket) {
            break
        }
        markupExpr(p, atStart: atStart, nesting: &nesting)
        atStart = p.hadNewline()
    }
    return (p.balanced && p.currentStart() == range.upperBound) ? p.finish() : nil
}

/// Parses a single markup expression.
private func markupExpr(
    _ p: Parser, atStart: Bool, nesting: inout Int
) {
    guard p.increaseDepth() else { return }
    defer { p.depth -= 1 }

    switch p.current() {
    case .leftBracket:
        nesting += 1
        p.convertAndEat(.text)

    case .rightBracket where nesting > 0:
        nesting -= 1
        p.convertAndEat(.text)

    case .rightBracket:
        p.unexpected()
        p.hint("try using a backslash escape: \\]")

    case .shebang:
        p.eat()

    case .text, .linebreak, .escape, .shorthand, .smartQuote, .link, .label:
        p.eat()

    case .raw:
        p.eat() // Raw is handled entirely in the Lexer.

    case .hash:
        embeddedCodeExpr(p)
    case .star:
        strong(p)
    case .underscore:
        emph(p)
    case .headingMarker where atStart:
        heading(p)
    case .listMarker where atStart:
        listItem(p)
    case .enumMarker where atStart:
        enumItem(p)
    case .termMarker where atStart:
        termItem(p)
    case .refMarker:
        reference(p)
    case .dollar:
        equation(p)

    case .headingMarker, .listMarker, .enumMarker, .termMarker, .colon:
        p.convertAndEat(.text)

    default:
        p.unexpected()
    }
}

/// Parses strong content: `*Strong*`.
private func strong(_ p: Parser) {
    p.withNlMode(.stopParBreak) {
        let m = p.marker()
        p.assert(.star)
        markup(p, atStart: false, wrapTrivia: true,
               stopSet: SyntaxSet(.star, .rightBracket, .end))
        let hadClosing = p.expectClosingDelimiter(m, kind: .star)
        p.wrap(m, kind: .strong)
        if hadClosing && p[m].len == 2 {
            p[m].warn("no text within stars")
            p[m].hint(
                "using multiple consecutive stars (e.g. **) has no " +
                "additional effect"
            )
        }
    }
}

/// Parses emphasized content: `_Emphasized_`.
private func emph(_ p: Parser) {
    p.withNlMode(.stopParBreak) {
        let m = p.marker()
        p.assert(.underscore)
        markup(p, atStart: false, wrapTrivia: true,
               stopSet: SyntaxSet(.underscore, .rightBracket, .end))
        let hadClosing = p.expectClosingDelimiter(m, kind: .underscore)
        p.wrap(m, kind: .emph)
        if hadClosing && p[m].len == 2 {
            p[m].warn("no text within underscores")
            p[m].hint(
                "using multiple consecutive underscores (e.g. __) has no " +
                "additional effect"
            )
        }
    }
}

/// Parses a section heading: `= Introduction`.
private func heading(_ p: Parser) {
    p.withNlMode(.stop) {
        let m = p.marker()
        p.assert(.headingMarker)
        markup(p, atStart: false, wrapTrivia: false,
               stopSet: SyntaxSet(.label, .rightBracket, .end))
        p.wrap(m, kind: .heading)
    }
}

/// Parses an item in a bullet list: `- ...`.
private func listItem(_ p: Parser) {
    p.withNlMode(.requireColumn(p.currentColumn())) {
        let m = p.marker()
        p.assert(.listMarker)
        markup(p, atStart: true, wrapTrivia: false,
               stopSet: SyntaxSet(.rightBracket, .end))
        p.wrap(m, kind: .listItem)
    }
}

/// Parses an item in an enumeration (numbered list): `+ ...` or `1. ...`.
private func enumItem(_ p: Parser) {
    p.withNlMode(.requireColumn(p.currentColumn())) {
        let m = p.marker()
        p.assert(.enumMarker)
        markup(p, atStart: true, wrapTrivia: false,
               stopSet: SyntaxSet(.rightBracket, .end))
        p.wrap(m, kind: .enumItem)
    }
}

/// Parses an item in a term list: `/ Term: Details`.
private func termItem(_ p: Parser) {
    p.withNlMode(.requireColumn(p.currentColumn())) {
        let m = p.marker()
        p.withNlMode(.stop) {
            p.assert(.termMarker)
            markup(p, atStart: false, wrapTrivia: false,
                   stopSet: SyntaxSet(.colon, .rightBracket, .end))
        }
        p.expect(.colon)
        markup(p, atStart: true, wrapTrivia: false,
               stopSet: SyntaxSet(.rightBracket, .end))
        p.wrap(m, kind: .termItem)
    }
}

/// Parses a reference: `@target`, `@target[..]`.
private func reference(_ p: Parser) {
    let m = p.marker()
    p.assert(.refMarker)
    if p.directlyAt(.leftBracket) {
        contentBlock(p)
    }
    p.wrap(m, kind: .ref)
}

/// Parses a mathematical equation: `$x$`, `$ x^2 $`.
private func equation(_ p: Parser) {
    let m = p.marker()
    p.enterModes(.math, .continue) {
        p.assert(.dollar)
        math(p, stopSet: SyntaxSet(.dollar, .end))
        _ = p.expectClosingDelimiter(m, kind: .dollar)
    }
    p.wrap(m, kind: .equation)
}

/// Parses the contents of a mathematical equation: `x^2 + 1`.
private func math(_ p: Parser, stopSet: SyntaxSet) {
    let m = p.marker()
    _ = mathExprs(p, stopSet: stopSet)
    p.wrap(m, kind: .math)
}

/// Parses a sequence of math expressions. Returns the number of expressions
/// parsed (including errors).
@discardableResult
private func mathExprs(_ p: Parser, stopSet: SyntaxSet) -> Int {
    guard p.checkDepthUntil(stopSet) else { return 1 }

    var count = 0
    while !p.atSet(stopSet) {
        if p.atSet(.mathExpr) {
            mathExpr(p)
        } else {
            p.unexpected()
        }
        count += 1
    }
    return count
}

/// Parses a single math expression.
private func mathExpr(_ p: Parser) {
    mathExprPrec(p, minPrec: 0, stopSet: SyntaxSet())
}

/// Parses a math expression with at least the given precedence, possibly
/// chaining with another operator by returning early.
private func mathExprPrec(_ p: Parser, minPrec: UInt8, stopSet: SyntaxSet) {
    guard p.increaseDepth() else { return }
    defer { p.depth -= 1 }

    let m = p.marker()
    // Whether this expression can group with a following open delimiter as an
    // implicit function call.
    var continuable = false
    switch p.current() {
    case .hash:
        embeddedCodeExpr(p)

    // The lexer manages creating full MathFieldAccess nodes if needed.
    case .mathIdent, .mathFieldAccess:
        continuable = true
        p.eat()
        // Parse a function call for an identifier or field access.
        if mathFuncPrec >= minPrec && p.directlyAt(.leftParen) {
            mathArgs(p)
            p.wrap(m, kind: .mathCall)
            continuable = false
        }

    // Parse delimiters as an atomic unit.
    case .mathOpening, .leftParen:
        mathDelimited(p)
    // An unmatched closing delimiter.
    case .mathClosing, .rightParen:
        p.convertAndEat(.mathClosing)

    case .bang, .comma, .semicolon:
        p.convertAndEat(.mathSymbol)

    case .linebreak, .mathAlignPoint, .mathSymbol, .mathNumber,
         .mathShorthand:
        p.eat()

    case .mathLetter, .mathPrimes, .escape, .str:
        continuable = true
        p.eat()

    // The only prefix operator in math.
    case .root:
        p.eat()
        let m2 = p.marker()
        mathExprPrec(p, minPrec: mathRootPrec, stopSet: SyntaxSet())
        mathUnparen(p, m2)
        p.wrap(m, kind: .mathRoot)

    default:
        p.expected("expression")
    }

    // Maybe recognize an implicit function call.
    if continuable
        && mathFuncPrec >= minPrec
        && !p.hadTrivia()
        && p.atSet(SyntaxSet(.mathOpening, .leftParen))
    {
        mathDelimited(p)
        p.wrap(m, kind: .math)
    }

    // Parse infix and postfix operators. The general form of a parsed op looks
    // like: `MathAttach[ MathLetter("x"), Hat("^"), MathNumber("2") ]`.
    while !p.atSet(stopSet) {
        let opKind = p.current()
        guard let (wrapper, infixAssoc, prec) = mathOp(opKind, hadTrivia: p.hadTrivia()),
              prec >= minPrec
        else { break }

        // Prepare a chaining set for the attachment operators.
        var chainSet: SyntaxSet
        if wrapper == .mathAttach {
            // Hat can chain with Underscore, Underscore can chain with Hat, and
            // Prime can chain with either (but prime can't interrupt a chain,
            // see below).
            chainSet = SyntaxSet(.hat, .underscore).removing(opKind)
        } else {
            chainSet = SyntaxSet()
        }

        // Eat the operator itself.
        if opKind == .bang {
            p.convertAndEat(.mathSymbol)
        } else {
            p.eat()
        }

        // Slash is the only operator that removes parens from its left operand.
        if wrapper == .mathFrac {
            mathUnparen(p, m)
        }

        // Parse the operator's right operand.
        if let assoc = infixAssoc {
            let rhsPrec: UInt8 = assoc == .left ? prec + 1 : prec
            let mRhs = p.marker()
            mathExprPrec(p, minPrec: rhsPrec, stopSet: chainSet)
            mathUnparen(p, mRhs)
        }

        // Avoid interrupting a chain when initially parsing a prime.
        // For `a^b'_c^d` the grouping is `(a^(b')_c)^d` and not `a^(b'_c^d)`.
        if !(opKind == .mathPrimes && p.atSet(stopSet)) {
            // Parse chained attachment operators as a single attachment.
            while p.atSet(chainSet) {
                chainSet = chainSet.removing(p.current())
                p.eat()
                let mChainRhs = p.marker()
                mathExprPrec(p, minPrec: prec, stopSet: chainSet)
                mathUnparen(p, mChainRhs)
            }
        }

        // Finish the operator by wrapping from its left operand.
        p.wrap(m, kind: wrapper)
    }
}

// These are declared here so they're easier to compare with `mathOp`.
private let mathFuncPrec: UInt8 = 2
private let mathRootPrec: UInt8 = 2

/// Precedence and wrapper kinds for infix and postfix math operators.
private func mathOp(
    _ kind: SyntaxKind, hadTrivia: Bool
) -> (SyntaxKind, Assoc?, UInt8)? {
    switch kind {
    case .slash: return (.mathFrac, .left, 1)
    case .underscore: return (.mathAttach, .right, 2)
    case .hat: return (.mathAttach, .right, 2)
    case .mathPrimes where !hadTrivia: return (.mathAttach, nil, 2)
    case .bang where !hadTrivia: return (.math, nil, 3)
    default: return nil
    }
}

/// Parse matched delimiters in math: `[x + y]`.
private func mathDelimited(_ p: Parser) {
    let m = p.marker()
    p.convertAndEat(.mathOpening) // Converts `LeftParen`.
    let mBody = p.marker()
    _ = mathExprs(p, stopSet: SyntaxSet(.dollar, .end, .mathClosing, .rightParen))
    if p.atSet(SyntaxSet(.mathClosing, .rightParen)) {
        p.wrap(mBody, kind: .math)
        p.convertAndEat(.mathClosing) // Converts `RightParen`.
        p.wrap(m, kind: .mathDelimited)
    } else {
        // If we had no closing delimiter, just produce a math sequence.
        p.wrap(m, kind: .math)
    }
}

/// Remove one set of parentheses (if any) from a previously parsed expression
/// by converting to non-expression `SyntaxKind`s.
private func mathUnparen(_ p: Parser, _ m: Marker) {
    let node = p[m]
    let children = node.children
    if node.kind == .mathDelimited, children.count >= 2,
       children[0].leafText == "(", children[children.count - 1].leafText == ")"
    {
        // `LeftParen` and `RightParen` kinds are skipped in the AST.
        children[0].convertToKind(.leftParen)
        children[children.count - 1].convertToKind(.rightParen)
        node.convertToKind(.math)
    }
}

/// Parse an argument list in math: `(a, b; c, d; size: #50%)`.
private func mathArgs(_ p: Parser) {
    let m = p.marker()
    p.assert(.leftParen)

    var seen = Set<String>()
    while !p.atSet(SyntaxSet(.end, .dollar, .rightParen)) {
        mathArg(p, seen: &seen)
        switch p.current() {
        case .end, .dollar, .rightParen:
            break
        case .semicolon, .comma:
            p.eat()
        default:
            p.expected("comma or semicolon")
        }
    }

    _ = p.expectClosingDelimiter(m, kind: .rightParen)
    p.wrap(m, kind: .mathArgs)
}

/// Parses a single argument in a math argument list.
private func mathArg(_ p: Parser, seen: inout Set<String>) {
    let m = p.marker()
    let start = p.currentStart()

    var argKind: SyntaxKind? = nil

    if let spread = p.lexer.maybeMathSpreadArg(start: start) {
        // Parses a spread argument: `..args`.
        argKind = .spread
        p.token.node = spread
        p.eat()
    } else if let named = p.lexer.maybeMathNamedArg(start: start) {
        // Parses a named argument: `thickness: #12pt`.
        argKind = .named
        p.token.node = named
        let text = p.currentText()
        p.eat()
        p.convertAndEat(.colon)
        if !seen.insert(text).inserted {
            p[m].convertToError("duplicate argument: \(text)")
        }
    }

    // Parses the argument itself.
    let mArg = p.marker()
    let count = mathExprs(p, stopSet: SyntaxSet(.end, .dollar, .comma, .semicolon, .rightParen))

    if count == 0 {
        // This can't happen due to checks in `Lexer::maybe_math_spread_arg`.
        precondition(argKind != .spread)

        // Named arguments require a value.
        if argKind == .named {
            p.expected("expression")
        }
    }

    // Wrap math function arguments to join adjacent math content or create an
    // empty 'Math' node for when we have 0 args.
    if count != 1 {
        p.wrap(mArg, kind: .math)
    }

    if let kind = argKind {
        p.wrap(m, kind: kind)
    }
}

/// Parses the contents of a code block.
private func code(_ p: Parser, stopSet: SyntaxSet) {
    let m = p.marker()
    codeExprs(p, stopSet: stopSet)
    p.wrap(m, kind: .code)
}

/// Parses a sequence of code expressions.
private func codeExprs(_ p: Parser, stopSet: SyntaxSet) {
    guard p.checkDepthUntil(stopSet) else { return }

    while !p.atSet(stopSet) {
        p.withNlMode(.contextualContinue) {
            if !p.atSet(.codeExpr) {
                p.unexpected()
                return
            }
            codeExpr(p)
            if !p.atSet(stopSet) && !p.eatIf(.semicolon) {
                p.expected("semicolon or line break")
                if p.at(.label) {
                    p.hint("labels can only be applied in markup mode")
                    p.hint("try wrapping your code in a markup block (`[ ]`)")
                }
            }
        }
    }
}

/// Parses an atomic code expression embedded in markup or math.
private func embeddedCodeExpr(_ p: Parser) {
    p.enterModes(.code, .stop) {
        p.assert(.hash)
        if p.hadTrivia() || p.end() {
            p.expected("expression")
            return
        }

        let stmt = p.atSet(.stmt)
        codeExprPrec(p, atomic: true, minPrec: 0)

        // Note: 2d math arguments rely on the `directly_at` check.
        let semi = (stmt || p.directlyAt(.semicolon)) && p.eatIf(.semicolon)

        if stmt && !semi && !p.end() && !p.at(.rightBracket) {
            p.expected("semicolon or line break")
        }
    }
}

/// Parses a single code expression.
private func codeExpr(_ p: Parser) {
    codeExprPrec(p, atomic: false, minPrec: 0)
}

/// Parses a code expression with at least the given precedence.
private func codeExprPrec(_ p: Parser, atomic: Bool, minPrec: UInt8) {
    guard p.increaseDepth() else { return }
    defer { p.depth -= 1 }

    let m = p.marker()
    if p.atSet(.unaryOp) {
        if !atomic {
            let op = UnOp(kind: p.current())!
            p.eat()
            codeExprPrec(p, atomic: atomic, minPrec: op.precedence)
            p.wrap(m, kind: .unary)
        } else {
            p.unexpected()
            p.hint(
                "to use a unary operator here, wrap the entire expression " +
                "in parentheses"
            )
        }
    } else {
        codePrimary(p, atomic: atomic)
    }

    while true {
        if p.directlyAt(.leftParen) || p.directlyAt(.leftBracket) {
            args(p)
            p.wrap(m, kind: .funcCall)
            continue
        }

        var lexerCopy = p.lexer
        let atFieldOrMethod = p.directlyAt(.dot) && lexerCopy.next().0 == .ident

        if atomic && !atFieldOrMethod {
            break
        }

        if p.eatIf(.dot) {
            p.expect(.ident)
            p.wrap(m, kind: .fieldAccess)
            continue
        }

        var binop: BinOp? = nil
        if p.atSet(.binaryOp) {
            binop = BinOp(kind: p.current())
        } else if minPrec <= BinOp.notIn.precedence && p.eatIf(.not) {
            if p.at(.in) {
                binop = .notIn
            } else {
                p.expected("keyword `in`")
                break
            }
        }

        if let op = binop {
            var prec = op.precedence
            if prec < minPrec {
                break
            }

            if op.assoc == .left {
                prec += 1
            }

            p.eat()
            codeExprPrec(p, atomic: false, minPrec: prec)
            p.wrap(m, kind: .binary)
            continue
        }

        break
    }
}

/// Parses a primary in a code expression.
private func codePrimary(_ p: Parser, atomic: Bool) {
    let m = p.marker()
    switch p.current() {
    case .ident:
        p.eat()
        if !atomic && p.at(.arrow) {
            p.wrap(m, kind: .params)
            p.assert(.arrow)
            codeExpr(p)
            p.wrap(m, kind: .closure)
        }

    case .underscore where !atomic:
        p.eat()
        if p.at(.arrow) {
            p.wrap(m, kind: .params)
            p.eat()
            codeExpr(p)
            p.wrap(m, kind: .closure)
        } else if p.eatIf(.eq) {
            codeExpr(p)
            p.wrap(m, kind: .destructAssignment)
        } else {
            p[m].expected("expression")
        }

    case .leftBrace:
        codeBlock(p)
    case .leftBracket:
        contentBlock(p)
    case .leftParen:
        exprWithParen(p, atomic: atomic)
    case .dollar:
        equation(p)
    case .let:
        letBinding(p)
    case .set:
        setRule(p)
    case .show:
        showRule(p)
    case .context:
        contextual(p, atomic: atomic)
    case .if:
        conditional(p)
    case .while:
        whileLoop(p)
    case .for:
        forLoop(p)
    case .import:
        moduleImport(p)
    case .include:
        moduleInclude(p)
    case .break:
        breakStmt(p)
    case .continue:
        continueStmt(p)
    case .return:
        returnStmt(p)

    case .raw:
        p.eat() // Raw is handled entirely in the Lexer.

    case .none, .auto, .int, .float, .bool, .numeric, .str, .label:
        p.eat()

    // Consume erroneous tokens for things like `#12p`, `#]`, or `#"abc\"`.
    default:
        if atomic {
            p.unexpected()
        } else {
            p.expected("expression")
        }
    }
}

/// Reparses a full content or code block.
func reparseBlock(_ text: String, range: Range<Int>) -> SyntaxNode? {
    let p = Parser(text: text, offset: range.lowerBound, mode: .code)
    precondition(p.at(.leftBracket) || p.at(.leftBrace))
    block(p)
    guard p.balanced && p.prevEnd() == range.upperBound else { return nil }
    return p.finish().first
}

/// Parses a content or code block.
private func block(_ p: Parser) {
    switch p.current() {
    case .leftBracket:
        contentBlock(p)
    case .leftBrace:
        codeBlock(p)
    default:
        p.expected("block")
    }
}

/// Parses a code block: `{ let x = 1; x + 2 }`.
private func codeBlock(_ p: Parser) {
    let m = p.marker()
    p.enterModes(.code, .continue) {
        p.assert(.leftBrace)
        code(p, stopSet: SyntaxSet(.rightBrace, .rightBracket, .rightParen, .end))
        _ = p.expectClosingDelimiter(m, kind: .rightBrace)
    }
    p.wrap(m, kind: .codeBlock)
}

/// Parses a content block: `[*Hi* there!]`.
private func contentBlock(_ p: Parser) {
    let m = p.marker()
    p.enterModes(.markup, .continue) {
        p.assert(.leftBracket)
        markup(p, atStart: true, wrapTrivia: true,
               stopSet: SyntaxSet(.rightBracket, .end))
        _ = p.expectClosingDelimiter(m, kind: .rightBracket)
    }
    p.wrap(m, kind: .contentBlock)
}

/// Parses a let binding: `let x = 1`.
private func letBinding(_ p: Parser) {
    let m = p.marker()
    p.assert(.let)

    let m2 = p.marker()
    var closure = false
    var other = false

    if p.eatIf(.ident) {
        if p.directlyAt(.leftParen) {
            params(p)
            closure = true
        }
    } else {
        var seen = Set<String>()
        pattern(p, reassignment: false, seen: &seen, dupe: nil)
        other = true
    }

    let hadEq: Bool
    if closure || other {
        hadEq = p.expect(.eq)
    } else {
        hadEq = p.eatIf(.eq)
    }
    if hadEq {
        codeExpr(p)
    }

    if closure {
        p.wrap(m2, kind: .closure)
    }

    p.wrap(m, kind: .letBinding)
}

/// Parses a set rule: `set text(...)`.
private func setRule(_ p: Parser) {
    let m = p.marker()
    p.assert(.set)

    let m2 = p.marker()
    p.expect(.ident)
    while p.eatIf(.dot) {
        p.expect(.ident)
        p.wrap(m2, kind: .fieldAccess)
    }

    args(p)
    if p.eatIf(.if) {
        codeExpr(p)
    }
    p.wrap(m, kind: .setRule)
}

/// Parses a show rule: `show heading: it => emph(it.body)`.
private func showRule(_ p: Parser) {
    let m = p.marker()
    p.assert(.show)
    let m2 = p.beforeTrivia()

    if !p.at(.colon) {
        codeExpr(p)
    }

    if p.eatIf(.colon) {
        codeExpr(p)
    } else {
        p.expectedAt(m2, "colon")
    }

    p.wrap(m, kind: .showRule)
}

/// Parses a contextual expression: `context text.lang`.
private func contextual(_ p: Parser, atomic: Bool) {
    let m = p.marker()
    p.assert(.context)
    codeExprPrec(p, atomic: atomic, minPrec: 0)
    p.wrap(m, kind: .contextual)
}

/// Parses an if-else conditional: `if x { y } else { z }`.
private func conditional(_ p: Parser) {
    let m = p.marker()
    p.assert(.if)
    codeExpr(p)
    block(p)
    if p.eatIf(.else) {
        if p.at(.if) {
            conditional(p)
        } else {
            block(p)
        }
    }
    p.wrap(m, kind: .conditional)
}

/// Parses a while loop: `while x { y }`.
private func whileLoop(_ p: Parser) {
    let m = p.marker()
    p.assert(.while)
    codeExpr(p)
    block(p)
    p.wrap(m, kind: .whileLoop)
}

/// Parses a for loop: `for x in y { z }`.
private func forLoop(_ p: Parser) {
    let m = p.marker()
    p.assert(.for)

    var seen = Set<String>()
    pattern(p, reassignment: false, seen: &seen, dupe: nil)

    if p.at(.comma) {
        let node = p.eatAndGet()
        node.unexpected()
        node.hint("destructuring patterns must be wrapped in parentheses")
        if p.atSet(.pattern) {
            pattern(p, reassignment: false, seen: &seen, dupe: nil)
        }
    }

    p.expect(.in)
    codeExpr(p)
    block(p)
    p.wrap(m, kind: .forLoop)
}

/// Parses a module import: `import "utils.typ": a, b, c`.
private func moduleImport(_ p: Parser) {
    let m = p.marker()
    p.assert(.import)
    codeExpr(p)
    if p.eatIf(.as) {
        // Allow renaming a full module import.
        p.expect(.ident)
    }

    if p.eatIf(.colon) {
        if p.at(.leftParen) {
            p.withNlMode(.continue) {
                let m2 = p.marker()
                p.assert(.leftParen)

                importItems(p)

                _ = p.expectClosingDelimiter(m2, kind: .rightParen)
            }
        } else if !p.eatIf(.star) {
            importItems(p)
        }
    }

    p.wrap(m, kind: .moduleImport)
}

/// Parses items to import from a module: `a, b, c`.
private func importItems(_ p: Parser) {
    let m = p.marker()
    while !p.current().isTerminator {
        let itemMarker = p.marker()
        if !p.eatIf(.ident) {
            p.unexpected()
        }

        // Nested import path: `a.b.c`
        while p.eatIf(.dot) {
            p.expect(.ident)
        }

        p.wrap(itemMarker, kind: .importItemPath)

        // Rename imported item.
        if p.eatIf(.as) {
            p.expect(.ident)
            p.wrap(itemMarker, kind: .renamedImportItem)
        }

        if !p.current().isTerminator {
            p.expect(.comma)
        }
    }

    p.wrap(m, kind: .importItems)
}

/// Parses a module include: `include "chapter1.typ"`.
private func moduleInclude(_ p: Parser) {
    let m = p.marker()
    p.assert(.include)
    codeExpr(p)
    p.wrap(m, kind: .moduleInclude)
}

/// Parses a break from a loop: `break`.
private func breakStmt(_ p: Parser) {
    let m = p.marker()
    p.assert(.break)
    p.wrap(m, kind: .loopBreak)
}

/// Parses a continue in a loop: `continue`.
private func continueStmt(_ p: Parser) {
    let m = p.marker()
    p.assert(.continue)
    p.wrap(m, kind: .loopContinue)
}

/// Parses a return from a function: `return`, `return x + 1`.
private func returnStmt(_ p: Parser) {
    let m = p.marker()
    p.assert(.return)
    if p.atSet(.codeExpr) {
        codeExpr(p)
    }
    p.wrap(m, kind: .funcReturn)
}

/// An expression that starts with a parenthesis.
private func exprWithParen(_ p: Parser, atomic: Bool) {
    if atomic {
        // Atomic expressions aren't modified by operators that follow them.
        _ = parenthesizedOrArrayOrDict(p)
        return
    }

    // If we've seen this position before and have a memoized result, restore
    // it and return. Otherwise, get a key and a checkpoint to restart from.
    guard let (memoKey, checkpoint) = p.restoreMemoOrCheckpoint() else { return }
    // The node length from when we restored.
    let prevLen = checkpoint.nodeLen

    // When we reach a '(', we can't be sure what it is.
    let kind = parenthesizedOrArrayOrDict(p)

    // If, however, '=>' or '=' follows, we must backtrack and reparse.
    if p.at(.arrow) {
        p.restore(checkpoint)
        let m = p.marker()
        params(p)
        if !p.expect(.arrow) {
            return
        }
        codeExpr(p)
        p.wrap(m, kind: .closure)
    } else if p.at(.eq) && kind != .parenthesized {
        p.restore(checkpoint)
        let m = p.marker()
        var seen = Set<String>()
        destructuringOrParenthesized(p, reassignment: true, seen: &seen)
        if !p.expect(.eq) {
            return
        }
        codeExpr(p)
        p.wrap(m, kind: .destructAssignment)
    } else {
        return
    }

    // Memoize result if we backtracked.
    p.memoizeParsedNodes(memoKey, prevLen: prevLen)
}

/// Parses either a parenthesized expression, an array, or a dictionary.
@discardableResult
private func parenthesizedOrArrayOrDict(_ p: Parser) -> SyntaxKind {
    var state = GroupState()

    // An edge case with parens is whether we can interpret a leading spread
    // expression as a dictionary.
    let m = p.marker()
    p.withNlMode(.continue) {
        p.assert(.leftParen)
        if p.eatIf(.colon) {
            state.kind = .dict
        }

        while !p.current().isTerminator {
            if !p.atSet(.arrayOrDictItem) {
                p.unexpected()
                continue
            }

            arrayOrDictItem(p, state: &state)
            state.count += 1

            if !p.current().isTerminator && p.expect(.comma) {
                state.maybeJustParens = false
            }
        }

        _ = p.expectClosingDelimiter(m, kind: .rightParen)
    }

    let kind = state.maybeJustParens && state.count == 1
        ? SyntaxKind.parenthesized
        : (state.kind ?? .array)

    p.wrap(m, kind: kind)
    return kind
}

/// State for array/dictionary parsing.
private struct GroupState {
    var count = 0
    /// Whether this is just a single expression in parens: `(a)`.
    var maybeJustParens = true
    /// The `SyntaxKind` to wrap as (if we've figured it out yet).
    var kind: SyntaxKind? = nil
    /// Store named arguments so we can give an error if they're repeated.
    var seen = Set<String>()
}

/// Parses a single item in an array or dictionary.
private func arrayOrDictItem(_ p: Parser, state: inout GroupState) {
    let m = p.marker()

    if p.eatIf(.dots) {
        // Parses a spread item: `..item`.
        codeExpr(p)
        p.wrap(m, kind: .spread)
        state.maybeJustParens = false
        return
    }

    codeExpr(p)

    if p.eatIf(.colon) {
        // Parses a named/keyed pair: `name: item` or `"key": item`.
        codeExpr(p)

        let node = p[m]
        let pairKind: SyntaxKind = node.kind == .ident ? .named : .keyed

        if let key = exprKey(node), !state.seen.insert(key).inserted {
            node.convertToError("duplicate key: \(key)")
        }

        p.wrap(m, kind: pairKind)
        state.maybeJustParens = false

        if state.kind == .array {
            p[m].expected("expression")
        } else {
            state.kind = .dict
        }
    } else {
        // Parses a positional item.
        if state.kind == .dict {
            p[m].expected("named or keyed pair")
        } else {
            state.kind = .array
        }
    }
}

/// Extracts the dictionary key text from an identifier or string expression
/// node, mirroring `ast::Expr` matching in the Rust parser.
private func exprKey(_ node: SyntaxNode) -> String? {
    switch node.kind {
    case .ident:
        return node.leafText
    case .str:
        let text = node.leafText
        guard text.count >= 2 else { return nil }
        return unescapeTypstString(String(text.dropFirst().dropLast()))
    default:
        return nil
    }
}

/// Parses a function call's argument list: `(12pt, y)`.
private func args(_ p: Parser) {
    if !p.directlyAt(.leftParen) && !p.directlyAt(.leftBracket) {
        p.expected("argument list")
        if p.at(.leftParen) || p.at(.leftBracket) {
            p.hint("there may not be any spaces before the argument list")
        }
    }

    let m = p.marker()
    if p.at(.leftParen) {
        let m2 = p.marker()
        p.withNlMode(.continue) {
            p.assert(.leftParen)

            var seen = Set<String>()
            while !p.current().isTerminator {
                if !p.atSet(.arg) {
                    p.unexpected()
                    continue
                }

                arg(p, seen: &seen)

                if !p.current().isTerminator {
                    p.expect(.comma)
                }
            }

            _ = p.expectClosingDelimiter(m2, kind: .rightParen)
        }
    }

    while p.directlyAt(.leftBracket) {
        contentBlock(p)
    }

    p.wrap(m, kind: .args)
}

/// Parses a single argument in an argument list.
private func arg(_ p: Parser, seen: inout Set<String>) {
    let m = p.marker()

    // Parses a spread argument: `..args`.
    if p.eatIf(.dots) {
        codeExpr(p)
        p.wrap(m, kind: .spread)
        return
    }

    // Parses a normal positional argument or an argument name.
    let wasAtExpr = p.atSet(.codeExpr)
    let text = p.currentText()
    codeExpr(p)

    // Parses a named argument: `thickness: 12pt`.
    if p.eatIf(.colon) {
        // Recover from bad argument name.
        if wasAtExpr {
            if p[m].kind != .ident {
                p[m].expected("identifier")
            } else if !seen.insert(text).inserted {
                p[m].convertToError("duplicate argument: \(text)")
            }
        }

        codeExpr(p)
        p.wrap(m, kind: .named)
    }
}

/// Parses a closure's parameters: `(x, y)`.
private func params(_ p: Parser) {
    let m = p.marker()
    p.withNlMode(.continue) {
        p.assert(.leftParen)

        var seen = Set<String>()
        var sink = false

        while !p.current().isTerminator {
            if !p.atSet(.param) {
                p.unexpected()
                continue
            }

            param(p, seen: &seen, sink: &sink)

            if !p.current().isTerminator {
                p.expect(.comma)
            }
        }

        _ = p.expectClosingDelimiter(m, kind: .rightParen)
    }
    p.wrap(m, kind: .params)
}

/// Parses a single parameter in a parameter list.
private func param(_ p: Parser, seen: inout Set<String>, sink: inout Bool) {
    let m = p.marker()

    // Parses argument sink: `..sink`.
    if p.eatIf(.dots) {
        if p.atSet(.patternLeaf) {
            patternLeaf(p, reassignment: false, seen: &seen, dupe: "parameter")
        }
        p.wrap(m, kind: .spread)
        let hadSink = sink
        sink = true
        if hadSink {
            p[m].convertToError("only one argument sink is allowed")
        }
        return
    }

    // Parses a normal positional parameter or a parameter name.
    let wasAtPat = p.atSet(.pattern)
    pattern(p, reassignment: false, seen: &seen, dupe: "parameter")

    // Parses a named parameter: `thickness: 12pt`.
    if p.eatIf(.colon) {
        // Recover from bad parameter name.
        if wasAtPat && p[m].kind != .ident {
            p[m].expected("identifier")
        }

        codeExpr(p)
        p.wrap(m, kind: .named)
    }
}

/// Parses a binding or reassignment pattern.
private func pattern(
    _ p: Parser, reassignment: Bool, seen: inout Set<String>, dupe: String?
) {
    guard p.increaseDepth() else { return }
    defer { p.depth -= 1 }

    switch p.current() {
    case .underscore:
        p.eat()
    case .leftParen:
        destructuringOrParenthesized(p, reassignment: reassignment, seen: &seen)
    default:
        patternLeaf(p, reassignment: reassignment, seen: &seen, dupe: dupe)
    }
}

/// Parses a destructuring pattern or just a parenthesized pattern.
private func destructuringOrParenthesized(
    _ p: Parser, reassignment: Bool, seen: inout Set<String>
) {
    var sink = false
    var count = 0
    var maybeJustParens = true

    let m = p.marker()
    p.withNlMode(.continue) {
        p.assert(.leftParen)

        while !p.current().isTerminator {
            if !p.atSet(.destructuringItem) {
                p.unexpected()
                continue
            }

            destructuringItem(p, reassignment: reassignment, seen: &seen,
                              maybeJustParens: &maybeJustParens, sink: &sink)
            count += 1

            if !p.current().isTerminator && p.expect(.comma) {
                maybeJustParens = false
            }
        }

        _ = p.expectClosingDelimiter(m, kind: .rightParen)
    }

    if maybeJustParens && count == 1 && !sink {
        p.wrap(m, kind: .parenthesized)
    } else {
        p.wrap(m, kind: .destructuring)
    }
}

/// Parses an item in a destructuring pattern.
private func destructuringItem(
    _ p: Parser, reassignment: Bool, seen: inout Set<String>,
    maybeJustParens: inout Bool, sink: inout Bool
) {
    let m = p.marker()

    // Parse destructuring sink: `..rest`.
    if p.eatIf(.dots) {
        if p.atSet(.patternLeaf) {
            patternLeaf(p, reassignment: reassignment, seen: &seen, dupe: nil)
        }
        p.wrap(m, kind: .spread)
        let hadSink = sink
        sink = true
        if hadSink {
            p[m].convertToError("only one destructuring sink is allowed")
        }
        return
    }

    // Parse a normal positional pattern or a destructuring key.
    let wasAtPat = p.atSet(.pattern)

    // We must use a full checkpoint here because there may be trivia between
    // the identifier and the colon we need to skip.
    let checkpoint = p.checkpoint()
    if !(p.eatIf(.ident) && p.at(.colon)) {
        p.restore(checkpoint)
        pattern(p, reassignment: reassignment, seen: &seen, dupe: nil)
    }

    // Parse named destructuring item.
    if p.eatIf(.colon) {
        // Recover from bad named destructuring.
        if wasAtPat && p[m].kind != .ident {
            p[m].expected("identifier")
        }

        pattern(p, reassignment: reassignment, seen: &seen, dupe: nil)
        p.wrap(m, kind: .named)
        maybeJustParens = false
    }
}

/// Parses a leaf in a pattern - either an identifier or an expression
/// depending on whether it's a binding or reassignment pattern.
private func patternLeaf(
    _ p: Parser, reassignment: Bool, seen: inout Set<String>, dupe: String?
) {
    if p.current().isKeyword {
        p.eatAndGet().expected("pattern")
        return
    } else if !p.atSet(.patternLeaf) {
        p.expected("pattern")
        return
    }

    let m = p.marker()
    let text = p.currentText()

    // We parse an atomic expression even though we only want an identifier for
    // better error recovery.
    codeExprPrec(p, atomic: true, minPrec: 0)

    if !reassignment {
        let node = p[m]
        if node.kind == .ident {
            if !seen.insert(text).inserted {
                node.convertToError(
                    "duplicate \(dupe ?? "binding"): \(text)"
                )
            }
        } else {
            node.expected("pattern")
        }
    }
}

// MARK: - Parser state

/// How to proceed with parsing when at a newline.
enum AtNewline: Sendable, Hashable {
    /// Continue at newlines.
    case `continue`
    /// Stop at any newline.
    case stop
    /// Continue only if there is a continuation with `else` or `.` (Code only).
    case contextualContinue
    /// Stop only at a parbreak, not normal newlines (Markup only).
    case stopParBreak
    /// Require that the token's column be greater or equal to a column.
    case requireColumn(Int)

    /// Whether to stop at a newline or continue based on the current context.
    func stopAt(_ newline: Newline, kind: SyntaxKind) -> Bool {
        switch self {
        case .continue:
            return false
        case .stop:
            return true
        case .contextualContinue:
            switch kind {
            case .else, .dot: return false
            default: return true
            }
        case .stopParBreak:
            return newline.parbreak
        case .requireColumn(let minCol):
            // When the column is `nil`, the newline doesn't start a column,
            // and we continue parsing.
            return newline.column.map { $0 <= minCol } ?? false
        }
    }
}

/// Information about newlines in a group of trivia.
struct Newline {
    /// The column of the start of the next token in its line.
    var column: Int?
    /// Whether any of our newlines were paragraph breaks.
    var parbreak: Bool
}

/// A marker representing a node's position in the parser.
struct Marker: Equatable {
    var index: Int
}

/// A single token returned from the lexer with a cached `SyntaxKind` and a
/// record of preceding trivia.
struct Token {
    /// The `SyntaxKind` of the current token.
    var kind: SyntaxKind
    /// The `SyntaxNode` of the current token.
    var node: SyntaxNode
    /// The number of preceding trivia before this token.
    var nTrivia: Int
    /// Whether this token's preceding trivia contained a newline.
    var newline: Newline?
    /// The index into the text of the start of our current token.
    var start: Int
    /// The index into the text of the end of the previous token.
    var prevEnd: Int
}

/// Extra parser state for efficiently recovering from mispredicted parses.
/// Same idea as packrat parsing, used only for parenthesized structures.
final class MemoArena {
    /// A single arena of previously parsed nodes.
    var arena: [SyntaxNode] = []
    /// A map from the parser's current position to a range of previously
    /// parsed nodes in the arena and a checkpoint of the parser's state.
    var memoMap: [Int: (range: Range<Int>, state: PartialState)] = [:]
}

/// A checkpoint of the parser which can fully restore it to a previous state.
struct Checkpoint {
    var nodeLen: Int
    var state: PartialState
}

/// State needed to restore the parser's current token and the lexer (but not
/// the nodes vector).
struct PartialState {
    var cursor: Int
    var lexMode: SyntaxMode
    var token: Token
}

/// Manages parsing a stream of tokens into a tree of `SyntaxNode`s.
/// Port of `Parser` in `typst-syntax/src/parser.rs`.
final class Parser {
    /// The source text shared with the lexer.
    let text: String
    /// A lexer over the source text with multiple modes.
    var lexer: Lexer
    /// The newline mode: whether to insert a temporary end at newlines.
    var nlMode: AtNewline
    /// The current token under inspection, not yet present in `nodes`.
    var token: Token
    /// Whether the parser has the expected set of open/close delimiters.
    var balanced = true
    /// Nodes representing the concrete syntax tree of previously parsed text.
    var nodes: [SyntaxNode] = []
    /// Parser checkpoints for a given text index.
    let memo = MemoArena()
    /// The current expression nesting depth.
    var depth = 0

    init(text: String, offset: Int, mode: SyntaxMode) {
        var lexer = Lexer(text: text, mode: mode)
        lexer.jump(offset)
        var parsed: [SyntaxNode] = []
        let token = Parser.lex(&parsed, &lexer, .continue)
        self.text = text
        self.lexer = lexer
        self.nlMode = .continue
        self.token = token
        self.nodes = parsed
    }

    /// Consume the parser, yielding the full vector of parsed nodes.
    func finish() -> [SyntaxNode] {
        nodes
    }

    /// Consume the parser, generating a single top-level node.
    func finishInto(_ kind: SyntaxKind) -> SyntaxNode {
        precondition(at(.end))
        return SyntaxNode.inner(kind, nodes)
    }

    // MARK: Token inspection

    /// The `SyntaxKind` of the next token to be eaten.
    func current() -> SyntaxKind { token.kind }

    /// Whether the current token is a given `SyntaxKind`.
    func at(_ kind: SyntaxKind) -> Bool { token.kind == kind }

    /// Whether the current token is contained in a `SyntaxSet`.
    func atSet(_ set: SyntaxSet) -> Bool { set.contains(token.kind) }

    /// Whether we're at the end of the token stream.
    func end() -> Bool { at(.end) }

    /// If we're at the given `kind` with no preceding trivia tokens.
    func directlyAt(_ kind: SyntaxKind) -> Bool {
        token.kind == kind && !hadTrivia()
    }

    /// Whether `token` had any preceding trivia.
    func hadTrivia() -> Bool { token.nTrivia > 0 }

    /// Whether `token` had a newline among any of its preceding trivia.
    func hadNewline() -> Bool { token.newline != nil }

    /// The number of characters until the most recent newline from the start
    /// of the current token.
    func currentColumn() -> Int {
        if let column = token.newline?.column {
            return column
        }
        return lexer.column(token.start)
    }

    /// The current token's text.
    func currentText() -> String {
        slice(token.start..<lexer.cursor)
    }

    /// The offset into the text of the current token's start.
    func currentStart() -> Int { token.start }

    /// The offset into the text of the previous token's end.
    func prevEnd() -> Int { token.prevEnd }

    /// Extract a byte range of the source text as a String.
    private func slice(_ range: Range<Int>) -> String {
        String(decoding: lexer.s.bytes[range], as: UTF8.self)
    }

    // MARK: Markers and eating

    /// A marker that will point to the current token in the parser once it's
    /// been eaten.
    func marker() -> Marker { Marker(index: nodes.count) }

    /// A marker that will point to first trivia before this token in the
    /// parser (or the token itself if no trivia precede it).
    func beforeTrivia() -> Marker { Marker(index: nodes.count - token.nTrivia) }

    subscript(m: Marker) -> SyntaxNode { nodes[m.index] }

    /// Eat the current node and return it for in-place mutation.
    @discardableResult
    func eatAndGet() -> SyntaxNode {
        let offset = nodes.count
        eat()
        return nodes[offset]
    }

    /// Eat the token if at `kind`. Returns `true` if eaten.
    @discardableResult
    func eatIf(_ kind: SyntaxKind) -> Bool {
        let at = self.at(kind)
        if at {
            eat()
        }
        return at
    }

    /// Assert that we are at the given `SyntaxKind` and eat it.
    func assert(_ kind: SyntaxKind) {
        precondition(token.kind == kind)
        eat()
    }

    /// Convert the current token's `SyntaxKind` and eat it.
    func convertAndEat(_ kind: SyntaxKind) {
        token.node.convertToKind(kind)
        eat()
    }

    /// Eat the current token by saving it to the `nodes` vector, then move
    /// the lexer forward to prepare a new token.
    func eat() {
        nodes.append(token.node)
        token = Parser.lex(&nodes, &lexer, nlMode)
    }

    /// Detach the parsed trivia nodes from this token so that subsequent
    /// wrapping will include the trivia.
    func flushTrivia() {
        token.nTrivia = 0
        token.prevEnd = token.start
    }

    /// Wrap the nodes from a marker up to (but excluding) the current token in
    /// a new inner node of the given kind.
    func wrap(_ from: Marker, kind: SyntaxKind) {
        let to = beforeTrivia().index
        let from = min(from.index, to)
        let children = Array(nodes[from..<to])
        nodes.replaceSubrange(from..<to, with: [SyntaxNode.inner(kind, children)])
    }

    /// Wrap the nodes from a marker up to (but excluding) the current token in
    /// a new error node with the given message.
    func wrapError(_ from: Marker, _ message: String) {
        let to = beforeTrivia().index
        let from = min(from.index, to)
        let len = nodes[from..<to].reduce(0) { $0 + $1.len }
        let end = token.prevEnd
        let start = max(0, end - len)
        nodes.replaceSubrange(
            from..<to,
            with: [SyntaxNode.error(message, slice(start..<end))]
        )
    }

    /// Parse within the `SyntaxMode` for subsequent tokens.
    func enterModes(_ mode: SyntaxMode, _ stop: AtNewline, _ body: () -> Void) {
        let previous = lexer.mode
        lexer.mode = mode
        withNlMode(stop, body)
        if mode != previous {
            lexer.mode = previous
            lexer.jump(token.prevEnd)
            nodes.removeLast(token.nTrivia)
            token = Parser.lex(&nodes, &lexer, nlMode)
        }
    }

    /// Parse within the `AtNewline` mode for subsequent tokens.
    func withNlMode(_ mode: AtNewline, _ body: () -> Void) {
        let previous = nlMode
        nlMode = mode
        body()
        nlMode = previous
        if let newline = token.newline, mode != previous {
            // Restore our actual token's kind or insert a fake end.
            let actualKind = token.node.kind
            token.kind = nlMode.stopAt(newline, kind: actualKind) ? .end : actualKind
        }
    }

    /// Move the lexer forward and prepare the current token.
    private static func lex(
        _ nodes: inout [SyntaxNode], _ lexer: inout Lexer, _ nlMode: AtNewline
    ) -> Token {
        let prevEnd = lexer.cursor
        var start = prevEnd
        var (kind, node) = lexer.next()
        var nTrivia = 0
        var spaceWithNewline = false
        var parbreak = false

        while kind.isTrivia {
            spaceWithNewline = spaceWithNewline || kind == .spaceWithNewline
            parbreak = parbreak || kind == .parbreak
            nTrivia += 1
            nodes.append(node)
            start = lexer.cursor
            (kind, node) = lexer.next()
        }

        var newline: Newline? = nil
        if spaceWithNewline || parbreak {
            let column = lexer.mode == .markup ? lexer.column(start) : nil
            let nl = Newline(column: column, parbreak: parbreak)
            if nlMode.stopAt(nl, kind: kind) {
                // Insert a temporary `End` to halt the parser. The actual kind
                // will be restored from `node` later.
                kind = .end
            }
            newline = nl
        }

        return Token(
            kind: kind, node: node, nTrivia: nTrivia,
            newline: newline, start: start, prevEnd: prevEnd
        )
    }
}

// MARK: - Memoization

extension Parser {
    /// Store the already parsed nodes and the parser state into the memo map.
    func memoizeParsedNodes(_ key: Int, prevLen: Int) {
        let checkpoint = self.checkpoint()
        let memoStart = memo.arena.count
        memo.arena.append(contentsOf: nodes[prevLen..<checkpoint.nodeLen])
        let arenaRange = memoStart..<memo.arena.count
        memo.memoMap[key] = (arenaRange, checkpoint.state)
    }

    /// Try to load a memoized result.
    func restoreMemoOrCheckpoint() -> (key: Int, checkpoint: Checkpoint)? {
        // We use the starting index of the current token as our key.
        let key = currentStart()
        if let (range, state) = memo.memoMap[key] {
            nodes.append(contentsOf: memo.arena[range])
            // It's important that we don't truncate the nodes vector since it
            // may have grown or shrunk since we made this checkpoint.
            restorePartial(state)
            return nil
        }
        return (key, checkpoint())
    }

    /// Restore the parser to the state at a checkpoint.
    func restore(_ checkpoint: Checkpoint) {
        nodes.removeSubrange(checkpoint.nodeLen..<nodes.count)
        restorePartial(checkpoint.state)
    }

    /// Restore parts of the checkpoint excluding the nodes vector.
    private func restorePartial(_ state: PartialState) {
        lexer.jump(state.cursor)
        lexer.mode = state.lexMode
        token = state.token
    }

    /// Save a checkpoint of the parser state.
    func checkpoint() -> Checkpoint {
        Checkpoint(
            nodeLen: nodes.count,
            state: PartialState(
                cursor: lexer.cursor, lexMode: lexer.mode, token: token
            )
        )
    }
}

// MARK: - Error recovery

extension Parser {
    /// Consume the given `kind` or produce an error.
    @discardableResult
    func expect(_ kind: SyntaxKind) -> Bool {
        let at = self.at(kind)
        if at {
            eat()
        } else if kind == .ident && token.kind.isKeyword {
            trimErrors()
            eatAndGet().expected(kind.name)
        } else {
            balanced = balanced && !kind.isGrouping
            expected(kind.name)
        }
        return at
    }

    /// Consume the given closing delimiter or produce an error for the
    /// matching opening delimiter at `open`.
    @discardableResult
    func expectClosingDelimiter(_ open: Marker, kind: SyntaxKind) -> Bool {
        let at = eatIf(kind)
        if !at {
            nodes[open.index].convertToError("unclosed delimiter")
        }
        return at
    }

    /// Produce an error that the given `thing` was expected.
    func expected(_ thing: String) {
        if token.kind.isError {
            // If we encounter an erroneous token when something was expected,
            // we need to actually consume the token.
            trimErrors()
            eat()
        } else if !afterError() {
            expectedAt(beforeTrivia(), thing)
        }
    }

    /// Whether the last non-trivia node is an error.
    private func afterError() -> Bool {
        let m = beforeTrivia()
        return m.index > 0 && nodes[m.index - 1].kind.isError
    }

    /// Produce an error that the given `thing` was expected at the position
    /// of the marker `m`.
    func expectedAt(_ m: Marker, _ thing: String) {
        nodes.insert(SyntaxNode.error("expected \(thing)", ""), at: m.index)
    }

    /// Add a hint to a trailing error.
    func hint(_ hint: String) {
        let m = beforeTrivia()
        if m.index > 0 {
            nodes[m.index - 1].hint(hint)
        }
    }

    /// Consume the next token (if any) and produce an error stating that it
    /// was unexpected.
    func unexpected() {
        trimErrors()
        balanced = balanced && !token.kind.isGrouping
        eatAndGet().unexpected()
    }

    /// Remove trailing errors with zero length.
    private func trimErrors() {
        let end = beforeTrivia().index
        var start = end
        while start > 0
            && nodes[start - 1].kind.isError
            && nodes[start - 1].isEmpty
        {
            start -= 1
        }
        nodes.removeSubrange(start..<end)
    }

    /// Check if the maximum depth has been exceeded.
    func checkDepthUntil(_ stopSet: SyntaxSet) -> Bool {
        if depth < maxDepth {
            return true
        }
        depthCheckError(stopSet: stopSet)
        return false
    }

    /// Check if the maximum depth has been exceeded, increasing the depth
    /// otherwise. Pair with `defer { p.depth -= 1 }`.
    func increaseDepth() -> Bool {
        if depth < maxDepth {
            depth += 1
            return true
        }
        depthCheckError(stopSet: nil)
        return false
    }

    /// Generate an error for an exceeded maximum depth check.
    private func depthCheckError(stopSet: SyntaxSet?) {
        let m = marker()

        var balance = 0
        // This function has to guarantee some sort of forward progress.
        withNlMode(.continue) {
            while true {
                // We don't need to add `MathOpening/MathClosing` since they
                // don't actually contribute to delimiter balance.
                if atSet(SyntaxSet(.leftBracket, .leftBrace, .leftParen)) {
                    balance += 1
                } else if atSet(SyntaxSet(.rightBracket, .rightBrace, .rightParen)) {
                    balance -= 1
                }
                eat()

                let atStop = stopSet.map { atSet($0) } ?? true
                if (balance == 0 && atStop) || end() {
                    break
                }
            }
        }

        wrapError(m, "maximum parsing depth exceeded")
    }
}

