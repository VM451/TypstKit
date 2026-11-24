import Foundation
import TypstUtils

/// An iterator over source text producing syntax tokens.
/// Port of `typst-syntax/src/lexer.rs`.
struct Lexer {
    /// The scanner over the source text.
    var s: Scanner
    /// The mode the lexer is in.
    var mode: SyntaxMode
    /// An error plus hints for the current token, `nil` between `next` calls.
    private var error: (message: String, hints: [String])?

    init(text: String, mode: SyntaxMode) {
        self.s = Scanner(text)
        self.mode = mode
        self.error = nil
    }

    /// The index at which the last token ends and the next will start.
    var cursor: Int { s.cursor }

    /// Jump to a byte index.
    mutating func jump(_ index: Int) { s.jump(index) }

    /// The number of characters until the most recent newline from an index.
    /// Port of `Lexer::column`.
    func column(_ index: Int) -> Int {
        // Fast path: scan back to the nearest ASCII newline byte.
        var j = min(index, s.bytes.count)
        while j > 0 {
            let b = s.bytes[j - 1]
            if b == 0x0A || b == 0x0D { break }
            j -= 1
        }
        // Count scalars, resetting at any (possibly multi-byte) newline.
        var count = 0
        let segment = String(decoding: s.bytes[j..<min(index, s.bytes.count)], as: UTF8.self)
        for scalar in segment.unicodeScalars {
            if isNewline(scalar) {
                count = 0
            } else {
                count += 1
            }
        }
        return count
    }

    /// Construct a full-positioned syntax error token.
    private mutating func error(_ message: String) -> SyntaxKind {
        error = (message, [])
        return .error
    }

    /// If the current token is an error, add a hint.
    private mutating func hint(_ message: String) {
        error?.hints.append(message)
    }

    /// Return the next token: its kind and node.
    mutating func next() -> (SyntaxKind, SyntaxNode) {
        error = nil
        let start = s.cursor

        guard let c = s.eat() else {
            return (.end, SyntaxNode.leaf(.end, ""))
        }

        let kind: SyntaxKind
        var node: SyntaxNode? = nil

        if isSpace(c, mode: mode) {
            kind = whitespace(start: start, c: c)
        } else if c == "#" && start == 0 && s.eatIf("!") {
            kind = shebang()
        } else if c == "/" && s.eatIf("/") {
            kind = lineComment()
        } else if c == "/" && s.eatIf("*") {
            kind = blockComment()
        } else if c == "*" && s.eatIf("/") {
            kind = error("unexpected end of block comment")
            hint("consider escaping the `*` with a backslash or opening the block comment with `/*`")
        } else if c == "`" && mode != .math {
            return raw()
        } else {
            switch mode {
            case .markup: kind = markup(start: start, c: c)
            case .math:
                let (k, n) = math(start: start, c: c)
                kind = k
                node = n
            case .code: kind = code(start: start, c: c)
            }
        }

        if let node { return (kind, node) }

        let text = s.from(start)
        let result: SyntaxNode
        if let e = error {
            result = SyntaxNode.error(e.message, text).withHints(e.hints)
        } else {
            result = SyntaxNode.leaf(kind, text)
        }
        return (kind, result)
    }

    /// Eat whitespace greedily.
    private mutating func whitespace(start: Int, c: Unicode.Scalar) -> SyntaxKind {
        let m = mode
        let more = s.eatWhile { isSpace($0, mode: m) }
        let newlines: Int
        if c == " " && more.isEmpty {
            newlines = 0
        } else {
            newlines = countNewlines(s.from(start))
        }

        if mode == .markup && newlines >= 2 {
            return .parbreak
        } else if newlines > 0 {
            return .spaceWithNewline
        } else {
            return .spaceNoNewline
        }
    }

    private mutating func shebang() -> SyntaxKind {
        _ = s.eatUntil { isNewline($0) }
        return .shebang
    }

    private mutating func lineComment() -> SyntaxKind {
        _ = s.eatUntil { isNewline($0) }
        return .lineComment
    }

    private mutating func blockComment() -> SyntaxKind {
        var state: Unicode.Scalar = "_"
        var depth = 1

        while let c = s.eat() {
            let next: Unicode.Scalar
            if state == "*" && c == "/" {
                depth -= 1
                if depth == 0 { break }
                next = "_"
            } else if state == "/" && c == "*" {
                depth += 1
                next = "_"
            } else {
                next = c
            }
            state = next
        }
        return .blockComment
    }
}

