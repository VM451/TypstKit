import Foundation

/// Office Math (OMML) to LaTeX (port of `shared/math/omml.rs`). The same
/// element tree serves docx and pptx directly, and rtf through its math
/// destinations.

enum Omml {
    /// One `m:oMath` as LaTeX source without delimiters.
    static func toTex(_ omath: XmlElement) -> String {
        let tex = Tex()
        walkChildren(omath, tex, mode: .math)
        return tex.finish()
    }

    /// The equations of an `m:oMathPara`, one per `m:oMath` line.
    static func paraToTex(_ para: XmlElement) -> [String] {
        var lines = para.descendants(XmlNS.m, "oMath").map(toTex).filter { !$0.isEmpty }
        if lines.isEmpty {
            let whole = toTex(para)
            lines = whole.isEmpty ? [] : [whole]
        }
        return lines
    }

    private enum Mode {
        case math
        /// Inside `m:fName`: run text names a function (`\sin`, `\lim`).
        case funcName
        /// Inside an equation-array row: `&` marks an alignment point.
        case array
    }

    private static func walkChildren(_ elem: XmlElement, _ tex: Tex, mode: Mode) {
        for child in elem.childElems {
            walkElem(child, tex, mode: mode)
        }
    }

    private static func walkElem(_ e: XmlElement, _ tex: Tex, mode: Mode) {
        if e.ns != XmlNS.m {
            // Revision and bookmark markup from the host document.
            switch e.local {
            case "del", "moveFrom", "rPr", "pPr": break
            default: walkChildren(e, tex, mode: mode)
            }
            return
        }
        switch e.local {
        case "r": run(e, tex, mode: mode)
        case "t": tex.pushMathText(e.text)
        case "f": fraction(e, tex)
        case "sSup":
            tex.pushBase(arg(e, "e", mode: .math))
            tex.pushChar("^")
            tex.pushGroup(arg(e, "sup", mode: .math))
        case "sSub":
            tex.pushBase(arg(e, "e", mode: .math))
            tex.pushChar("_")
            tex.pushGroup(arg(e, "sub", mode: .math))
        case "sSubSup":
            tex.pushBase(arg(e, "e", mode: .math))
            tex.pushChar("_")
            tex.pushGroup(arg(e, "sub", mode: .math))
            tex.pushChar("^")
            tex.pushGroup(arg(e, "sup", mode: .math))
        case "sPre":
            tex.pushStr("{}_")
            tex.pushGroup(arg(e, "sub", mode: .math))
            tex.pushChar("^")
            tex.pushGroup(arg(e, "sup", mode: .math))
            tex.pushGroup(arg(e, "e", mode: .math))
        case "rad":
            let deg = arg(e, "deg", mode: .math)
            tex.pushMacro("\\sqrt")
            if flag(e, "radPr", "degHide") != true, !deg.isEmpty {
                tex.pushChar("[")
                tex.pushTex(deg)
                tex.pushChar("]")
            }
            tex.pushGroup(arg(e, "e", mode: .math))
        case "d": delimited(e, tex)
        case "nary": nary(e, tex)
        case "func":
            if let name = e.find(XmlNS.m, "fName") {
                walkChildren(name, tex, mode: .funcName)
            }
            tex.pushGroup(arg(e, "e", mode: .math))
        case "acc":
            let chr = prop(e, "accPr", "chr").flatMap { $0.first } ?? "\u{302}"
            tex.pushCommand(mathAccent(chr) ?? "\\hat", arg(e, "e", mode: .math))
        case "bar":
            let top = prop(e, "barPr", "pos").map { $0 == "top" } ?? false
            tex.pushCommand(top ? "\\overline" : "\\underline", arg(e, "e", mode: .math))
        case "borderBox":
            tex.pushCommand("\\boxed", arg(e, "e", mode: .math))
        case "phant" where flag(e, "phantPr", "show") == false:
            tex.pushCommand("\\phantom", arg(e, "e", mode: .math))
        case "box", "phant":
            tex.pushGroup(arg(e, "e", mode: mode))
        case "groupChr": groupChar(e, tex)
        case "limLow", "limUpp": limit(e, tex, mode: mode)
        case "m": matrix(e, tex)
        case "eqArr": equationArray(e, tex)
        default:
            if e.local.hasSuffix("Pr") {
                break
            }
            walkChildren(e, tex, mode: mode)
        }
    }

