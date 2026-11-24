import Foundation

/// LaTeX emission shared by the OMML and MathML converters (port of
/// `shared/math/tex.rs`): a buffer that keeps control words separated from
/// following letters, and the Unicode to LaTeX mappings.

final class Tex {
    private(set) var out = ""
    /// The output ends in a letter-named control word, which would swallow
    /// a letter appended directly after it.
    private var afterMacro = false

    init() {}

    var isEmpty: Bool { out.isEmpty }
    func contains(_ c: Character) -> Bool { out.contains(c) }

    func pushStr(_ s: String) {
        guard let first = s.first else { return }
        if afterMacro, first.isASCII, first.isLetter { out.append(" ") }
        out += s
        afterMacro = Self.endsWithControlWord(s)
    }

    func pushChar(_ c: Character) {
        if afterMacro, c.isASCII, c.isLetter { out.append(" ") }
        out.append(c)
        afterMacro = false
    }

    /// A control word, with its backslash (`\alpha`, `\{`).
    func pushMacro(_ name: String) {
        out += name
        afterMacro = Self.endsWithControlWord(name)
    }

    func pushTex(_ other: Tex) {
        if other.out.isEmpty { return }
        pushStr(other.out)
        afterMacro = other.afterMacro
    }

    /// `{inner}`.
    func pushGroup(_ inner: Tex) {
        pushChar("{")
        pushTex(inner)
        pushChar("}")
    }

    /// A script base: `inner` as it stands when it is one atom.
    func pushBase(_ inner: Tex) {
        let atom = inner.out.count == 1
            || (inner.out.hasPrefix("\\") && inner.out.dropFirst().allSatisfy { $0.isASCII && $0.isLetter })
        if atom { pushTex(inner) } else { pushGroup(inner) }
    }

    /// `\name{inner}`.
    func pushCommand(_ name: String, _ inner: Tex) {
        pushMacro(name)
        pushGroup(inner)
    }

    /// Text in math mode: symbols become control words, styled mathematical
    /// alphanumerics fold back to base letters inside the matching font
    /// command, and TeX specials are escaped.
    func pushMathText(_ text: String) {
        var pending: (Variant, String)? = nil
        for c in text {
            if let (base, variant) = foldAlnum(c), variant != .plain {
                if let (v, run) = pending, v == variant {
                    pending = (v, run + String(base))
                } else {
                    flushVariant(pending)
                    pending = (variant, String(base))
                }
            } else if let (base, _) = foldAlnum(c) {
                flushVariant(pending)
                pending = nil
                pushMathChar(base)
            } else {
                flushVariant(pending)
                pending = nil
                pushMathChar(c)
            }
        }
        flushVariant(pending)
    }

    private func flushVariant(_ pending: (Variant, String)?) {
        guard let (variant, run) = pending else { return }
        let inner = Tex()
        inner.pushMathText(run)
        pushCommand(variant.command, inner)
    }

    /// One character in math mode.
    func pushMathChar(_ c: Character) {
        if let mapped = mathSymbol(c) {
            if mapped.hasPrefix("\\") {
                pushMacro(mapped)
            } else {
                pushStr(mapped)
            }
            return
        }
        switch c {
        case "{", "}", "$", "%", "&", "#", "_":
            pushChar("\\")
            pushChar(c)
        case "\\": pushMacro("\\backslash")
        case "^": pushStr("\\char`^")
        case "~": pushMacro("\\sim")
        case "\u{a0}": pushStr("\\ ")
        default:
            if c.isWhitespace { pushChar(" ") }
            else if !c.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) { pushChar(c) }
        }
    }

    /// `\text{...}`: literal text inside a formula.
    func pushTextMode(_ text: String) {
        let inner = Tex()
        for c in text {
            switch c {
            case "{", "}", "$", "%", "&", "#", "_":
                inner.pushChar("\\")
                inner.pushChar(c)
            case "\\": inner.pushStr("\\textbackslash{}")
            case "^": inner.pushStr("\\textasciicircum{}")
            case "~": inner.pushStr("\\textasciitilde{}")
            case "\u{a0}": inner.pushChar("~")
            default:
                if c.isWhitespace { inner.pushChar(" ") }
                else if !c.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) { inner.pushChar(c) }
            }
        }
        pushCommand("\\text", inner)
    }

    func finish() -> String {
        var out = ""
        var prevSpace = true
        for c in self.out.trimmingCharacters(in: .whitespacesAndNewlines) {
            let space = c == " "
            if !(space && prevSpace) { out.append(c) }
            prevSpace = space
        }
        return out
    }

    /// Whether `s` ends in a letter-named control word (`\alpha`,
    /// `\left\langle`), which would swallow a letter written after it.
    private static func endsWithControlWord(_ s: String) -> Bool {
        var nameLen = 0
        for c in s.reversed() {
            if c.isASCII, c.isLetter { nameLen += 1 } else { break }
        }
        guard nameLen > 0 else { return false }
        let idx = s.index(s.endIndex, offsetBy: -nameLen)
        return s[..<idx].hasSuffix("\\")
    }
}