// MARK: - Raw

extension Lexer {
    /// Parse entire raw segments in the lexer.
    private mutating func raw() -> (SyntaxKind, SyntaxNode) {
        let start = s.cursor - 1

        // Determine number of opening backticks.
        var backticks = 1
        while s.eatIf("`") { backticks += 1 }

        // Special case for ``.
        if backticks == 2 {
            let nodes = [
                SyntaxNode.leaf(.rawDelim, "`"),
                SyntaxNode.leaf(.rawDelim, "`"),
            ]
            return (.raw, SyntaxNode.inner(.raw, nodes))
        }

        // Find end of raw text.
        var found = 0
        while found < backticks {
            guard let c = s.eat() else {
                let error = SyntaxNode.error("unclosed raw text", s.from(start))
                return (.error, error)
            }
            if c == "`" { found += 1 } else { found = 0 }
        }
        let end = s.cursor

        let innerBytes = Array(s.bytes[(start + backticks)..<(end - backticks)])
        var inner = Scanner(bytes: innerBytes)
        let innerLen = inner.length

        // Opening delimiter (text identical to closing run).
        let delim = SyntaxNode.leaf(.rawDelim, s.from(end - backticks))
        var nodes = [delim]

        var tag: String? = nil
        var diffFutureTagLen: Int? = nil
        if delim.leafText.utf8.count >= 3 {
            (tag, diffFutureTagLen) = Self.rawLangTag(&inner)
            if let tag {
                nodes.append(SyntaxNode.leaf(.rawLang, tag))
            }
            Self.blockyRaw(&inner, &nodes)
        } else {
            Self.inlineRaw(&inner, &nodes)
        }

        // Closing delimiter.
        nodes.append(delim)

        let raw = SyntaxNode.inner(.raw, nodes)
        Self.addRawWarnings(raw, backticks: backticks,
                            diffFutureTagLen: diffFutureTagLen, tag: tag,
                            innerLen: innerLen)

        return (.raw, raw)
    }

    /// Lex the raw language tag; also return the length of the future tag if
    /// it will differ in the next version.
    private static func rawLangTag(_ s: inout Scanner) -> (String?, Int?) {
        let start = s.cursor
        let futureTag = s.eatUntil { $0.isTypstWhitespace || $0 == "`" }
        if futureTag.isEmpty {
            return (nil, nil)
        }
        s.jump(start)
        var tag: String? = nil
        if s.eatIf(isIdStart) {
            _ = s.eatWhile(isIdContinue)
            tag = s.from(start)
        }
        let diff = (tag == nil || tag!.utf8.count != futureTag.utf8.count)
            ? futureTag.utf8.count
            : nil
        return (tag, diff)
    }

    /// Raw blocks: language tag, smart whitespace trimming, dedent.
    private static func blockyRaw(_ s: inout Scanner, _ nodes: inout [SyntaxNode]) {
        var lines = splitNewlines(s.after)

        // Determine dedent level.
        var dedent = Int.max
        for line in lines.dropFirst() where !line.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            dedent = min(dedent, leadingWhitespaceCount(line))
        }
        if let last = lines.last {
            dedent = min(dedent, leadingWhitespaceCount(last))
        }
        if dedent == Int.max { dedent = 0 }

