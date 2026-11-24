import Foundation

/// Render an inline equation (`$...$`), guaranteed to contain no markup
/// syntax that could break the surrounding Typst document.
func renderInlineMath(_ tex: String) -> String {
    let tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
    if tex.isEmpty { return "" }
    if let body = texToTypstMath(tex) {
        let singleLine = collapseNewlines(body)
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let candidate = "$\(trimmed)$"
            if isPlausibleTypstMath(candidate) { return candidate }
            let parenthesized = "($(trimmed))$"
            if isPlausibleTypstMath(parenthesized) { return parenthesized }
        }
    }
    // Safe fallback: raw inline span when the TeX is syntactically broken.
    let single = tex.replacingOccurrences(of: "\n", with: " ")
    if !single.contains("`") {
        return "`\(single)`"
    }
    return "#raw(\"\(escapeString(single))\")"
}

/// Render a display block equation (`$ ... $`).
func renderBlockMath(_ tex: String) -> String? {
    let tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
    if tex.isEmpty { return nil }
    if let body = texToTypstMath(tex) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let candidate = "$ \(trimmed) $"
            if isPlausibleTypstMath(candidate) { return candidate }
        }
    }
    let fence = backtickFence(tex, minTicks: 3)
    return "\(fence)tex\n\(tex)\n\(fence)"
}

/// Lightweight sanity check replacing `typst_syntax::parse` verification:
/// balanced parens/brackets outside strings, no raw `$` inside the math
/// body, strings closed. The wrapping `$` delimiters are stripped first.
private func isPlausibleTypstMath(_ snippet: String) -> Bool {
    var body = snippet[...]
    if body.hasPrefix("$") { body = body.dropFirst() }
    if body.hasSuffix("$") { body = body.dropLast() }
    var depth = 0
    var inString = false
    var escaped = false
    var i = body.startIndex
    while i < body.endIndex {
        let c = body[i]
        if escaped { escaped = false; i = body.index(after: i); continue }
        if c == "\\" { escaped = true; i = body.index(after: i); continue }
        if inString {
            if c == "\"" { inString = false }
            i = body.index(after: i); continue
        }
        switch c {
        case "\"": inString = true
        case "(", "[": depth += 1
        case ")", "]":
            depth -= 1
            if depth < 0 { return false }
        case "$": return false
        default: break
        }
        i = body.index(after: i)
    }
    return depth == 0 && !inString
}

// MARK: - LaTeX -> Typst math translator

/// Convert a LaTeX math expression to Typst math markup. Returns nil when the
/// input uses constructs outside the supported subset; callers then degrade
/// to a raw `tex` span.
private func texToTypstMath(_ tex: String) -> String? {
    var parser = TexParser(Array(tex))
    let out = parser.parseSequence()
    parser.skipWhitespace()
    guard parser.ok, parser.isAtEnd else { return nil }
    let tidied = simplifySingleCharScripts(tidyMathSpacing(out))
    return tidied.isEmpty ? nil : tidied
}

private struct TexParser {
    let chars: [Character]
    var pos = 0
    var ok = true

    init(_ chars: [Character]) { self.chars = chars }

    var isAtEnd: Bool { pos >= chars.count }

    func peek(_ ahead: Int = 0) -> Character? {
        let i = pos + ahead
        return i < chars.count ? chars[i] : nil
    }

    @discardableResult
    mutating func advance() -> Character? {
        guard pos < chars.count else { return nil }
        defer { pos += 1 }
        return chars[pos]
    }

    mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { pos += 1 }
    }

    mutating func skipComment() {
        // LaTeX `%` comments run to end of line.
        while let c = peek(), c != "\n" { pos += 1 }
    }

    /// Parse a math sequence until EOF.
    mutating func parseSequence() -> String {
        var out = ""
        while !isAtEnd {
            // Infix fraction commands: `a \over b`, `a \atop b`,
            // `a \overwithdelims( [ b`, ... The numerator is everything
            // accumulated so far in this group (TeX semantics).
            if let over = peekOverCommand() {
                _ = readCommand()
                var d1 = "", d2 = ""
                if over.hasSuffix("withdelims") {
                    d1 = parseDelimiterChar()
                    d2 = parseDelimiterChar()
                }
                if over == "above" || over == "abovewithdelims" {
                    _ = parseArg() // dimension argument: discard
                }
                let denom = parseSequence()
                let frac = "frac(\(sanitizeArg(out)), \(sanitizeArg(denom)))"
                out = (d1.isEmpty && d2.isEmpty)
                    ? frac
                    : "lr(\(d1) \(frac) \(d2))"
                return out
            }
            let piece = parseItem()
            if piece.isEmpty && !ok { break }
            out += piece
        }
        return out
    }

    /// If the upcoming token is an infix `\over`-family command, return its name.
    private mutating func peekOverCommand() -> String? {
        var i = pos
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        guard i < chars.count, chars[i] == "\\" else { return nil }
        var j = i + 1
        var name = ""
        while j < chars.count, chars[j].isASCII, chars[j].isLetter {
            name.append(chars[j]); j += 1
        }
        if name.isEmpty, j < chars.count { name = String(chars[j]) }
        let overNames: Set<String> = [
            "over", "atop", "above",
            "overwithdelims", "atopwithdelims",
            "abovewithdelims", "belowwithdelims",
        ]
        return overNames.contains(name) ? name : nil
    }

    /// One math item: atom with optional `^`/`_` script attachments.
    private mutating func parseItem() -> String {
        skipWhitespace()
        guard let c = peek() else { return "" }
        if c == "^" || c == "_" {
            advance()
            return c == "^" ? "\\^" : "\\_"
        }
        if c == "&" {
            advance()
            return " & "
        }
        if c == "'" {
            var n = 0
            while peek() == "'" { advance(); n += 1 }
            return String(repeating: "'", count: n)
        }
        if c == "%" {
            skipComment()
            return ""
        }
        if c == "~" {
            advance()
            return "space.nobreak"
        }
        if c == "\\" {
            let cmd = parseCommand()
            var result = cmd
            // Script attachments bind to the command result (e.g. \frac{..}{..}_1).
            result += parseScriptSuffix()
            return result
        }
        if c == "{" {
            let g = parseBraceGroup()
            return g + parseScriptSuffix()
        }
        if c == "(" || c == "[" {
            let d = parseDelimitedLiteral(open: c)
            return d + parseScriptSuffix()
        }
        if c == ")" || c == "]" {
            advance()
            return c == ")" ? "\\)" : "\\]"
        }
        if c == "#" {
            // Stray `#` in LaTeX math: emit escaped to stay literal.
            advance()
            return "\\u{0023}"
        }
        advance()
        if c.isNumber {
            var num = String(c)
            while let n = peek(), n.isNumber || n == "." {
                num.append(n); advance()
            }
            return num + parseScriptSuffix()
        }
        // Ordinary single char.
        return String(c) + parseScriptSuffix()
    }

    /// Consume `^arg` / `_arg` pairs; each arg becomes a parenthesized group
    /// (Typst `math_unparen` strips the parens, so they never render).
    private mutating func parseScriptSuffix() -> String {
        var out = ""
        while true {
            skipWhitespace()
            guard let c = peek(), c == "^" || c == "_" else { break }
            advance()
            guard let arg = parseScriptArg() else { ok = false; return out }
            out += "\(c)(\(sanitizeArg(arg)))"
        }
        return out
    }

    /// Script argument: `{...}` group or a single atom (no further scripts).
    private mutating func parseScriptArg() -> String? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        if c == "{" { return parseBraceGroup() }
        return parseAtomNoScripts()
    }

    /// `{...}` group: parse contents; returns inner markup.
    private mutating func parseBraceGroup() -> String {
        advance() // '{'
        var depth = 1
        var inner = ""
        while !isAtEnd {
            let c = advance()!
            if c == "\\" {
                inner.append(c)
                if let n = advance() { inner.append(n) }
                continue
            }
            if c == "{" { depth += 1; inner.append(c); continue }
            if c == "}" {
                depth -= 1
                if depth == 0 { break }
                inner.append(c); continue
            }
            inner.append(c)
        }
        guard depth == 0 else { ok = false; return "" }
        var sub = TexParser(Array(inner))
        let out = sub.parseSequence()
        sub.skipWhitespace()
        guard sub.ok, sub.isAtEnd else {
            return "#text[\(escapeMarkup(inner, atLineStart: false))]"
        }
        return out
    }

    /// Literal `(...)` or `[...]` delimited group in the source.
    private mutating func parseDelimitedLiteral(open: Character) -> String {
        let close: Character = open == "(" ? ")" : "]"
        advance()
        var inner = ""
        var depth = 1
        while !isAtEnd {
            let c = advance()!
            if c == "\\" {
                inner.append(c)
                if let n = advance() { inner.append(n) }
                continue
            }
            if c == open { depth += 1; inner.append(c); continue }
            if c == close {
                depth -= 1
                if depth == 0 { break }
                inner.append(c); continue
            }
            inner.append(c)
        }
        guard depth == 0 else { ok = false; return "" }
        var sub = TexParser(Array(inner))
        let body = sub.parseSequence()
        sub.skipWhitespace()
        guard sub.ok, sub.isAtEnd else { ok = false; return "" }
        return "\(open)\(body)\(close)"
    }

    /// Read a control sequence: `\` + ASCII letters, or `\` + single char.
    private mutating func readCommand() -> String {
        advance() // backslash
        var name = ""
        while let c = peek(), c.isASCII, c.isLetter {
            name.append(c)
            advance()
        }
        if name.isEmpty, let c = advance() {
            name = String(c)
        }
        return name
    }

    /// Single atom WITHOUT script attachment (for function args).
    private mutating func parseAtomNoScripts() -> String? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        if c == "{" { return parseBraceGroup() }
        if c == "(" || c == "[" { return parseDelimitedLiteral(open: c) }
        if c == "\\" { return parseCommand() }
        if c == "'" {
            var n = 0
            while peek() == "'" { advance(); n += 1 }
            return String(repeating: "'", count: n)
        }
        if c == "%" { skipComment(); return parseAtomNoScripts() }
        advance()
        if c.isNumber {
            var num = String(c)
            while let n = peek(), n.isNumber || n == "." { num.append(n); advance() }
            return num
        }
        return String(c)
    }

    /// Parse one function argument: a `{...}` group or a single atom.
    private mutating func parseArg() -> String? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        if c == "{" { return parseBraceGroup() }
        return parseAtomNoScripts()
    }

    /// Parse a `{...}` group and return its RAW inner LaTeX.
    private mutating func parseBraceRaw() -> String? {
        skipWhitespace()
        guard peek() == "{" else { return nil }
        advance()
        var depth = 1
        var inner = ""
        while !isAtEnd {
            let c = advance()!
            if c == "\\" {
                inner.append(c)
                if let n = advance() { inner.append(n) }
                continue
            }
            if c == "{" { depth += 1; inner.append(c); continue }
            if c == "}" {
                depth -= 1
                if depth == 0 { return inner }
                inner.append(c); continue
            }
            inner.append(c)
        }
        ok = false
        return nil
    }

    private mutating func parseCommand() -> String {
        let name = readCommand()
        switch name {
        // ---- Fraction-like ---------------------------------------------
        case "frac", "dfrac", "tfrac", "cfrac":
            guard let a = parseArg(), let b = parseArg() else { return "" }
            return "frac(\(sanitizeArg(a)), \(sanitizeArg(b)))"
        case "binom", "dbinom", "tbinom":
            guard let a = parseArg(), let b = parseArg() else { return "" }
            return "binom(\(sanitizeArg(a)), \(sanitizeArg(b)))"
        case "genfrac":
            // \genfrac{ldelim}{rdelim}{thickness}{style}{num}{den}
            var args: [String] = []
            for _ in 0..<6 { args.append(parseArg() ?? "") }
            let frac = "frac(\(sanitizeArg(args[4])), \(sanitizeArg(args[5])))"
            let d1 = delimiterNameToTypst(args[0]) ?? args[0]
            let d2 = delimiterNameToTypst(args[1]) ?? args[1]
            if d1.isEmpty && d2.isEmpty { return frac }
            return "lr(\(d1) \(frac) \(d2))"
        case "substack":
            guard let raw = parseBraceRaw() else { return "" }
            let rows = splitEnvRows(raw).map { row -> String in
                var sub = TexParser(Array(row))
                return sub.parseSequence()
            }
            return "matrix(\(rows.joined(separator: "; ")))"
        case "sqrt":
            var indexArg: String? = nil
            skipWhitespace()
            if peek() == "[" {
                advance()
                var raw = ""
                var depth = 1
                while !isAtEnd, depth > 0 {
                    let c = advance()!
                    if c == "[" { depth += 1 }
                    if c == "]" { depth -= 1; if depth == 0 { break } }
                    raw.append(c)
                }
                var sub = TexParser(Array(raw))
                indexArg = sub.parseSequence()
            }
            guard let rad = parseArg() else { return "" }
            if let idx = indexArg, !idx.isEmpty {
                return "root(\(sanitizeArg(idx)), \(sanitizeArg(rad)))"
            }
            return "sqrt(\(sanitizeArg(rad)))"

        // ---- Over/under --------------------------------------------------
        case "overline":
            guard let a = parseArg() else { return "" }
            return "overline(\(sanitizeArg(a)))"
        case "underline":
            guard let a = parseArg() else { return "" }
            return "underline(\(sanitizeArg(a)))"
        case "overbrace":
            guard let a = parseArg() else { return "" }
            return "overbrace(\(sanitizeArg(a)))"
        case "underbrace":
            guard let a = parseArg() else { return "" }
            return "underbrace(\(sanitizeArg(a)))"
        case "stackrel":
            guard let top = parseArg(), let base = parseArg() else { return "" }
            return "attach(\(sanitizeArg(base)), t: \(sanitizeArg(top)))"
        case "buildrel":
            // \buildrel{top}\over{base} - rare; treat like stackrel if \over
            // follows is handled by the infix path anyway.
            guard let top = parseArg() else { return "" }
            return "attach(\(sanitizeArg(top)))"

        // ---- Fonts / styles ----------------------------------------------
        case "mathrm": return fontWrap("upright")
        case "mathbf", "boldsymbol", "pmb": return fontWrap("bold")
        case "mathit": return fontWrap("italic")
        case "mathsf": return fontWrap("sans")
        case "mathtt": return fontWrap("mono")
        case "mathfrak": return fontWrap("frak")
        case "mathcal": return fontWrap("cal")
        case "mathscr": return fontWrap("scr")
        case "mathbb", "Bbb": return fontWrap("bb")
        case "mathnormal", "mathdefault": return parseArg() ?? ""
        case "displaystyle": return styleWrap("display")
        case "textstyle": return styleWrap("inline")
        case "scriptstyle": return styleWrap("script")
        case "scriptscriptstyle": return styleWrap("sscript")
        case "limits", "nolimits": return ""

        // ---- Operators ----------------------------------------------------
        case "operatorname": return fontWrap("upright")
        case "operatorname*": return fontWrap("upright")
        case "mathop": return parseArg() ?? ""
        case "mathchoice":
            // \mathchoice{d}{t}{s}{ss}: emit the textstyle arg.
            var args: [String] = []
            for _ in 0..<4 { args.append(parseArg() ?? "") }
            return args.count > 1 ? args[1] : ""
        case "text": return parseTextArg()

        // ---- Delimiters ----------------------------------------------------
        case "left":
            skipWhitespace()
            return "lr(\(parseDelimiterChar())"
        case "right":
            skipWhitespace()
            return "\(parseDelimiterChar()))"
        case "middle":
            skipWhitespace()
            return parseDelimiterChar()
        case "big", "Big", "bigg", "Bigg",
             "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr":
            skipWhitespace()
            return parseDelimiterChar()

        // ---- Environments ----------------------------------------------------
        case "begin": return parseEnvironment()
        case "end": ok = false; return ""

        // ---- Spacing ---------------------------------------------------------
        case "quad": return "quad"
        case "qquad": return "wide"
        case ",": return "thin"
        case ":": return "med"
        case ";": return "thick"
        case "!": return ""
        case ">": return "med"
        case " ": return " "
        case "enspace", "thinspace": return "thin"
        case "thickspace": return "thick"
        case "medspace": return "med"
        case "negthinspace": return "negthinspace"
        case "negmedspace": return "negmedspace"
        case "negthickspace": return "negthickspace"
        case "negthinspace2": return ""
        case "hspace", "hspace*", "kern", "mkern", "mskip", "hskip", "vskip":
            return parseHSpace()
        case "phantom", "hphantom", "vphantom":
            _ = parseArg()
            return ""
        case "mathstrut", "strut": return ""
        case "rule":
            _ = parseArg(); _ = parseArg()
            return ""
        case "raisebox", "parbox", "minipage", "makebox", "framebox",
             "colorbox", "fcolorbox", "mbox", "hbox", "vbox", "smash":
            // Text-mode box commands: emit the LAST brace arg (the content).
            return parseLastArg() ?? ""
        case "includegraphics", "input", "include", "import", "subimport",
             "label", "ref", "eqref", "cite", "pageref", "autoref", "nameref",
             "tag", "tag*", "footnote", "marginpar", "thanks", "index",
             "glossary", "bibliographystyle", "bibliography", "documentclass",
             "usepackage", "RequirePackage", "newcommand", "renewcommand",
             "providecommand", "DeclareMathOperator", "newtheorem", "def",
             "let", "gdef", "edef", "xdef", "newif", "newcount", "newdimen",
             "newskip", "newmuskip", "newread", "newwrite", "newfam", "newinsert",
             "newbox", "newtoks", "catcode", "mathcode", "delcode", "lccode",
             "uccode", "sfcode", "hyphenation", "patterns", "message", "typeout",
             "errmessage", "show", "showthe", "meaning", "the", "number",
             "romannumeral", "jobname", "today", "month", "year", "time",
             "if", "else", "fi", "ifx", "ifnum", "ifdim", "ifodd", "ifvmode",
             "ifhmode", "ifmmode", "ifinner", "ifvoid", "ifhbox", "ifvbox",
             "ifeof", "iftrue", "iffalse", "or", "loop", "repeat", "while",
             "foreach", "begin0", "begingroup", "endgroup", "aftergroup",
             "global", "long", "outer", "protected", "expandafter", "noexpand",
             "relax", "hfil", "hfill", "vfil", "vfill", "hfilneg", "vfilneg",
             "break", "nobreak", "penalty", "kern0", "mkern0", "mskip0",
             "hspace0", "vspace0", "hspace*0", "vspace*0", "indent", "noindent",
             "par", "smallskip", "medskip", "bigskip", "newpage", "clearpage",
             "cleardoublepage", "linebreak", "nolinebreak", "pagebreak",
             "nopagebreak", "samepage", "enlargethispage", "centering",
             "raggedright", "raggedleft", "flushleft", "flushright", "center",
             "tiny", "scriptsize", "footnotesize", "small", "normalsize",
             "large", "Large", "LARGE", "huge", "Huge", "selectfont",
             "fontfamily", "fontseries", "fontshape", "fontsize", "baselineskip",
             "linespread", "rm", "sf", "tt", "bf", "it", "sl", "sc", "em",
             "enspace2", "negthickspace2", "mspace", "nonscript",
             "mathop2", "limits2":
            // Consume following brace args then drop.
            _ = parseArg()
            return ""

        // ---- Accents ---------------------------------------------------------
        case "hat", "widehat": return accentWrap("hat")
        case "tilde", "widetilde": return accentWrap("tilde.op")
        case "bar": return accentWrap("macron")
        case "breve": return accentWrap("breve")
        case "check": return accentWrap("caron")
        case "acute": return accentWrap("acute")
        case "grave": return accentWrap("grave")
        case "dot": return accentWrap("dot.op")
        case "ddot": return accentWrap("diaer")
        case "vec", "overrightarrow": return accentWrap("arrow.r")
        case "overleftarrow": return accentWrap("arrow.l")
        case "overleftrightarrow": return accentWrap("arrow.l.r")
        case "mathring": return accentWrap("compose")
        case "dddot":
            guard let a = parseArg() else { return "" }
            return "\(sanitizeArg(a))\\u{20DB}"
        case "ddddot":
            guard let a = parseArg() else { return "" }
            return "\(sanitizeArg(a))\\u{20DC}"
        // Single-character accent commands.
        case "^": return accentWrap("hat")
        case "~": return accentWrap("tilde.op")
        case "'": return accentWrap("acute")
        case "\"": return accentWrap("diaer")
        case "`": return accentWrap("grave")
        case ".": return accentWrap("dot.op")
        case "=": return accentWrap("macron")
        case "u": return accentWrap("breve")
        case "v": return accentWrap("caron")
        case "H", "c", "d", "b", "t", "k", "B", "G", "r":
            // Combining accents with no Typst accent func: keep content.
            _ = parseArg()
            return ""

        // ---- Symbols -----------------------------------------------------------
        default:
            return symbolOrOperator(name)
        }
    }

    private mutating func fontWrap(_ fn: String) -> String {
        guard let a = parseArg() else { return "" }
        return "\(fn)(\(sanitizeArg(a)))"
    }

    private mutating func styleWrap(_ fn: String) -> String {
        guard let a = parseArg() else { return "" }
        return "\(fn)(\(sanitizeArg(a)))"
    }

    private mutating func accentWrap(_ fn: String) -> String {
        guard let a = parseArg() else { return "" }
        return "\(fn)(\(sanitizeArg(a)))"
    }

    /// `\text{...}` -> `#text[...]` with markup-escaped content.
    private mutating func parseTextArg() -> String {
        guard let raw = parseBraceRaw() else { return "" }
        return "#text[\(escapeMarkup(raw, atLineStart: false))]"
    }

    /// Parse up to `n` args and return the LAST non-empty one (for box cmds).
    private mutating func parseLastArg() -> String? {
        var last: String? = nil
        for _ in 0..<4 {
            skipWhitespace()
            guard peek() == "{" else { break }
            if let a = parseArg() { last = a }
        }
        return last
    }

    /// `\left`/`\right` handled inline in parseCommand; keep for compat.
    private mutating func parseLeftRight(_ which: String) -> String {
        skipWhitespace()
        let delim = parseDelimiterChar()
        switch which {
        case "left": return "lr(\(delim)"
        case "right": return "\(delim))"
        default: return delim
        }
    }

    private mutating func parseBigDelimiter() -> String {
        skipWhitespace()
        return parseDelimiterChar()
    }

    /// Read one delimiter spec after \left/\right/\big/\middle.
    private mutating func parseDelimiterChar() -> String {
        skipWhitespace()
        guard let c = peek() else { return "" }
        if c == "." { advance(); return "" }
        if c == "\\" {
            let name = readCommand()
            return delimiterNameToTypst(name) ?? ""
        }
        advance()
        return delimiterCharToTypst(c)
    }

    private func delimiterCharToTypst(_ c: Character) -> String {
        switch c {
        case "{": return "{"
        case "}": return "}"
        case "\\": return "\\u{005C}"
        default: return String(c)
        }
    }

    private func delimiterNameToTypst(_ name: String) -> String? {
        switch name {
        case "langle": return "⟨"
        case "rangle": return "⟩"
        case "lfloor": return "⌊"
        case "rfloor": return "⌋"
        case "lceil": return "⌈"
        case "rceil": return "⌉"
        case "lVert", "rVert", "Vert": return "‖"
        case "vert", "lvert", "rvert": return "|"
        case "|": return "‖"
        case "lbrace", "rbrace": return name.hasPrefix("l") ? "{" : "}"
        case "lbrack", "rbrack": return name.hasPrefix("l") ? "[" : "]"
        case "lparen", "rparen": return name.hasPrefix("l") ? "(" : ")"
        case "uparrow": return "↑"
        case "downarrow": return "↓"
        case "updownarrow": return "↕"
        case "Uparrow": return "⇑"
        case "Downarrow": return "⇓"
        case "Updownarrow": return "⇕"
        case "backslash": return "\\u{005C}"
        case "lmoustache": return "\\u{23B0}"
        case "rmoustache": return "\\u{23B1}"
        case "bracevert": return "|"
        case "arrowvert": return "\\u{23D0}"
        case "Arrowvert": return "‖"
        case "ulcorner": return "\\u{231C}"
        case "urcorner": return "\\u{231D}"
        case "llcorner": return "\\u{231E}"
        case "lrcorner": return "\\u{231F}"
        case "lgroup": return "⦅"
        case "rgroup": return "⦆"
        case "mid": return "|"
        default: return nil
        }
    }

    /// `\begin{env}...\end{env}` -> Typst matrix/cases/aligned construct.
    private mutating func parseEnvironment() -> String {
        skipWhitespace()
        guard let envRaw = parseBraceRaw() else { ok = false; return "" }
        var env = envRaw.trimmingCharacters(in: .whitespaces)
        env = env.replacingOccurrences(of: "*", with: "")
        // Environments taking a column-spec argument: \begin{array}{cc}.
        let argEnvs: Set<String> = [
            "array", "tabular", "tabularx", "tabulary", "longtable",
            "supertabular", "xtabular", "tabular*",
        ]
        if argEnvs.contains(env) {
            _ = parseBraceRaw()
        }
        guard let inner = extractEnvironmentBody(env: env) else {
            ok = false
            return ""
        }
        return renderEnvironment(name: env, body: inner)
    }

    /// Scan forward for the matching `\end{env}`, honoring nested `\begin`.
    private mutating func extractEnvironmentBody(env: String) -> String? {
        var depth = 1
        var i = pos
        let chars = self.chars
        while i < chars.count {
            if chars[i] == "\\" {
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isASCII, chars[j].isLetter {
                    name.append(chars[j]); j += 1
                }
                if name.isEmpty, j < chars.count {
                    name = String(chars[j]); j += 1
                }
                if name == "begin" {
                    var k = j
                    while k < chars.count, chars[k].isWhitespace { k += 1 }
                    if k < chars.count, chars[k] == "{" {
                        var d = 1; k += 1
                        while k < chars.count, d > 0 {
                            if chars[k] == "{" { d += 1 }
                            if chars[k] == "}" { d -= 1 }
                            k += 1
                        }
                        depth += 1
                        i = k
                        continue
                    }
                }
                if name == "end" {
                    var k = j
                    while k < chars.count, chars[k].isWhitespace { k += 1 }
                    if k < chars.count, chars[k] == "{" {
                        var d = 1; k += 1
                        var innerName = ""
                        while k < chars.count, d > 0 {
                            if chars[k] == "{" { d += 1 }
                            else if chars[k] == "}" {
                                d -= 1
                                if d == 0 { break }
                            }
                            innerName.append(chars[k])
                            k += 1
                        }
                        k += 1
                        let endName = innerName.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "*", with: "")
                        if endName == env, depth == 1 {
                            let body = String(chars[pos..<i])
                            pos = k
                            return body
                        }
                        if depth > 1 { depth -= 1 }
                        i = k
                        continue
                    }
                }
                i = j
                continue
            }
            i += 1
        }
        return nil
    }

    /// Split env body into rows (`\\`) then cells (`&`), convert each cell.
    private func renderEnvironment(name: String, body: String) -> String {
        // \\hline and friends inside tabular: strip them first.
        var cleaned = body
        for cmd in ["hline", "hdashline", "cline", "toprule", "midrule",
                    "bottomrule", "cmidrule", "addlinespace", "specialrule",
                    "hhline", "firsthline", "lasthline", "hlineB", "cdashline"] {
            cleaned = cleaned.replacingOccurrences(of: "\\\(cmd)", with: " ")
        }
        let rows = splitEnvRows(cleaned)
        let cellRows: [[String]] = rows.map { row in
            splitEnvCells(row).map { cell -> String in
                var sub = TexParser(Array(cell))
                let converted = sub.parseSequence()
                sub.skipWhitespace()
                if sub.ok, sub.isAtEnd {
                    return sanitizeArg(converted)
                }
                return "#text[\(escapeMarkup(cell, atLineStart: false))]"
            }
        }

        func joinCells(_ cells: [String]) -> String {
            cells.joined(separator: " & ")
        }
        func joinMatCells(_ cells: [String]) -> String {
            cells.joined(separator: ", ")
        }

        switch name {
        case "matrix", "smallmatrix", "array", "subarray", "darray":
            return "matrix(\(cellRows.map(joinMatCells).joined(separator: "; ")))"
        case "pmatrix":
            return "pmatrix(\(cellRows.map(joinMatCells).joined(separator: "; ")))"
        case "bmatrix":
            return "bmatrix(\(cellRows.map(joinMatCells).joined(separator: "; ")))"
        case "Bmatrix":
            return "Bmatrix(\(cellRows.map(joinMatCells).joined(separator: "; ")))"
        case "vmatrix":
            return "vmatrix(\(cellRows.map(joinMatCells).joined(separator: "; ")))"
        case "Vmatrix":
            return "Vmatrix(\(cellRows.map(joinMatCells).joined(separator: "; ")))"
        case "cases", "dcases", "rcases", "drcases":
            return "cases(\(cellRows.map(joinCells).joined(separator: ", ")))"
        case "aligned", "align", "alignedat", "alignat", "gather", "gathered",
             "multline", "split", "equation", "displaymath", "eqnarray",
             "flalign", "subequations", "align*", "gather*", "multline*",
             "equation*", "flalign*", "alignat*", "eqnarray*":
            return "aligned(\(cellRows.map(joinCells).joined(separator: " \\\n")))"
        default:
            var sub = TexParser(Array(body))
            return sub.parseSequence()
        }
    }

    /// Split environment body on top-level `\\` row separators.
    private func splitEnvRows(_ body: String) -> [String] {
        var rows: [String] = []
        var current = ""
        var depth = 0
        let chars = Array(body)
        var idx = 0
        while idx < chars.count {
            let c = chars[idx]
            if c == "\\" {
                if idx + 1 < chars.count, chars[idx + 1] == "\\", depth == 0 {
                    rows.append(current)
                    current = ""
                    idx += 2
                    var j = idx
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == "[" {
                        var d = 1; j += 1
                        while j < chars.count, d > 0 {
                            if chars[j] == "[" { d += 1 }
                            if chars[j] == "]" { d -= 1 }
                            j += 1
                        }
                        idx = j
                    }
                    continue
                }
                current.append(c)
                if idx + 1 < chars.count {
                    current.append(chars[idx + 1])
                    idx += 2
                    continue
                }
                idx += 1
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            current.append(c)
            idx += 1
        }
        rows.append(current)
        return rows
    }

    /// Split one env row on top-level `&` cell separators.
    private func splitEnvCells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var depth = 0
        let chars = Array(row)
        var idx = 0
        while idx < chars.count {
            let c = chars[idx]
            if c == "\\" {
                current.append(c)
                if idx + 1 < chars.count {
                    current.append(chars[idx + 1])
                    idx += 2
                    continue
                }
                idx += 1
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if c == "&", depth == 0 {
                cells.append(current)
                current = ""
                idx += 1
                continue
            }
            current.append(c)
            idx += 1
        }
        cells.append(current)
        return cells
    }

    /// `\hspace{..}`/`\kern..` -> Typst `#h(..)` with unit conversion.
    private mutating func parseHSpace() -> String {
        skipWhitespace()
        var raw = ""
        if peek() == "{" {
            if let r = parseBraceRaw() { raw = r }
        } else {
            while let c = peek(), !(c.isWhitespace) {
                raw.append(c); advance()
            }
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // TeX dimension: optional sign, number, unit.
        guard let m = trimmed.range(of: #"^(-?\d*\.?\d+)\s*(pt|pc|in|bp|cm|mm|dd|cc|em|ex|mu)$"#,
                                    options: .regularExpression) else {
            return ""
        }
        let whole = String(trimmed[m])
        guard let numEnd = whole.firstIndex(where: { $0.isLetter }) else { return "" }
        let numStr = String(whole[..<numEnd])
        let unit = String(whole[numEnd...])
        guard var value = Double(numStr) else { return "" }
        let typstUnit: String
        switch unit {
        case "em": typstUnit = "em"
        case "ex": value *= 0.5; typstUnit = "em"
        case "pt": typstUnit = "pt"
        case "pc": value *= 12; typstUnit = "pt"
        case "in": typstUnit = "in"
        case "bp": typstUnit = "pt" // ~1:1
        case "cm": typstUnit = "cm"
        case "mm": typstUnit = "mm"
        case "dd": value *= 123.37; typstUnit = "pt" // 1dd ≈ 123.37pt
        case "cc": value *= 12 * 123.37; typstUnit = "pt"
        case "mu": value /= 18; typstUnit = "em" // 1mu = 1/18 em
        default: return ""
        }
        // Trim trailing zeros.
        var num = String(format: "%.4f", value)
        while num.hasSuffix("0") { num.removeLast() }
        if num.hasSuffix(".") { num.removeLast() }
        if num == "-0" { num = "0" }
        return "#h(\(num)\(typstUnit))"
    }

    // MARK: Symbols

    private mutating func symbolOrOperator(_ name: String) -> String {
        if let s = symbolMap[name] { return s }
        skipWhitespace()
        if peek() == "{" {
            return parseBraceGroup()
        }
        AnyTypLog.debug("math: dropping unsupported \\\(name)")
        return ""
    }

    /// LaTeX control sequence -> Typst math emission. Verified against codex
    /// sym.txt + typst-library 0.15.1 module table.
    private let symbolMap: [String: String] = [
        // ---- Greek -----------------------------------------------------
        "alpha": "alpha", "beta": "beta", "gamma": "gamma", "delta": "delta",
        "epsilon": "epsilon", "varepsilon": "\\u{03B5}", "zeta": "zeta",
        "eta": "eta", "theta": "theta", "vartheta": "\\u{03D1}",
        "iota": "iota", "kappa": "kappa", "lambda": "lambda", "mu": "mu",
        "nu": "nu", "xi": "xi", "omicron": "\\u{03BF}", "pi": "pi",
        "varpi": "\\u{03D6}", "rho": "rho", "varrho": "\\u{03F1}",
        "sigma": "sigma", "varsigma": "\\u{03C2}", "tau": "tau",
        "upsilon": "upsilon", "phi": "phi", "varphi": "\\u{03C6}",
        "chi": "chi", "psi": "psi", "omega": "omega",
        "Alpha": "Alpha", "Beta": "Beta", "Gamma": "Gamma", "Delta": "Delta",
        "Epsilon": "Epsilon", "Zeta": "Zeta", "Eta": "Eta", "Theta": "Theta",
        "Iota": "Iota", "Kappa": "Kappa", "Lambda": "Lambda", "Mu": "Mu",
        "Nu": "Nu", "Xi": "Xi", "Omicron": "\\u{039F}", "Pi": "Pi",
        "Rho": "Rho", "Sigma": "Sigma", "Tau": "Tau", "Upsilon": "Upsilon",
        "Phi": "Phi", "Chi": "Chi", "Psi": "Psi", "Omega": "Omega",
        "digamma": "\\u{03DD}", "Digamma": "\\u{03DC}",
        "beth": "beth", "gimel": "gimel", "daleth": "daleth",
        "hbar": "planck", "hslash": "\\u{210F}", "ell": "ell", "wp": "\\u{2118}",
        "Re": "Re", "Im": "Im", "aleph": "aleph", "partial": "partial",
        "nabla": "nabla", "gradient": "gradient", "infty": "oo",
        "prime": "prime", "emptyset": "emptyset", "varnothing": "emptyset",
        "complement": "complement", "therefore": "therefore",
        "because": "because", "qed": "qed", "top": "top", "bot": "bot",
        "angle": "angle", "measuredangle": "\\u{2221}",
        "sphericalangle": "\\u{2222}", "surd": "\\u{221A}",

        // ---- Relations / logic ------------------------------------------
        "leq": "\\u{2264}", "le": "\\u{2264}", "geq": "\\u{2265}",
        "ge": "\\u{2265}", "neq": "\\u{2260}", "ne": "\\u{2260}",
        "equiv": "equiv", "approx": "approx", "cong": "\\u{2245}",
        "sim": "\\u{223C}", "simeq": "\\u{2243}", "asymp": "asymp",
        "doteq": "\\u{2250}", "propto": "prop", "models": "models",
        "vdash": "\\u{22A2}", "dashv": "\\u{22A3}", "Vdash": "\\u{22A9}",
        "Vvdash": "\\u{22AA}", "nvdash": "\\u{22AC}", "nvDash": "\\u{22AD}",
        "nVdash": "\\u{22AE}", "nVDash": "\\u{22AF}", "perp": "perp",
        "parallel": "parallel", "nparallel": "\\u{2226}", "mid": "\\u{2223}",
        "nmid": "\\u{2224}", "smile": "smile", "frown": "frown",
        "bowtie": "bowtie", "Join": "\\u{22C8}", "between": "\\u{226C}",
        "pitchfork": "\\u{22D4}", "varpropto": "\\u{221D}",
        "smallsmile": "\\u{2323}", "smallfrown": "\\u{2322}",
        "bumpeq": "\\u{224F}", "Bumpeq": "\\u{224E}",
        "doteqdot": "\\u{2251}", "fallingdotseq": "\\u{2252}",
        "risingdotseq": "\\u{2253}", "eqcirc": "\\u{2256}",
        "circeq": "\\u{2257}", "triangleq": "\\u{225C}",
        "trianglelefteq": "\\u{22B4}", "trianglerighteq": "\\u{22B5}",
        "lesseqgtr": "\\u{22DA}", "gtreqless": "\\u{22DB}",
        "lesseqqgtr": "\\u{22DA}", "gtreqqless": "\\u{22DB}",
        "eqslantless": "\\u{2A95}", "eqslantgtr": "\\u{2A96}",
        "curlyeqprec": "\\u{22DE}", "curlyeqsucc": "\\u{22DF}",
        "precsim": "\\u{227E}", "succsim": "\\u{227F}",
        "precapprox": "\\u{2A7E}", "succapprox": "\\u{2A7F}",
        "precnapprox": "\\u{2A7C}", "succnapprox": "\\u{2A7D}",
        "precneqq": "\\u{2AB5}", "succneqq": "\\u{2AB6}",
        "precnsim": "\\u{22E0}", "succnsim": "\\u{22E1}",
        "precneq": "\\u{2AB9}", "succneq": "\\u{2ABA}",
        "prec": "prec", "succ": "succ", "preceq": "\\u{227A}",
        "succeq": "\\u{227B}", "ll": "\\u{226A}", "gg": "\\u{226B}",
        "subseteq": "\\u{2286}", "supseteq": "\\u{2287}",
        "nsubseteq": "\\u{2288}", "nsupseteq": "\\u{2289}",
        "subsetneq": "\\u{228A}", "supsetneq": "\\u{228B}",
        "sqsubseteq": "\\u{228F}", "sqsupseteq": "\\u{2290}",
        "nsubset": "\\u{2284}", "nsupset": "\\u{2285}",
        "subset": "subset", "supset": "supset",
        "in": "in", "ni": "\\u{220B}", "owns": "\\u{220B}",
        "notin": "\\u{2209}", "forall": "forall", "exists": "exists",
        "nexists": "\\u{2204}", "neg": "not", "lnot": "not", "land": "and",
        "wedge": "and", "lor": "or", "vee": "or", "oplus": "\\u{2295}",
        "ominus": "\\u{2296}", "otimes": "\\u{2297}", "oslash": "\\u{2298}",
        "odot": "\\u{2299}", "circledast": "\\u{229B}", "circledcirc": "\\u{229A}",
        "circleddash": "\\u{229D}", "boxplus": "\\u{229E}", "boxminus": "\\u{229F}",
        "boxtimes": "\\u{22A0}", "boxdot": "\\u{22A1}", "intercal": "\\u{22BA}",
        "barwedge": "\\u{22BC}", "doublebarwedge": "\\u{2A5E}",
        "veebar": "\\u{22BF}", "curlywedge": "\\u{22CF}", "curlyvee": "\\u{22CE}",
        "Cap": "\\u{22D2}", "Cup": "\\u{22D3}", "doublecap": "\\u{22C0}",
        "doublecup": "\\u{22C1}", "sqcap": "\\u{2293}", "sqcup": "\\u{2294}",
        "uplus": "\\u{228E}", "dotplus": "\\u{2214}",
        "divideontimes": "\\u{22C7}", "ltimes": "\\u{22C9}",
        "rtimes": "\\u{22CA}", "leftthreetimes": "\\u{22CB}",
        "rightthreetimes": "\\u{22CC}", "smallsetminus": "\\u{2216}",
        "setminus": "without", "wr": "\\u{2240}",
        "bigtriangleup": "\\u{25B2}", "bigtriangledown": "\\u{25BC}",
        "triangleleft": "\\u{25C1}", "triangleright": "\\u{25B7}",
        "triangle": "\\u{25B3}", "triangledown": "\\u{25BD}",
        "blacktriangle": "\\u{25B2}", "blacktriangledown": "\\u{25BC}",
        "blacktriangleleft": "\\u{25C0}", "blacktriangleright": "\\u{25B6}",
        "lozenge": "lozenge", "blacklozenge": "\\u{25CA}",
        "Diamond": "\\u{25CA}", "diamond": "\\u{25C7}",
        "Diamondblack": "\\u{25C6}", "square": "\\u{25A1}",
        "blacksquare": "\\u{25A0}", "Box": "\\u{25A1}",
        "bigstar": "\\u{2605}", "star": "\\u{22C6}", "ast": "\\u{2217}",
        "circ": "compose", "bullet": "bullet", "cdot": "\\u{22C5}",
        "centerdot": "\\u{22C5}", "times": "times", "div": "div",
        "pm": "\\u{00B1}", "mp": "\\u{2213}", "dagger": "dagger",
        "ddagger": "\\u{2021}", "amalg": "\\u{2A3F}", "diamondmath": "\\u{22C4}",

        // ---- Arrows ------------------------------------------------------
        "to": "->", "rightarrow": "->", "leftarrow": "<-", "gets": "<-",
        "leftrightarrow": "<->", "mapsto": "|->", "hookrightarrow": "\\u{21AA}",
        "hookleftarrow": "\\u{21A9}", "Rightarrow": "\\u{21D2}",
        "Leftarrow": "\\u{21D0}", "Leftrightarrow": "\\u{21D4}",
        "implies": "\\u{21D2}", "impliedby": "\\u{21D0}", "iff": "\\u{21D4}",
        "longrightarrow": "-->", "longleftarrow": "<--",
        "Longrightarrow": "==>", "Longleftarrow": "\\u{27F8}",
        "Longleftrightarrow": "\\u{27FA}", "longleftrightarrow": "<-->",
        "uparrow": "\\u{2191}", "downarrow": "\\u{2193}",
        "updownarrow": "\\u{2195}", "Uparrow": "\\u{21D1}",
        "Downarrow": "\\u{21D3}", "Updownarrow": "\\u{21D5}",
        "nearrow": "\\u{2197}", "searrow": "\\u{2198}", "swarrow": "\\u{2199}",
        "nwarrow": "\\u{2196}", "leadsto": "\\u{21DD}",
        "rightsquigarrow": "\\u{21DD}", "leftrightsquigarrow": "\\u{21AD}",
        "dashrightarrow": "\\u{21E2}", "dashleftarrow": "\\u{21E0}",
        "rightleftharpoons": "\\u{21CC}", "leftrightharpoons": "\\u{21CB}",
        "rightleftharpoonup": "\\u{21CF}",
        "leftharpoonup": "\\u{21BC}", "leftharpoondown": "\\u{21BD}",
        "rightharpoonup": "\\u{21C0}", "rightharpoondown": "\\u{21C1}",
        "Lsh": "\\u{21B0}", "Rsh": "\\u{21B1}", "looparrowright": "\\u{21AC}",
        "looparrowleft": "\\u{21AB}", "curvearrowright": "\\u{21B7}",
        "curvearrowleft": "\\u{21B6}", "circlearrowright": "\\u{21BB}",
        "circlearrowleft": "\\u{21BA}", "twoheadrightarrow": "\\u{21A0}",
        "twoheadleftarrow": "\\u{219E}", "leftarrowtail": "\\u{21A2}",
        "rightarrowtail": "\\u{21A3}", "multimap": "multimap",
        "restriction": "\\u{21BE}", "nleftarrow": "\\u{21CD}",
        "nrightarrow": "\\u{21CF}",

        // ---- Big operators -----------------------------------------------
        "sum": "sum", "prod": "product", "coprod": "\\u{2210}",
        "int": "integral", "iint": "\\u{222C}", "iiint": "\\u{222D}",
        "iiiint": "\\u{2A0C}", "oint": "\\u{222E}", "oiint": "\\u{222F}",
        "oiiint": "\\u{2230}", "intop": "integral", "ointop": "\\u{222E}",
        "bigcup": "\\u{22C3}", "bigcap": "\\u{22C2}", "bigoplus": "\\u{2A01}",
        "bigotimes": "\\u{2A02}", "bigodot": "\\u{2A00}", "biguplus": "\\u{2A04}",
        "bigsqcup": "\\u{2A06}", "bigvee": "\\u{22C1}", "bigwedge": "\\u{22C0}",

        // ---- Delimiters ----------------------------------------------------
        "langle": "\\u{27E8}", "rangle": "\\u{27E9}", "lfloor": "\\u{230A}",
        "rfloor": "\\u{230B}", "lceil": "\\u{2308}", "rceil": "\\u{2309}",
        "lVert": "\\u{2016}", "rVert": "\\u{2016}", "Vert": "\\u{2016}",
        "vert": "|", "lvert": "|", "rvert": "|", "lbrace": "\\u{007B}",
        "rbrace": "\\u{007D}", "lbrack": "[", "rbrack": "]", "lparen": "(",
        "rparen": ")", "lmoustache": "\\u{23B0}", "rmoustache": "\\u{23B1}",
        "bracevert": "|", "arrowvert": "\\u{23D0}", "Arrowvert": "\\u{2016}",
        "ulcorner": "\\u{231C}", "urcorner": "\\u{231D}",
        "llcorner": "\\u{231E}", "lrcorner": "\\u{231F}",
        "lgroup": "\\u{27EE}", "rgroup": "\\u{27EF}", "backslash": "\\u{005C}",

        // ---- Misc ---------------------------------------------------------
        "ldots": "\\u{2026}", "cdots": "\\u{22EF}", "vdots": "\\u{22EE}",
        "ddots": "\\u{22F1}", "dots": "\\u{2026}", "colon": ":",
        "ldotp": ".", "cdotp": ".",
        "degree": "\\u{00B0}", "checkmark": "\\u{2713}",
        "maltese": "\\u{2720}", "yen": "\\u{00A5}", "euro": "\\u{20AC}",
        "pounds": "\\u{00A3}", "textsterling": "\\u{00A3}",
        "copyright": "\\u{00A9}", "textregistered": "\\u{00AE}",
        "texttrademark": "\\u{2122}", "textcopyright": "\\u{00A9}",
        "textpercent": "%", "textbullet": "\\u{2022}",
        "textquotedblleft": "\\u{201C}", "textquotedblright": "\\u{201D}",
        "textquoteleft": "\\u{2018}", "textquoteright": "\\u{2019}",
        "guillemotleft": "\\u{00AB}", "guillemotright": "\\u{00BB}",
        "guilsinglleft": "\\u{2039}", "guilsinglright": "\\u{203A}",
        "textellipsis": "\\u{2026}", "textendash": "\\u{2013}",
        "textemdash": "\\u{2014}", "textminus": "\\u{2212}",
        "texttimes": "\\u{00D7}", "textdiv": "\\u{00F7}",
        "textasciiacute": "\\u{00B4}", "textasciigrave": "`",
        "textasciitilde": "\\u{02DC}", "textasciicircum": "^",
        "textquestiondown": "\\u{00BF}", "i": "dotless.i",
        "j": "dotless.j", "imath": "dotless.i", "jmath": "dotless.j",
        "Bbbk": "\\u{2124}", "Finv": "\\u{2132}", "Game": "\\u{2141}",
        "eth": "\\u{00F0}", "mho": "\\u{2127}",
        "section": "\\u{00A7}", "P": "\\u{00B6}", "S": "\\u{00A7}",
        "dag": "\\u{2020}", "ddag": "\\u{2021}",

        // ---- Punctuation escapes ------------------------------------------
        "%": "\\u{0025}", "_": "\\u{005F}", "{": "\\u{007B}", "}": "\\u{007D}",
        "#": "\\u{0023}", "$": "\\u{0024}", "&": "\\u{0026}",
    ]

    // MARK: - Helpers

    /// Sanitize converted arg content for embedding inside a Typst math call
    /// `f(...)`: protect top-level `,` `;` `)` `]` `&` that would break or
    /// corrupt the argument list. Strings and `#expr`s are skipped.
    private func sanitizeArg(_ s: String) -> String {
        var out = ""
        var depth = 0
        var inString = false
        var inCode = false
        var codeDepth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let nextIdx = s.index(after: i)
            let next = nextIdx < s.endIndex ? s[nextIdx] : nil

            if inString {
                out.append(c)
                if c == "\\", let n = next {
                    out.append(n)
                    i = s.index(i, offsetBy: 2)
                    continue
                }
                if c == "\"" { inString = false }
                i = s.index(after: i)
                continue
            }
            if inCode {
                out.append(c)
                if c == "\\", let n = next {
                    out.append(n); i = s.index(i, offsetBy: 2); continue
                }
                if c == "\"" { inString = true; i = s.index(after: i); continue }
                if c == "(" || c == "[" { codeDepth += 1 }
                if c == ")" || c == "]" {
                    codeDepth -= 1
                    if codeDepth <= 0 { inCode = false; codeDepth = 0 }
                }
                i = s.index(after: i)
                continue
            }
            if c == "#" {
                inCode = true
                codeDepth = 0
                out.append(c)
                i = s.index(after: i)
                continue
            }
            if c == "\\" {
                out.append(c)
                i = s.index(after: i)
                if i < s.endIndex {
                    let e = s[i]
                    out.append(e)
                    i = s.index(after: i)
                    if e == "u", i < s.endIndex, s[i] == "{" {
                        while i < s.endIndex {
                            let u = s[i]
                            out.append(u)
                            i = s.index(after: i)
                            if u == "}" { break }
                        }
                    }
                }
                continue
            }
            if c == "\"" { inString = true; out.append(c); i = s.index(after: i); continue }
            if c == "(" || c == "[" { depth += 1; out.append(c); i = s.index(after: i); continue }
            if c == ")" || c == "]" {
                if depth == 0 {
                    out += c == ")" ? "\\)" : "\\]"
                } else {
                    depth -= 1
                    out.append(c)
                }
                i = s.index(after: i)
                continue
            }
            if depth == 0 {
                switch c {
                case ",": out += "comma"; i = s.index(after: i); continue
                case ";": out += "semi"; i = s.index(after: i); continue
                case "&": out += "\\&"; i = s.index(after: i); continue
                default: break
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Tidying (ported from math.rs)

private func collapseNewlines(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var prevSpace = false
    for ch in s {
        if ch == "\n" || ch == "\r" {
            if !prevSpace {
                out.append(" ")
                prevSpace = true
            }
        } else {
            prevSpace = ch == " "
            out.append(ch)
        }
    }
    return out
}

/// Clean redundant whitespace (`frac(1 ,2 )` -> `frac(1, 2)`) outside strings.
private func tidyMathSpacing(_ s: String) -> String {
    let chars = Array(s)
    var out = ""
    out.reserveCapacity(s.count)
    var inString = false
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "\"", i == 0 || chars[i - 1] != "\\" {
            inString.toggle()
            out.append(ch)
            i += 1
            continue
        }
        if inString {
            out.append(ch)
            i += 1
            continue
        }
        if ch == " " {
            let prevBackslash = out.hasSuffix("\\")
            while i + 1 < chars.count, chars[i + 1] == " " { i += 1 }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if !prevBackslash, let n = next, n == "," || n == ")" || n == ";" || n == "^" || n == "_" {
                i += 1
                continue
            }
            if !prevBackslash, out.hasSuffix("(") {
                i += 1
                continue
            }
            let prevChar = out.last
            if !prevBackslash {
                let digitJoin = prevChar?.isNumber == true
                    && (next?.isNumber == true
                        || (next == "." && i + 2 < chars.count
                            && (chars[i + 2].isNumber || chars[i + 2] == " ")))
                let prev2 = out.count >= 2 ? out[out.index(out.endIndex, offsetBy: -2)] : nil
                let dotJoin = prevChar == "." && prev2?.isNumber == true
                    && next?.isNumber == true
                if digitJoin || dotJoin {
                    i += 1
                    continue
                }
            }
            out.append(" ")
            i += 1
            continue
        }
        if ch == ",", i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != "\n" {
            out += ", "
            i += 1
            continue
        }
        out.append(ch)
        i += 1
    }
    return simplifySingleCharScripts(out)
}

/// `x^(a)` -> `x^a` when the script arg is a single char.
private func simplifySingleCharScripts(_ s: String) -> String {
    let chars = Array(s)
    var out = ""
    out.reserveCapacity(s.count)
    var inString = false
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "\"", i == 0 || chars[i - 1] != "\\" {
            inString.toggle()
            out.append(ch)
            i += 1
            continue
        }
        if !inString,
           ch == "^" || ch == "_",
           i + 1 < chars.count, chars[i + 1] == "(",
           i + 2 < chars.count, chars[i + 2].isLetter || chars[i + 2].isNumber,
           i + 3 < chars.count, chars[i + 3] == ")",
           i + 4 >= chars.count || !(chars[i + 4].isLetter || chars[i + 4].isNumber || chars[i + 4] == "(") {
            out.append(ch)
            out.append(chars[i + 2])
            i += 4
            continue
        }
        out.append(ch)
        i += 1
    }
    return out
}