/// Font variant of a mathematical alphanumeric symbol.
enum Variant {
    case plain, bold, boldItalic, script, fraktur, doubleStruck, sansSerif, monospace

    var command: String {
        switch self {
        case .plain: return "\\mathit"
        case .bold: return "\\mathbf"
        case .boldItalic: return "\\boldsymbol"
        case .script: return "\\mathcal"
        case .fraktur: return "\\mathfrak"
        case .doubleStruck: return "\\mathbb"
        case .sansSerif: return "\\mathsf"
        case .monospace: return "\\mathtt"
        }
    }

    /// The variant a MathML `mathvariant` names.
    static func fromMathvariant(_ value: String) -> Variant? {
        switch value {
        case "bold": return .bold
        case "bold-italic": return .boldItalic
        case "script", "bold-script": return .script
        case "fraktur", "bold-fraktur": return .fraktur
        case "double-struck": return .doubleStruck
        case "sans-serif", "bold-sans-serif", "sans-serif-italic", "sans-serif-bold-italic": return .sansSerif
        case "monospace": return .monospace
        default: return nil
        }
    }
}

private let greekUpper = Array("ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡϴΣΤΥΦΧΨΩ")
private let greekLower = Array("αβγδεζηθικλμνξοπρςστυφχψω")
private let greekExtra = Array("∂ϵϑϰϕϱϖ")

/// Fold a Mathematical Alphanumeric Symbol (or a letterlike symbol in the
/// same role) to its base character and font variant.
func foldAlnum(_ c: Character) -> (Character, Variant)? {
    let scalars = c.unicodeScalars
    guard scalars.count == 1, let scalar = scalars.first else { return nil }
    let cp = scalar.value

    // Letterlike symbols.
    let letterlike: (Character, Variant)? = {
        switch c {
        case "ℎ": return ("h", .plain)
        case "ℬ": return ("B", .script)
        case "ℰ": return ("E", .script)
        case "ℱ": return ("F", .script)
        case "ℋ": return ("H", .script)
        case "ℐ": return ("I", .script)
        case "ℒ": return ("L", .script)
        case "ℳ": return ("M", .script)
        case "ℛ": return ("R", .script)
        case "ℯ": return ("e", .script)
        case "ℊ": return ("g", .script)
        case "ℴ": return ("o", .script)
        case "ℭ": return ("C", .fraktur)
        case "ℌ": return ("H", .fraktur)
        case "ℑ": return ("I", .fraktur)
        case "ℜ": return ("R", .fraktur)
        case "ℨ": return ("Z", .fraktur)
        case "ℂ": return ("C", .doubleStruck)
        case "ℍ": return ("H", .doubleStruck)
        case "ℕ": return ("N", .doubleStruck)
        case "ℙ": return ("P", .doubleStruck)
        case "ℚ": return ("Q", .doubleStruck)
        case "ℝ": return ("R", .doubleStruck)
        case "ℤ": return ("Z", .doubleStruck)
        default: return nil
        }
    }()
    if let letterlike { return letterlike }

    guard (0x1D400...0x1D7FF).contains(cp) else { return nil }
    let offset = cp - 0x1D400
    if offset < 13 * 52 {
        let latin: [Variant] = [.bold, .plain, .boldItalic, .script, .script, .fraktur,
                                .doubleStruck, .fraktur, .sansSerif, .sansSerif, .sansSerif,
                                .sansSerif, .monospace]
        let style = Int(offset / 52)
        let i = Int(offset % 52)
        let base = i < 26 ? Character(UnicodeScalar(65 + i)!) : Character(UnicodeScalar(97 + i - 26)!)
        return (base, latin[style])
    }
    if let greek = cp.checkedSubtracting(0x1D6A8), greek < 5 * 58 {
        let greekVariants: [Variant] = [.bold, .plain, .boldItalic, .sansSerif, .sansSerif]
        let style = Int(greek / 58)
        let i = Int(greek % 58)
        let base: Character
        switch i {
        case 0...24: base = greekUpper[i]
        case 25: base = "∇"
        case 26...50: base = greekLower[i - 26]
        default: base = greekExtra[i - 51]
        }
        return (base, greekVariants[style])
    }
    if let digit = cp.checkedSubtracting(0x1D7CE), digit < 5 * 10 {
        let digitVariants: [Variant] = [.bold, .doubleStruck, .sansSerif, .sansSerif, .monospace]
        let base = Character(UnicodeScalar(48 + Int(digit % 10))!)
        return (base, digitVariants[Int(digit / 10)])
    }
    return nil
}