        // Trim whitespace from the last line.
        if let last = lines.last,
           last.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            lines.removeLast()
        } else if !lines.isEmpty {
            // If the last line ends in a backtick after trimming, remove a
            // single trailing ascii space.
            var last = lines[lines.count - 1]
            if trimEndWhitespace(last).hasSuffix("`") && last.hasSuffix(" ") {
                last.removeLast()
                lines[lines.count - 1] = last
            }
        }

        var prev = s.cursor
        func pushLeaf(_ kind: SyntaxKind, _ s: inout Scanner,
                      _ nodes: inout [SyntaxNode], _ prev: inout Int) {
            nodes.append(SyntaxNode.leaf(kind, s.from(prev)))
            prev = s.cursor
        }

        var iter = lines.makeIterator()

        // Handle the first line.
        if let firstLine = iter.next() {
            if firstLine.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                s.advance(firstLine.utf8.count)
            } else {
                let lineEnd = s.cursor + firstLine.utf8.count
                if s.eatIf(" ") {
                    pushLeaf(.rawTrimmed, &s, &nodes, &prev)
                }
                s.jump(lineEnd)
                pushLeaf(.text, &s, &nodes, &prev)
            }
        }

        // Add inner lines.
        while let line = iter.next() {
            let offset = byteLengthOfFirstChars(line, dedent)
            _ = s.eatNewline()
            s.advance(offset)
            pushLeaf(.rawTrimmed, &s, &nodes, &prev)
            s.advance(line.utf8.count - offset)
            pushLeaf(.text, &s, &nodes, &prev)
        }

        // Add final trimmed.
        if !s.done {
            nodes.append(SyntaxNode.leaf(.rawTrimmed, s.after))
        }
    }

    /// Inline raw text: non-newline runs as Text, newlines as RawTrimmed.
    private static func inlineRaw(_ s: inout Scanner, _ nodes: inout [SyntaxNode]) {
        var prev = s.cursor
        while !s.done {
            if s.at({ isNewline($0) }) {
                nodes.append(SyntaxNode.leaf(.text, s.from(prev)))
                prev = s.cursor
                _ = s.eatNewline()
                nodes.append(SyntaxNode.leaf(.rawTrimmed, s.from(prev)))
                prev = s.cursor
                continue
            }
            _ = s.eat()
        }
        nodes.append(SyntaxNode.leaf(.text, s.from(prev)))
    }

    /// Warnings for language tags that will differ in the next version.
    private static func addRawWarnings(_ raw: SyntaxNode, backticks: Int,
                                       diffFutureTagLen: Int?, tag: String?,
                                       innerLen: Int) {
        if let futureTagLen = diffFutureTagLen {
            let futureRange = backticks..<(backticks + futureTagLen)
            if let tag {
                raw.warnAt(futureRange, "no whitespace between language tag and raw text")
                raw.hint("currently, Typst is treating `\(tag)` as the language tag")
                raw.hint("in the next version of Typst, this will change and we will treat all text until the first whitespace as the language tag")
                let tagRange = backticks..<(backticks + tag.utf8.count)
                raw.hintAt(tagRange, "if the current behavior is correct, please add a space after `\(tag)`")
                raw.hintAt(tagRange, "otherwise, add a space or newline after the initial backticks")
            } else {
                raw.warnAt(futureRange, "no whitespace before raw text")
                raw.hint("in the next version of Typst, this text will be treated as the language tag for this element")
                raw.hint("to avoid this, add a space after the initial backticks")
            }
        } else if let tag, innerLen == tag.utf8.count {
            raw.warn("empty raw text")
            raw.hint("Typst is treating `\(tag)` as the language tag")
            let tagRange = backticks..<(backticks + tag.utf8.count)
            raw.hintAt(tagRange, "to treat this as text, add a space after the initial backticks")
        }
    }
}

/// Count leading whitespace characters (scalars).
private func leadingWhitespaceCount(_ line: String) -> Int {
    line.unicodeScalars.prefix { $0.properties.isWhitespace }.count
}

/// Byte length of the first `n` characters of `line`.
private func byteLengthOfFirstChars(_ line: String, _ n: Int) -> Int {
    line.unicodeScalars.prefix(n).reduce(0) { $0 + String($1).utf8.count }
}

