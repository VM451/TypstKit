import Foundation

/// Presentation MathML to LaTeX (port of `shared/math/mathml.rs`), for EPUB
/// chapters and OpenDocument formula objects.

enum MathML {
    /// A `math` element as LaTeX source without delimiters.
    static func toTex(_ math: XmlElement) -> String {
        let tex = Tex()
        walkChildren(math, tex)
        return tex.finish()
    }

    /// Whether a `math` element asks for display (block) layout.
    static func isDisplay(_ math: XmlElement) -> Bool {
        math.attrAny("display") == "block"
    }

    private static func walkChildren(_ elem: XmlElement, _ tex: Tex) {
        for node in elem.children {
            if case .element(let child) = node {
                walkElem(child, tex)
            }
        }
    }

    /// Child elements, skipping nothing: MathML layout schemata count their
    /// arguments by position.
    private static func args(_ elem: XmlElement) -> [XmlElement] {
        elem.childElems
    }

    private static func sub(_ elem: XmlElement) -> Tex {
        let tex = Tex()
        walkElem(elem, tex)
        return tex
    }

    private static func subChildren(_ elem: XmlElement) -> Tex {
        let tex = Tex()
        walkChildren(elem, tex)
        return tex
    }

    private static func walkElem(_ e: XmlElement, _ tex: Tex) {
        switch e.local {
        case "semantics":
            if let annotation = texAnnotation(e) {
                tex.pushStr(annotation)
            } else if let first = e.childElems.first(where: {
                $0.local != "annotation" && $0.local != "annotation-xml"
            }) {
                walkElem(first, tex)
            }
        case "annotation", "annotation-xml":
            break
        case "mi": identifier(e, tex)
        case "mn": tex.pushMathText(e.text)
        case "mo": operatorElem(e, tex)
        case "mtext":
            let text = e.text
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                tex.pushTextMode(String(text.drop(while: { $0 == "\n" || $0 == "\r" })
                    .reversed().drop(while: { $0 == "\n" || $0 == "\r" }).reversed()))
            }
        case "ms":
            let text = e.text
            let trimmed = String(text.drop(while: { $0 == "\n" || $0 == "\r" })
                .reversed().drop(while: { $0 == "\n" || $0 == "\r" }).reversed())
            let quoted = "\(e.attrAny("lquote") ?? "\"")\(trimmed)\(e.attrAny("rquote") ?? "\"")"
            tex.pushTextMode(quoted)
        case "mspace":
            // Only the sign of the width survives.
            let width = (e.attrAny("width") ?? "0").trimmingCharacters(in: .whitespaces)
            let negative = width.hasPrefix("-") || width.hasPrefix("negative")
            var magnitudeStr = ""
            for ch in width.drop(while: { $0 == "-" }) {
                if ch.isASCII && (ch.isNumber || ch == ".") { magnitudeStr.append(ch) } else { break }
            }
            let magnitude = Double(magnitudeStr) ?? 1.0
            if magnitude == 0.0 {
                // nothing
            } else if negative {
                tex.pushStr("\\!")
            } else {
                tex.pushStr("\\ ")
            }
        case "mfrac":
            let parts = args(e)
            guard parts.count >= 2, let num = parts.first, let den = parts.dropFirst().first else {
                walkChildren(e, tex)
                return
            }
            let numTex = sub(num)
            let denTex = sub(den)
            if e.attrAny("bevelled") == "true" {
                tex.pushGroup(numTex)
                tex.pushChar("/")
                tex.pushGroup(denTex)
            } else if let t = e.attrAny("linethickness"), ["0", "0px"].contains(t.trimmingCharacters(in: .whitespaces)) {
                tex.pushChar("{")
                tex.pushTex(numTex)
                tex.pushMacro("\\atop")
                tex.pushTex(denTex)
                tex.pushChar("}")
            } else {
                tex.pushMacro("\\frac")
                tex.pushGroup(numTex)
                tex.pushGroup(denTex)
            }
        case "msqrt":
            tex.pushCommand("\\sqrt", subChildren(e))
        case "mroot":
            let parts = args(e)
            tex.pushMacro("\\sqrt")
            if parts.count > 1 {
                tex.pushChar("[")
                tex.pushTex(sub(parts[1]))
                tex.pushChar("]")
            }
            if let base = parts.first {
                tex.pushGroup(sub(base))
            }
        case "msup", "msub", "msubsup": scripts(e, tex)
        case "munder", "mover", "munderover": underOver(e, tex)
        case "mmultiscripts": multiscripts(e, tex)
        case "mfenced":
            let open = e.attrAny("open") ?? "("
            let close = e.attrAny("close") ?? ")"
            let seps = Array((e.attrAny("separators") ?? ",").filter { !$0.isWhitespace })
            tex.pushMacro("\\left")
            tex.pushStr(open.first.map { mathDelimiter($0) } ?? ".")
            for (i, part) in e.childElems.enumerated() {
                if i > 0, !seps.isEmpty {
                    // The last separator repeats for any further arguments.
                    let sepIdx = min(i - 1, seps.count - 1)
                    tex.pushMathChar(seps[sepIdx])
                }
                tex.pushTex(sub(part))
            }
            tex.pushMacro("\\right")
            tex.pushStr(close.first.map { mathDelimiter($0) } ?? ".")
        case "mtable": table(e, tex)
        case "mphantom":
            tex.pushCommand("\\phantom", subChildren(e))
        case "menclose":
            let notation = e.attrAny("notation") ?? "longdiv"
            let inner = subChildren(e)
            switch notation.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) {
            case "box", "roundedbox": tex.pushCommand("\\boxed", inner)
            case "top": tex.pushCommand("\\overline", inner)
            case "bottom", "underline": tex.pushCommand("\\underline", inner)
            case "horizontalstrike", "updiagonalstrike", "downdiagonalstrike":
                tex.pushCommand("\\cancel", inner)
            default: tex.pushGroup(inner)
            }
        case "mglyph", "maligngroup", "malignmark", "none", "mprescripts":
            break
        default:
            walkChildren(e, tex)
        }
    }

    private static func texAnnotation(_ semantics: XmlElement) -> String? {
        for a in semantics.childElems where a.local == "annotation" {
            if let enc = a.attrAny("encoding") {
                let e = enc.trimmingCharacters(in: .whitespaces).lowercased()
                if ["application/x-tex", "tex", "latex", "application/x-latex"].contains(e) {
                    let t = a.text.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { return t }
                }
            }
        }
        return nil
    }

    private static func identifier(_ e: XmlElement, _ tex: Tex) {
        let text = e.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return }
        let variant = e.attrAny("mathvariant")
        let single = text.count == 1
        // A multi-letter identifier renders upright.
        if !single, variant == nil || variant == "normal", text.allSatisfy({ $0.isLetter }) {
            if let name = mathFunctionName(text) {
                tex.pushMacro(name)
            } else {
                let inner = Tex()
                inner.pushMathText(text)
                tex.pushCommand("\\mathrm", inner)
            }
            return
        }
        let inner = Tex()
        inner.pushMathText(text)
        if let v = variant.flatMap(Variant.fromMathvariant) {
            tex.pushCommand(v.command, inner)
        } else if variant == "normal", single {
            tex.pushCommand("\\mathrm", inner)
        } else {
            tex.pushTex(inner)
        }
    }

    private static func operatorElem(_ e: XmlElement, _ tex: Tex) {
        let text = e.text.trimmingCharacters(in: .whitespaces)
        if text.count > 1, text.allSatisfy({ $0.isASCII && $0.isLetter }),
           let name = mathFunctionName(text) {
            tex.pushMacro(name)
            return
        }
        tex.pushMathText(text)
    }

    private static func scripts(_ e: XmlElement, _ tex: Tex) {
        let parts = args(e)
        guard let base = parts.first else { return }
        let baseTex = sub(base)
        if isBigOperator(base) {
            tex.pushTex(baseTex)
        } else {
            tex.pushBase(baseTex)
        }
        switch e.local {
        case "msup": script(tex, mark: "^", arg: parts.dropFirst().first)
        case "msub": script(tex, mark: "_", arg: parts.dropFirst().first)
        default:
            script(tex, mark: "_", arg: parts.count > 1 ? parts[1] : nil)
            script(tex, mark: "^", arg: parts.count > 2 ? parts[2] : nil)
        }
    }

    private static func script(_ tex: Tex, mark: Character, arg: XmlElement?) {
        guard let arg else { return }
        tex.pushChar(mark)
        tex.pushGroup(sub(arg))
    }

    private static func underOver(_ e: XmlElement, _ tex: Tex) {
        let parts = args(e)
        guard let base = parts.first else { return }
        let under: XmlElement? = switch e.local {
        case "munder": parts.count > 1 ? parts[1] : nil
        case "mover": nil
        default: parts.count > 1 ? parts[1] : nil
        }
        let over: XmlElement? = switch e.local {
        case "mover": parts.count > 1 ? parts[1] : nil
        case "munder": nil
        default: parts.count > 2 ? parts[2] : nil
        }
        // Limits on a big operator or named function take script form.
        if isBigOperator(base) || isNamedFunction(base) {
            tex.pushTex(sub(base))
            script(tex, mark: "_", arg: under)
            script(tex, mark: "^", arg: over)
            return
        }
        let plainOver = e.attrAny("accent") == "false"
        let plainUnder = e.attrAny("accentunder") == "false"
        var body = sub(base)
        if let over {
            body = decorate(over, body: body, over: true, plain: plainOver)
        }
        if let under {
            body = decorate(under, body: body, over: false, plain: plainUnder)
        }
        tex.pushTex(body)
    }

    /// `body` with `mark` placed over or under it.
    private static func decorate(_ mark: XmlElement, body: Tex, over: Bool, plain: Bool) -> Tex {
        let out = Tex()
        let text = mark.text.trimmingCharacters(in: .whitespaces)
        if !plain, text.count == 1, let c = text.first, let cmd = mathAccent(c) {
            let resolved: String
            switch (cmd, over) {
            case ("\\underline", true): resolved = "\\overline"
            case ("\\overline", false): resolved = "\\underline"
            case ("\\underbrace", true): resolved = "\\overbrace"
            case ("\\overbrace", false): resolved = "\\underbrace"
            default: resolved = cmd
            }
            out.pushCommand(resolved, body)
            return out
        }
        out.pushMacro(over ? "\\overset" : "\\underset")
        out.pushGroup(sub(mark))
        out.pushGroup(body)
        return out
    }

    private static func multiscripts(_ e: XmlElement, _ tex: Tex) {
        let parts = args(e)
        guard let base = parts.first else { return }
        let rest = Array(parts.dropFirst())
        let split = rest.firstIndex { $0.local == "mprescripts" } ?? rest.count
        let post = Array(rest[..<split])
        var pre = Array(rest[split...])
        if !pre.isEmpty { pre.removeFirst() }
        var i = 0
        while i < pre.count {
            tex.pushStr("{}")
            scriptPair(tex, pair: Array(pre[i..<min(i + 2, pre.count)]))
            i += 2
        }
        tex.pushGroup(sub(base))
        i = 0
        while i < post.count {
            scriptPair(tex, pair: Array(post[i..<min(i + 2, post.count)]))
            i += 2
        }
    }

    private static func scriptPair(_ tex: Tex, pair: [XmlElement]) {
        if let subEl = pair.first, subEl.local != "none" {
            tex.pushChar("_")
            tex.pushGroup(sub(subEl))
        }
        if pair.count > 1, pair[1].local != "none" {
            tex.pushChar("^")
            tex.pushGroup(sub(pair[1]))
        }
    }

    private static func table(_ e: XmlElement, _ tex: Tex) {
        tex.pushStr("\\begin{matrix}")
        let rows = e.childElems.filter { ["mtr", "mlabeledtr"].contains($0.local) }
        for (i, row) in rows.enumerated() {
            if i > 0 { tex.pushStr(" \\\\") }
            let cells = row.childElems.filter { $0.local == "mtd" }
            for (j, cell) in cells.enumerated() {
                tex.pushStr(j > 0 ? " & " : " ")
                tex.pushTex(subChildren(cell))
            }
        }
        tex.pushStr(" \\end{matrix}")
    }

    /// An `mo` holding an n-ary operator.
    private static func isBigOperator(_ e: XmlElement) -> Bool {
        guard e.local == "mo" else { return false }
        let text = e.text.trimmingCharacters(in: .whitespaces)
        let chars = Array(text)
        guard chars.count == 1, let s = mathSymbol(chars[0]) else { return false }
        return ["\\sum", "\\prod", "\\coprod", "\\int", "\\iint", "\\iiint", "\\iiiint",
                "\\oint", "\\oiint", "\\oiiint", "\\bigcup", "\\bigcap", "\\bigvee",
                "\\bigwedge", "\\bigoplus", "\\bigotimes", "\\bigodot", "\\biguplus",
                "\\bigsqcup"].contains(s)
    }

    /// An `mi` or `mo` naming a function that takes limits.
    private static func isNamedFunction(_ e: XmlElement) -> Bool {
        guard ["mi", "mo"].contains(e.local) else { return false }
        let text = e.text.trimmingCharacters(in: .whitespaces)
        return text.count > 1 && mathFunctionName(text) != nil
    }
}