extension UInt32 {
    /// `self - other` when non-negative, else nil.
    func checkedSubtracting(_ other: UInt32) -> UInt32? {
        self >= other ? self - other : nil
    }
}

extension Tex {
    /// `symbol(c)` lookup kept on the type for call-site clarity.
    func pushSymbolChar(_ c: Character) { pushMathChar(c) }
}

/// LaTeX for a Unicode math character: a control word, a literal
/// replacement, or an empty string for characters with no visible form.
func mathSymbol(_ c: Character) -> String? {
    mathSymbolTable[c]
}

private let mathSymbolTable: [Character: String] = [
    // Greek
    "α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta",
    "ε": "\\varepsilon", "ϵ": "\\epsilon", "ζ": "\\zeta", "η": "\\eta",
    "θ": "\\theta", "ϑ": "\\vartheta", "ι": "\\iota", "κ": "\\kappa",
    "ϰ": "\\varkappa", "λ": "\\lambda", "μ": "\\mu", "ν": "\\nu",
    "ξ": "\\xi", "ο": "o", "π": "\\pi", "ϖ": "\\varpi",
    "ρ": "\\rho", "ϱ": "\\varrho", "σ": "\\sigma", "ς": "\\varsigma",
    "τ": "\\tau", "υ": "\\upsilon", "φ": "\\varphi", "ϕ": "\\phi",
    "χ": "\\chi", "ψ": "\\psi", "ω": "\\omega",
    "Α": "A", "Β": "B", "Γ": "\\Gamma", "Δ": "\\Delta",
    "Ε": "E", "Ζ": "Z", "Η": "H", "Θ": "\\Theta", "ϴ": "\\Theta",
    "Ι": "I", "Κ": "K", "Λ": "\\Lambda", "Μ": "M", "Ν": "N",
    "Ξ": "\\Xi", "Ο": "O", "Π": "\\Pi", "Ρ": "P", "Σ": "\\Sigma",
    "Τ": "T", "Υ": "\\Upsilon", "Φ": "\\Phi", "Χ": "X", "Ψ": "\\Psi",
    "Ω": "\\Omega",
    // Big operators
    "∑": "\\sum", "∏": "\\prod", "∐": "\\coprod", "∫": "\\int",
    "∬": "\\iint", "∭": "\\iiint", "⨌": "\\iiiint", "∮": "\\oint",
    "∯": "\\oiint", "∰": "\\oiiint", "⋃": "\\bigcup", "⋂": "\\bigcap",
    "⋁": "\\bigvee", "⋀": "\\bigwedge", "⨁": "\\bigoplus",
    "⨂": "\\bigotimes", "⨀": "\\bigodot", "⨄": "\\biguplus",
    "⨆": "\\bigsqcup",
    // Binary operators
    "×": "\\times", "÷": "\\div", "±": "\\pm", "∓": "\\mp",
    "⋅": "\\cdot", "·": "\\cdot", "∙": "\\cdot", "∗": "\\ast",
    "∘": "\\circ", "∖": "\\setminus", "⊕": "\\oplus", "⊖": "\\ominus",
    "⊗": "\\otimes", "⊘": "\\oslash", "⊙": "\\odot", "∪": "\\cup",
    "∩": "\\cap", "⊎": "\\uplus", "⊓": "\\sqcap", "⊔": "\\sqcup",
    "∧": "\\wedge", "∨": "\\vee", "†": "\\dagger", "‡": "\\ddagger",
    "⋆": "\\star",
    // Relations
    "≤": "\\le", "⩽": "\\le", "≥": "\\ge", "⩾": "\\ge", "≠": "\\ne",
    "≈": "\\approx", "≡": "\\equiv", "≢": "\\not\\equiv", "≅": "\\cong",
    "≃": "\\simeq", "∼": "\\sim", "≁": "\\nsim", "∝": "\\propto",
    "≪": "\\ll", "≫": "\\gg", "≺": "\\prec", "≻": "\\succ",
    "⪯": "\\preceq", "≼": "\\preceq", "⪰": "\\succeq", "≽": "\\succeq",
    "⊂": "\\subset", "⊃": "\\supset", "⊆": "\\subseteq", "⊇": "\\supseteq",
    "⊄": "\\not\\subset", "⊈": "\\nsubseteq", "⊊": "\\subsetneq",
    "⊋": "\\supsetneq", "⊏": "\\sqsubset", "⊐": "\\sqsupset",
    "⊑": "\\sqsubseteq", "⊒": "\\sqsupseteq", "∈": "\\in", "∉": "\\notin",
    "∋": "\\ni", "∌": "\\not\\ni", "≐": "\\doteq", "≜": "\\triangleq",
    "≝": "\\overset{\\mathrm{def}}{=}", "≔": "\\coloneqq", "⊥": "\\perp",
    "∥": "\\parallel", "∦": "\\nparallel", "⊢": "\\vdash", "⊣": "\\dashv",
    "⊨": "\\models", "⊤": "\\top", "≍": "\\asymp", "≀": "\\wr",
    "⋈": "\\bowtie", "∣": "\\mid", "∤": "\\nmid",
    // Arrows
    "→": "\\to", "←": "\\leftarrow", "↔": "\\leftrightarrow",
    "⇒": "\\Rightarrow", "⇐": "\\Leftarrow", "⇔": "\\Leftrightarrow",
    "↑": "\\uparrow", "↓": "\\downarrow", "↕": "\\updownarrow",
    "⇑": "\\Uparrow", "⇓": "\\Downarrow", "⇕": "\\Updownarrow",
    "↦": "\\mapsto", "⟶": "\\longrightarrow", "⟵": "\\longleftarrow",
    "⟷": "\\longleftrightarrow", "⟹": "\\Longrightarrow",
    "⟸": "\\Longleftarrow", "⟺": "\\Longleftrightarrow",
    "⟼": "\\longmapsto", "↗": "\\nearrow", "↘": "\\searrow",
    "↙": "\\swarrow", "↖": "\\nwarrow", "↩": "\\hookleftarrow",
    "↪": "\\hookrightarrow", "⇀": "\\rightharpoonup", "↼": "\\leftharpoonup",
    "⇌": "\\rightleftharpoons", "↶": "\\curvearrowleft",
    "↷": "\\curvearrowright",
    // Logic and sets
    "∀": "\\forall", "∃": "\\exists", "∄": "\\nexists", "¬": "\\neg",
    "∅": "\\emptyset", "⌀": "\\emptyset", "∞": "\\infty", "∂": "\\partial",
    "∇": "\\nabla", "∴": "\\therefore", "∵": "\\because", "ℵ": "\\aleph",
    "ℶ": "\\beth", "ℏ": "\\hbar", "ℓ": "\\ell", "℘": "\\wp", "℧": "\\mho",
    "√": "\\surd", "∠": "\\angle", "∡": "\\measuredangle", "△": "\\triangle",
    "□": "\\square", "◻": "\\square", "◊": "\\lozenge", "°": "^{\\circ}",
    "′": "'", "″": "''", "‴": "'''", "⁗": "''''", "…": "\\ldots",
    "⋯": "\\cdots", "⋮": "\\vdots", "⋱": "\\ddots", "⋰": "\\iddots",
    // Delimiters
    "⟨": "\\langle", "〈": "\\langle", "⟩": "\\rangle", "〉": "\\rangle",
    "⌈": "\\lceil", "⌉": "\\rceil", "⌊": "\\lfloor", "⌋": "\\rfloor",
    "‖": "\\Vert",
    // Spacing and invisible characters
    "−": "-", "‐": "-", "‑": "-", "‒": "-", "–": "-",
    "\u{2009}": "\\,", "\u{200a}": "\\,", "\u{2006}": "\\,",
    "\u{2005}": "\\:", "\u{2004}": "\\:",
    "\u{2003}": "\\;", "\u{2002}": "\\;",
    "\u{2061}": "", "\u{2062}": "", "\u{2063}": "", "\u{2064}": "",
    "\u{200b}": "", "\u{feff}": "",
]