/// Trim trailing whitespace (Unicode White_Space) from a string.
private func trimEndWhitespace(_ s: String) -> String {
    var scalars = Array(s.unicodeScalars)
    while let last = scalars.last, last.properties.isWhitespace {
        scalars.removeLast()
    }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

// MARK: - Markup

extension Lexer {
    private mutating func markup(start: Int, c: Unicode.Scalar) -> SyntaxKind {
        switch c {
        case "\\": return backslash()
        case "h" where s.eatIf("ttp://") || s.eatIf("ttps://"): return link()
        case "<" where s.at(isIdContinue): return label()
        case "@" where s.at(isIdContinue): return refMarker()

        case "." where s.eatIf(".."): return .shorthand
        case "-" where s.eatIf("--"): return .shorthand
        case "-" where s.eatIf("-"): return .shorthand
        case "-" where s.eatIf("?"): return .shorthand
        case "-" where s.at({ $0.isTypstNumeric }): return .shorthand
        case "*" where !inWord(): return .star
        case "_" where !inWord(): return .underscore

        case "#": return .hash
        case "[": return .leftBracket
        case "]": return .rightBracket
        case "'", "\"": return .smartQuote
        case "$": return .dollar
        case "~": return .shorthand
        case ":": return .colon
        case "=":
            _ = s.eatWhile { $0 == "=" }
            return spaceOrEnd() ? .headingMarker : text()
        case "-" where spaceOrEnd(): return .listMarker
        case "+" where spaceOrEnd(): return .enumMarker
        case "/" where spaceOrEnd(): return .termMarker
        case "0"..."9": return numbering(start: start)

        default: return text()
        }
    }

    private mutating func backslash() -> SyntaxKind {
        if s.eatIf("u{") {
            let hex = s.eatWhile { $0.isASCIIAlphanumeric }
            guard s.eatIf("}") else {
                return error("unclosed Unicode escape sequence")
            }
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                return error("invalid Unicode codepoint: \(hex)")
            }
            _ = scalar
            return .escape
        }

        if s.done || s.at({ $0.isTypstWhitespace }) {
            return .linebreak
        } else {
            _ = s.eat()
            return .escape
        }
    }

    private mutating func link() -> SyntaxKind {
        let (link, balanced) = linkPrefix(s.after)
        s.advance(link.utf8.count)

        if !balanced {
            return error("automatic links cannot contain unbalanced brackets, use the `link` function instead")
        }
        return .link
    }

    private mutating func numbering(start: Int) -> SyntaxKind {
        _ = s.eatWhile { $0.isASCIIDigit }

        let read = s.from(start)
        if s.eatIf(".") && spaceOrEnd() && UInt64(read) != nil {
            return .enumMarker
        }
        return text()
    }

    private mutating func refMarker() -> SyntaxKind {
        _ = s.eatWhile(isValidInLabelLiteral)

        // Don't include trailing characters likely part of text.
        while let c = s.scout(-1), c == "." || c == ":" {
            s.uneat()
        }
        return .refMarker
    }

    private mutating func label() -> SyntaxKind {
        let label = s.eatWhile(isValidInLabelLiteral)
        if label.isEmpty {
            return error("label cannot be empty")
        }
        guard s.eatIf(">") else {
            return error("unclosed label")
        }
        return .label
    }

    private mutating func text() -> SyntaxKind {
        // Characters that terminate a text run (ASCII table + whitespace).
        func isBreak(_ c: Unicode.Scalar) -> Bool {
            switch c {
            case " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\\", "/",
                 "[", "]", "~", "-", ".", "'", "\"", "*", "_",
                 ":", "h", "`", "$", "<", ">", "@", "#":
                return true
            default:
                return c.properties.isWhitespace
            }
        }

        while true {
            _ = s.eatUntil(isBreak)

            // Continue with the same text node if the thing would become
            // text anyway.
            var look = s
            guard let c = look.eat() else { break }
            switch c {
            case " " where look.at({ $0.isTypstAlphanumeric }): break
            case "/" where !(look.at("/") || look.at("*")): break
            case "-" where !(look.at("-") || look.at("?")): break
            case "." where !look.at(".."): break
            case "h" where !look.at("ttp://") && !look.at("ttps://"): break
            case "@" where !look.at(isValidInLabelLiteral): break
            default: return .text
            }
            s = look
        }
        return .text
    }

    /// Whether surrounded by "word" characters (alphanumeric, non-CJK).
    private func inWord() -> Bool {
        func wordy(_ c: Unicode.Scalar?) -> Bool {
            guard let c else { return false }
            return c.isTypstAlphanumeric && !c.isCJKScript
        }
        return wordy(s.scout(-2)) && wordy(s.peek())
    }

    /// Whether at whitespace, end, or a comment start.
    private func spaceOrEnd() -> Bool {
        s.done || s.at({ $0.isTypstWhitespace }) || s.at("//") || s.at("/*")
    }
}

// MARK: - Math