    /// Child argument `name` of `parent`, converted on its own.
    private static func arg(_ parent: XmlElement, _ name: String, mode: Mode) -> Tex {
        let tex = Tex()
        if let child = parent.find(XmlNS.m, name) {
            walkChildren(child, tex, mode: mode)
        }
        return tex
    }

    /// A property value: `parent/pr/name/@m:val`, or the element's own text
    /// where the tree came from rtf.
    private static func prop(_ parent: XmlElement, _ pr: String, _ name: String) -> String? {
        guard let elem = parent.find(XmlNS.m, pr)?.find(XmlNS.m, name) else { return nil }
        if let v = elem.attr(XmlNS.m, "val") { return v }
        return directText(elem).trimmingCharacters(in: .whitespaces)
    }

    /// An on/off property: absent is `nil`; present with no value is on.
    private static func flag(_ parent: XmlElement, _ pr: String, _ name: String) -> Bool? {
        guard let value = prop(parent, pr, name) else { return nil }
        return !["0", "off", "false"].contains(value)
    }

    private static func directText(_ elem: XmlElement) -> String {
        var out = ""
        for node in elem.children {
            if case .text(let t) = node { out += t }
        }
        return out
    }

    /// A run's text: its `m:t` children, or its own text where the tree came
    /// from rtf.
    private static func runText(_ r: XmlElement) -> String {
        var fromT = ""
        var hasT = false
        for t in r.findAll(XmlNS.m, "t") {
            hasT = true
            fromT += t.text
        }
        if hasT { return fromT }
        let direct = directText(r)
        return direct.trimmingCharacters(in: .whitespaces).isEmpty ? "" : direct
    }

    private static func run(_ r: XmlElement, _ tex: Tex, mode: Mode) {
        let text = runText(r)
        if text.isEmpty { return }
        // Run properties sit under `m:rPr`; rtf writes them on the run
        // itself, with `sty` and `scr` as numbers in their enumeration order.
        func value(_ name: String) -> String? {
            guard let elem = r.find(XmlNS.m, "rPr")?.find(XmlNS.m, name) ?? r.find(XmlNS.m, name)
            else { return nil }
            if let v = elem.attr(XmlNS.m, "val") { return v }
            return directText(elem).trimmingCharacters(in: .whitespaces)
        }
        if let nor = value("nor"), !["0", "off", "false"].contains(nor) {
            tex.pushTextMode(text)
            return
        }
        if mode == .funcName, let name = mathFunctionName(text) {
            tex.pushMacro(name)
            return
        }
        let font: String? = {
            switch value("scr") {
            case "script", "1": return "\\mathcal"
            case "fraktur", "2": return "\\mathfrak"
            case "double-struck", "3": return "\\mathbb"
            case "sans-serif", "4": return "\\mathsf"
            case "monospace", "5": return "\\mathtt"
            default:
                switch value("sty") {
                case "p", "0": return "\\mathrm"
                case "b", "1": return "\\mathbf"
                case "bi", "3": return "\\boldsymbol"
                default: return nil
                }
            }
        }()
        let inner = Tex()
        if mode == .array {
            for (i, piece) in text.split(separator: "&", omittingEmptySubsequences: false).enumerated() {
                if i > 0 { inner.pushStr(" & ") }
                inner.pushMathText(String(piece))
            }
        } else {
            inner.pushMathText(text)
        }
        if let font {
            tex.pushCommand(font, inner)
        } else {
            tex.pushTex(inner)
        }
    }

    private static func fraction(_ e: XmlElement, _ tex: Tex) {
        let num = arg(e, "num", mode: .math)
        let den = arg(e, "den", mode: .math)
        switch prop(e, "fPr", "type") {
        case "lin":
            tex.pushGroup(num)
            tex.pushChar("/")
            tex.pushGroup(den)
        case "skw":
            tex.pushStr("{}^")
            tex.pushGroup(num)
            tex.pushStr("/_")
            tex.pushGroup(den)
        case "noBar":
            tex.pushChar("{")
            tex.pushTex(num)
            tex.pushMacro("\\atop")
            tex.pushTex(den)
            tex.pushChar("}")
        default:
            tex.pushMacro("\\frac")
            tex.pushGroup(num)
            tex.pushGroup(den)
        }
    }