/// LaTeX for a character in a `\left` / `\right` position.
func mathDelimiter(_ c: Character) -> String {
    switch c {
    case "(", "⟮": return "("
    case ")", "⟯": return ")"
    case "[": return "["
    case "]": return "]"
    case "{": return "\\{"
    case "}": return "\\}"
    case "|", "∣": return "|"
    case "‖", "∥": return "\\Vert"
    case "⟨", "〈": return "\\langle"
    case "⟩", "〉": return "\\rangle"
    case "⌈": return "\\lceil"
    case "⌉": return "\\rceil"
    case "⌊": return "\\lfloor"
    case "⌋": return "\\rfloor"
    case "/": return "/"
    case "\\": return "\\backslash"
    case "↑": return "\\uparrow"
    case "↓": return "\\downarrow"
    case "↕": return "\\updownarrow"
    case "⇑": return "\\Uparrow"
    case "⇓": return "\\Downarrow"
    case "⇕": return "\\Updownarrow"
    default: return "."
    }
}

/// Accent command for a combining mark or its spacing equivalent.
func mathAccent(_ c: Character) -> String? {
    switch c {
    case "\u{300}", "`": return "\\grave"
    case "\u{301}", "´": return "\\acute"
    case "\u{302}", "^", "ˆ": return "\\hat"
    case "\u{303}", "~", "˜": return "\\tilde"
    case "\u{304}", "¯", "ˉ": return "\\bar"
    case "\u{305}", "‾", "⎴": return "\\overline"
    case "\u{306}", "˘": return "\\breve"
    case "\u{307}", "˙": return "\\dot"
    case "\u{308}", "¨": return "\\ddot"
    case "\u{30a}", "˚": return "\\mathring"
    case "\u{30c}", "ˇ": return "\\check"
    case "\u{332}", "_", "⎵": return "\\underline"
    case "\u{20d6}", "←": return "\\overleftarrow"
    case "\u{20d7}", "→": return "\\vec"
    case "\u{20e1}", "↔": return "\\overleftrightarrow"
    case "\u{20db}": return "\\dddot"
    case "\u{20dc}": return "\\ddddot"
    case "\u{20ee}": return "\\underleftarrow"
    case "\u{20ef}": return "\\underrightarrow"
    case "⏞", "︷": return "\\overbrace"
    case "⏟", "︸": return "\\underbrace"
    default: return nil
    }
}

/// Control word for a function name LaTeX predefines (`\sin`), or an
/// `\operatorname` for any other alphabetic name.
func mathFunctionName(_ name: String) -> String? {
    let known: Set<String> = ["arccos", "arcsin", "arctan", "arg", "cos", "cosh", "cot", "coth",
                              "csc", "deg", "det", "dim", "exp", "gcd", "hom", "inf", "ker", "lg",
                              "lim", "liminf", "limsup", "ln", "log", "max", "min", "Pr", "sec",
                              "sin", "sinh", "sup", "tan", "tanh"]
    let name = name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    return known.contains(name) ? "\\\(name)" : "\\operatorname{\(name)}"
}