extension Lexer {
    private mutating func math(start: Int, c: Unicode.Scalar) -> (SyntaxKind, SyntaxNode?) {
        let kind: SyntaxKind
        switch c {
        case "\\": kind = backslash()
        case "\"": kind = string()

        // Shorthands (longest-match order matters).
        case "-" where s.eatIf(">>"): kind = .mathShorthand
        case "-" where s.eatIf(">"): kind = .mathShorthand
        case "-" where s.eatIf("->"): kind = .mathShorthand
        case ":" where s.eatIf("="): kind = .mathShorthand
        case ":" where s.eatIf(":="): kind = .mathShorthand
        case "!" where s.eatIf("="): kind = .mathShorthand
        case "." where s.eatIf(".."): kind = .mathShorthand
        case "<" where s.eatIf("==>"): kind = .mathShorthand
        case "<" where s.eatIf("-->"): kind = .mathShorthand
        case "<" where s.eatIf("--"): kind = .mathShorthand
        case "<" where s.eatIf("-<"): kind = .mathShorthand
        case "<" where s.eatIf("->"): kind = .mathShorthand
        case "<" where s.eatIf("<-"): kind = .mathShorthand
        case "<" where s.eatIf("<<"): kind = .mathShorthand
        case "<" where s.eatIf("=>"): kind = .mathShorthand
        case "<" where s.eatIf("=="): kind = .mathShorthand
        case "<" where s.eatIf("~~"): kind = .mathShorthand
        case "<" where s.eatIf("="): kind = .mathShorthand
        case "<" where s.eatIf("<"): kind = .mathShorthand
        case "<" where s.eatIf("-"): kind = .mathShorthand
        case "<" where s.eatIf("~"): kind = .mathShorthand
        case ">" where s.eatIf("->"): kind = .mathShorthand
        case ">" where s.eatIf(">>"): kind = .mathShorthand
        case "=" where s.eatIf("=>"): kind = .mathShorthand
        case "=" where s.eatIf(">"): kind = .mathShorthand
        case "=" where s.eatIf(":"): kind = .mathShorthand
        case ">" where s.eatIf("="): kind = .mathShorthand
        case ">" where s.eatIf(">"): kind = .mathShorthand
        case "|" where s.eatIf("->"): kind = .mathShorthand
        case "|" where s.eatIf("=>"): kind = .mathShorthand
        case "|" where s.eatIf("|"): kind = .mathShorthand
        case "~" where s.eatIf("~>"): kind = .mathShorthand
        case "~" where s.eatIf(">"): kind = .mathShorthand
        case "*", "-", "~": kind = .mathShorthand

        case ",": kind = .comma
        case ";": kind = .semicolon

        case "#": kind = .hash
        case "_": kind = .underscore
        case "$": kind = .dollar
        case "/": kind = .slash
        case "^": kind = .hat
        case "&": kind = .mathAlignPoint
        case "√", "∛", "∜": kind = .root
        case "!": kind = .bang

        case "'":
            _ = s.eatWhile { $0 == "'" }
            kind = .mathPrimes

        // Delimiters.
        case "(": kind = .leftParen
        case ")": kind = .rightParen
        case "[" where s.eatIf("|"):
            let leaf = SyntaxNode.leaf(.mathShorthand, s.from(start))
            return (.mathOpening, SyntaxNode.inner(.mathOpening, [leaf]))
        case "|" where s.eatIf("]"):
            let leaf = SyntaxNode.leaf(.mathShorthand, s.from(start))
            return (.mathClosing, SyntaxNode.inner(.mathClosing, [leaf]))
        default:
            if let cls = defaultMathClass(c), cls == .opening {
                kind = .mathOpening
            } else if let cls = defaultMathClass(c), cls == .closing {
                kind = .mathClosing
            } else if c.isTypstNumeric {
                _ = s.eatWhile { $0.isTypstNumeric }
                var look = s
                if look.eatIf(".") && !look.eatWhile({ $0.isTypstNumeric }).isEmpty {
                    s = look
                }
                kind = .mathNumber
            } else {
                return mathIdentOrSymbol(start: start, c: c)
            }
        }
        return (kind, nil)
    }

    /// The identifier/symbol disambiguation tail of `math`.
    private mutating func mathIdentOrSymbol(start: Int, c: Unicode.Scalar) -> (SyntaxKind, SyntaxNode?) {
        let charLen = String(c).utf8.count
        // Length of an entire identifier and of the initial grapheme.
        var identifierLen = 0
        if isMathIdStart(c) {
            identifierLen = charLen + s.eatWhile(isMathIdContinue).utf8.count
        }
        let afterStart = s.get(start..<s.length)
        let singleGraphemeLen: Int = {
            guard let first = afterStart.first else { return charLen }
            return String(first).utf8.count
        }()

        if identifierLen > singleGraphemeLen {
            let (kind, node) = mathIdentOrField(start: start)
            return (kind, node)
        } else if identifierLen == singleGraphemeLen {
            return (.mathLetter, nil)
        } else {
            s.jump(start + singleGraphemeLen)
            return (.mathSymbol, nil)
        }
    }