    private static func delimited(_ e: XmlElement, _ tex: Tex) {
        // An explicitly empty character means no delimiter on that side.
        func chr(_ name: String, _ defaultCh: Character) -> Character? {
            switch prop(e, "dPr", name) {
            case .some(let v): return v.first
            case .none: return defaultCh
            }
        }
        let beg = chr("begChr", "(")
        let end = chr("endChr", ")")
        let sep = chr("sepChr", "|")
        tex.pushMacro("\\left")
        tex.pushStr(beg.map { mathDelimiter($0) } ?? ".")
        for (i, part) in e.findAll(XmlNS.m, "e").enumerated() {
            if i > 0 {
                if let sep {
                    tex.pushMacro("\\middle")
                    tex.pushStr(mathDelimiter(sep))
                } else {
                    tex.pushChar(",")
                }
            }
            let inner = Tex()
            walkChildren(part, inner, mode: .math)
            tex.pushTex(inner)
        }
        tex.pushMacro("\\right")
        tex.pushStr(end.map { mathDelimiter($0) } ?? ".")
    }

    private static func nary(_ e: XmlElement, _ tex: Tex) {
        let chr = prop(e, "naryPr", "chr").flatMap { $0.first } ?? "∫"
        if let op = mathSymbol(chr), op.hasPrefix("\\") {
            tex.pushMacro(op)
        } else {
            tex.pushMacro("\\operatorname*")
            let inner = Tex()
            inner.pushMathChar(chr)
            tex.pushGroup(inner)
        }
        let integral = ["∫", "∬", "∭", "⨌", "∮", "∯", "∰"].contains(chr)
        switch prop(e, "naryPr", "limLoc") {
        case "undOvr" where integral: tex.pushMacro("\\limits")
        case "subSup" where !integral: tex.pushMacro("\\nolimits")
        default: break
        }
        if flag(e, "naryPr", "subHide") != true {
            let sub = arg(e, "sub", mode: .math)
            if !sub.isEmpty {
                tex.pushChar("_")
                tex.pushGroup(sub)
            }
        }
        if flag(e, "naryPr", "supHide") != true {
            let sup = arg(e, "sup", mode: .math)
            if !sup.isEmpty {
                tex.pushChar("^")
                tex.pushGroup(sup)
            }
        }
        tex.pushGroup(arg(e, "e", mode: .math))
    }

    private static func groupChar(_ e: XmlElement, _ tex: Tex) {
        let chr = prop(e, "groupChrPr", "chr").flatMap { $0.first } ?? "\u{23df}"
        let top = prop(e, "groupChrPr", "pos").map { $0 == "top" } ?? false
        let body = arg(e, "e", mode: .math)
        if let cmd = mathAccent(chr) {
            tex.pushCommand(cmd, body)
        } else {
            let mark = Tex()
            mark.pushMathChar(chr)
            tex.pushMacro(top ? "\\overset" : "\\underset")
            tex.pushGroup(mark)
            tex.pushGroup(body)
        }
    }

    private static func limit(_ e: XmlElement, _ tex: Tex, mode: Mode) {
        let upper = e.local == "limUpp"
        let base = arg(e, "e", mode: mode)
        let lim = arg(e, "lim", mode: .math)
        if mode == .funcName {
            // `\lim_{x \to 0}`: the operator takes its own limits.
            tex.pushTex(base)
            tex.pushChar(upper ? "^" : "_")
            tex.pushGroup(lim)
            return
        }
        tex.pushMacro(upper ? "\\overset" : "\\underset")
        tex.pushGroup(lim)
        tex.pushGroup(base)
    }

    private static func matrix(_ e: XmlElement, _ tex: Tex) {
        tex.pushStr("\\begin{matrix}")
        for (i, row) in e.findAll(XmlNS.m, "mr").enumerated() {
            if i > 0 { tex.pushStr(" \\\\") }
            for (j, cell) in row.findAll(XmlNS.m, "e").enumerated() {
                tex.pushStr(j > 0 ? " & " : " ")
                let inner = Tex()
                walkChildren(cell, inner, mode: .math)
                tex.pushTex(inner)
            }
        }
        tex.pushStr(" \\end{matrix}")
    }

    private static func equationArray(_ e: XmlElement, _ tex: Tex) {
        let rows: [Tex] = e.findAll(XmlNS.m, "e").map { row in
            let inner = Tex()
            walkChildren(row, inner, mode: .array)
            return inner
        }
        let env = rows.contains { $0.contains("&") } ? "aligned" : "gathered"
        tex.pushStr("\\begin{\(env)}")
        for (i, row) in rows.enumerated() {
            if i > 0 { tex.pushStr(" \\\\") }
            tex.pushChar(" ")
            tex.pushTex(row)
        }
        tex.pushStr(" \\end{\(env)}")
    }
}