    /// Parse a single MathIdent or an entire MathFieldAccess.
    private mutating func mathIdentOrField(start: Int) -> (SyntaxKind, SyntaxNode) {
        var kind = SyntaxKind.mathIdent
        var node = SyntaxNode.leaf(.mathIdent, s.from(start))
        while let ident = maybeDotIdent() {
            kind = .mathFieldAccess
            node = SyntaxNode.inner(.mathFieldAccess, [
                node,
                SyntaxNode.leaf(.dot, "."),
                SyntaxNode.leaf(.mathIdent, ident),
            ])
        }
        return (kind, node)
    }

    /// If at a dot and a math identifier, eat and return the identifier.
    private mutating func maybeDotIdent() -> String? {
        guard let next = s.scout(1), isMathIdStart(next), s.eatIf(".") else {
            return nil
        }
        let identStart = s.cursor
        _ = s.eat()
        _ = s.eatWhile(isMathIdContinue)
        return s.from(identStart)
    }

    /// Handle named arguments in a math function call.
    mutating func maybeMathNamedArg(start: Int) -> SyntaxNode? {
        let cursor = s.cursor
        s.jump(start)
        if s.eatIf(isIdStart) {
            _ = s.eatWhile(isIdContinue)
            if s.at(":") && !s.at(":=") && !s.at("::=") {
                let text = s.from(start)
                if text != "_" {
                    return SyntaxNode.leaf(.ident, text)
                }
                return SyntaxNode.error("expected identifier, found underscore", text)
            }
        }
        s.jump(cursor)
        return nil
    }

    /// Handle spread arguments in a math function call.
    mutating func maybeMathSpreadArg(start: Int) -> SyntaxNode? {
        let cursor = s.cursor
        s.jump(start)
        if s.eatIf("..") {
            let endChars: Set<Unicode.Scalar> = [".", ",", ";", ")", "$"]
            if !spaceOrEnd() && !s.at(endChars) {
                return SyntaxNode.leaf(.dots, s.from(start))
            }
        }
        s.jump(cursor)
        return nil
    }
}

// MARK: - Code

extension Lexer {
    private mutating func code(start: Int, c: Unicode.Scalar) -> SyntaxKind {
        switch c {
        case "<" where s.at(isIdContinue): return label()
        case "0"..."9": return number(start: start, firstC: c)
        case "." where s.at({ $0.isASCIIDigit }): return number(start: start, firstC: c)
        case "\"": return string()

        case "=" where s.eatIf("="): return .eqEq
        case "!" where s.eatIf("="): return .exclEq
        case "<" where s.eatIf("="): return .ltEq
        case ">" where s.eatIf("="): return .gtEq
        case "+" where s.eatIf("="): return .plusEq
        case "-" where s.eatIf("="): return .hyphEq
        case "\u{2212}" where s.eatIf("="): return .hyphEq
        case "*" where s.eatIf("="): return .starEq
        case "/" where s.eatIf("="): return .slashEq
        case "." where s.eatIf("."): return .dots
        case "=" where s.eatIf(">"): return .arrow

        case "{": return .leftBrace
        case "}": return .rightBrace
        case "[": return .leftBracket
        case "]": return .rightBracket
        case "(": return .leftParen
        case ")": return .rightParen
        case "$": return .dollar
        case ",": return .comma
        case ";": return .semicolon
        case ":": return .colon
        case ".": return .dot
        case "+": return .plus
        case "-", "\u{2212}": return .minus
        case "*": return .star
        case "/": return .slash
        case "=": return .eq
        case "<": return .lt
        case ">": return .gt

        default:
            if isIdStart(c) { return ident(start: start) }
            return invalidCharInCode(c)
        }
    }

    /// Error for an invalid character in code, with hints for common mistakes.
    private mutating func invalidCharInCode(_ c: Unicode.Scalar) -> SyntaxKind {
        func invalidChar() -> String { "the character `\(c)` is not valid in code" }
        func invalidStr(_ str: String) -> String { "`\(str)` is not valid in code" }

        if s.scout(-2) == "#" {
            _ = error(invalidChar())
            hint("the preceding hash is causing this to parse in code mode")
            hint("try escaping the preceding hash: `\\#`")
        } else {
            switch c {
            case "#":
                _ = error(invalidChar())
                hint("you are already in code mode")
                hint("try removing the `#`")
            case "&" where s.eatIf("&"):
                _ = error(invalidStr("&&"))
                hint("in Typst, `and` is used for logical AND")
            case "|" where s.eatIf("|"):
                _ = error(invalidStr("||"))
                hint("in Typst, `or` is used for logical OR")
            case "!":
                _ = error(invalidChar())
                hint("in Typst, `not` is used for negation")
                hint("or did you mean to write `!=` for not-equal?")
            case "~" where s.eatIf("="):
                _ = error(invalidStr("~="))
                hint("in Typst, `!=` is used for not-equal")
            default:
                _ = error(invalidChar())
            }
        }
        return .error
    }

    private mutating func ident(start: Int) -> SyntaxKind {
        _ = s.eatWhile(isIdContinue)
        let ident = s.from(start)

        let prev = s.get(0..<start)
        let precededByDotOrAt = (prev.hasSuffix(".") || prev.hasSuffix("@"))
            && !prev.hasSuffix("..")
        if !precededByDotOrAt, let keyword = keyword(ident) {
            return keyword
        }

        return ident == "_" ? .underscore : .ident
    }

    /// Lex a single number: integer, float, or with a unit suffix.
    private mutating func number(start: Int, firstC: Unicode.Scalar) -> SyntaxKind {
        // Alternative integer bases.
        var base: NonDecimalBase? = nil
        if firstC == "0" {
            if s.eatIf("x") { base = .hex }
            else if s.eatIf("o") { base = .octal }
            else if s.eatIf("b") { base = .binary }
        }

        // Read initial digits.
        if base == .hex {
            _ = s.eatWhile { $0.isASCIIAlphanumeric }
        } else {
            _ = s.eatWhile { $0.isASCIIDigit }
        }

        // Read floating point digits and exponents.
        var isFloat = false
        if base == nil {
            if firstC == "." {
                isFloat = true
            } else if !s.at("..")
                        && !(s.scout(1).map(isIdStart) ?? false)
                        && s.eatIf(".") {
                isFloat = true
                _ = s.eatWhile { $0.isASCIIDigit }
            }

            // Read the exponent.
            if !s.at("em") && s.eatIf(isExponentChar) {
                isFloat = true
                _ = s.eatIf(isSignChar)
                _ = s.eatWhile { $0.isASCIIDigit }
            }
        }

        let number = s.from(start)
        let suffix = s.eatWhile { $0.isASCIIAlphanumeric || $0 == "%" }
        let hasSuffix = !suffix.isEmpty

        // Suffix validation: nil = Ok, string = Err.
        var suffixError: String? = nil
        if hasSuffix
            && !["pt", "mm", "cm", "in", "deg", "rad", "em", "fr", "%"].contains(suffix) {
            suffixError = "invalid number suffix: `\(suffix)`"
        }

        // Number validation.
        var numberError: String? = nil
        if isFloat {
            if !isValidFloat(number) {
                numberError = "invalid floating point number: `\(number)`"
            }
        } else if let base {
            let digits = String(number.dropFirst(2))
            if let value = Int64(digits, radix: base.radix) {
                if hasSuffix {
                    if suffixError == nil {
                        suffixError = "try using a decimal number: `\(value)\(suffix)`"
                    }
                    numberError = "\(base.name) numbers cannot have a suffix"
                }
            } else if digits.isEmpty {
                numberError = "expected a\(base == .octal ? "n" : "") \(base.name) number"
            } else if suffixError != nil {
                // We're already erroring; report the invalid integer first.
                numberError = "invalid \(base.name) number: `\(number)`"
            }
            // Invalid digits and positive overflow are handled in the AST.
        }

        // Return the number kind or write an error with helpful hints.
        if let numberError, let suffixError {
            _ = error(numberError)
            hint(suffixError)
            return .error
        } else if let msg = numberError ?? suffixError {
            return error(msg)
        } else if isFloat && !hasSuffix {
            return .float
        } else if !isFloat && !hasSuffix {
            return .int
        } else {
            return .numeric
        }
    }

    private func isValidFloat(_ number: String) -> Bool {
        // `f64::from_str` semantics; the lexer only produces decimal forms.
        Double(number) != nil
    }

    private mutating func string() -> SyntaxKind {
        var escaped = false
        _ = s.eatUntil { c in
            let stop = c == "\"" && !escaped
            escaped = c == "\\" && !escaped
            return stop
        }

        guard s.eatIf("\"") else {
            return error("unclosed string")
        }
        return .str
    }
}

// `NonDecimalBase` lives in AstLiterals.swift (public, port of
// `ast::NonDecimalBase`); the lexer shares that definition.

// MARK: - Shared predicates & helpers (lexer.rs bottom half)

/// Whether a character will become a space token.
private func isSpace(_ character: Unicode.Scalar, mode: SyntaxMode) -> Bool {
    switch mode {
    case .markup:
        return character == " " || character == "\t" || isNewline(character)
    default:
        return character.isTypstWhitespace
    }
}

/// Whether a string is a valid Typst identifier.
func isIdent(_ string: String) -> Bool {
    let scalars = string.unicodeScalars
    guard let first = scalars.first, isIdStart(first) else { return false }
    return scalars.dropFirst().allSatisfy(isIdContinue)
}

/// Whether a scalar can start an identifier.
func isIdStart(_ c: Unicode.Scalar) -> Bool {
    UnicodeIdent.isXIDStart(c) || c == "_"
}

/// Whether a scalar can continue an identifier.
func isIdContinue(_ c: Unicode.Scalar) -> Bool {
    UnicodeIdent.isXIDContinue(c) || c == "_" || c == "-"
}

/// Whether a scalar can start an identifier in math.
private func isMathIdStart(_ c: Unicode.Scalar) -> Bool {
    UnicodeIdent.isXIDStart(c)
}

/// Whether a scalar can continue an identifier in math.
private func isMathIdContinue(_ c: Unicode.Scalar) -> Bool {
    UnicodeIdent.isXIDContinue(c) && c != "_"
}

/// Whether a scalar can be part of a label literal's name.
private func isValidInLabelLiteral(_ c: Unicode.Scalar) -> Bool {
    isIdContinue(c) || c == ":" || c == "."
}

/// Whether a string is valid in a label literal.
func isValidLabelLiteralId(_ id: String) -> Bool {
    !id.isEmpty && id.unicodeScalars.allSatisfy(isValidInLabelLiteral)
}

private func isExponentChar(_ c: Unicode.Scalar) -> Bool { c == "e" || c == "E" }
private func isSignChar(_ c: Unicode.Scalar) -> Bool { c == "+" || c == "-" }

/// Try to parse an identifier into a keyword.
private func keyword(_ ident: String) -> SyntaxKind? {
    switch ident {
    case "none": return SyntaxKind.none
    case "auto": return .auto
    case "true", "false": return .bool
    case "not": return .not
    case "and": return .and
    case "or": return .or
    case "let": return .let
    case "set": return .set
    case "show": return .show
    case "context": return .context
    case "if": return .if
    case "else": return .else
    case "for": return .for
    case "in": return .in
    case "while": return .while
    case "break": return .break
    case "continue": return .continue
    case "return": return .return
    case "import": return .import
    case "include": return .include
    case "as": return .as
    default: return nil
    }
}

/// Extract a prefix of the text that is a link; also returns whether
/// parentheses and brackets were balanced. Port of `link_prefix`.
func linkPrefix(_ text: String) -> (String, Bool) {
    var s = Scanner(text)
    var brackets: [Unicode.Scalar] = []

    _ = s.eatWhile { c in
        switch c {
        case "0"..."9", "a"..."z", "A"..."Z",
             "!", "#", "$", "%", "&", "*", "+",
             ",", "-", ".", "/", ":", ";", "=",
             "?", "@", "_", "~", "'":
            return true
        case "[":
            brackets.append("[")
            return true
        case "(":
            brackets.append("(")
            return true
        case "]":
            return brackets.popLast() == "["
        case ")":
            return brackets.popLast() == "("
        default:
            return false
        }
    }

    // Don't include trailing characters likely part of text.
    let trailing: Set<Unicode.Scalar> = ["!", ",", ".", ":", ";", "?", "'"]
    while let c = s.scout(-1), trailing.contains(c) {
        s.uneat()
    }

    return (s.before, brackets.isEmpty)
}
