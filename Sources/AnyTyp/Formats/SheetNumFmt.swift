import Foundation

/// Number-format engine subset (port of `sheet/numfmt.rs`): built-in
/// format codes plus a pragmatic parser covering the common grammar —
/// percent scaling, thousands grouping, fixed/scientific decimals,
/// literal currency/text, and date/time serials. Codes outside the
/// implemented grammar resolve to General, never a guess.
enum SheetNumFmt {
    /// Built-in numFmtId -> format code (the locale-independent subset
    /// of the Excel built-in table).
    static func builtinCode(_ id: UInt32) -> String? {
        switch id {
        case 1: return "0"
        case 2: return "0.00"
        case 3: return "#,##0"
        case 4: return "#,##0.00"
        case 9: return "0%"
        case 10: return "0.00%"
        case 11: return "0.00E+00"
        case 12: return "# ?/?"
        case 13: return "# ??/??"
        case 14: return "mm-dd-yy"
        case 15: return "d-mmm-yy"
        case 16: return "d-mmm"
        case 17: return "mmm-yy"
        case 18: return "h:mm AM/PM"
        case 19: return "h:mm:ss AM/PM"
        case 20: return "h:mm"
        case 21: return "h:mm:ss"
        case 22: return "m/d/yy h:mm"
        case 37: return "#,##0 ;(#,##0)"
        case 38: return "#,##0 ;[Red](#,##0)"
        case 39: return "#,##0.00;(#,##0.00)"
        case 40: return "#,##0.00;[Red](#,##0.00)"
        case 45: return "mm:ss"
        case 46: return "[h]:mm:ss"
        case 47: return "mmss.0"
        case 48: return "##0.0E+0"
        case 49: return "@"
        default: return nil
        }
    }

    /// What a serial renders as.
    enum Rendered {
        /// General numeric output with optional literal affixes.
        case general(value: Double, prefix: String, suffix: String)
        /// Fully rendered text.
        case text(String)
        /// A date/time serial needing the epoch rules.
        case dateTime(DateParts)
    }

    /// Which date/time components a format shows.
    struct DateParts {
        var date = false
        var time = false
        /// Elapsed-time format (`[h]`, `[m]`, `[s]`).
        var elapsed = false
    }

    /// A parsed number format.
    struct NumberFormat {
        /// Rendered sections in order; positive;negative;zero;text.
        var sections: [Section]

        struct Section {
            var body: Body
            /// Positive-condition value when the section is conditional.
            var condition: Cond?
        }

        struct Cond {
            var op: String // '<', '>', '=', '<>', '<=', '>='
            var value: Double
            func matches(_ v: Double) -> Bool {
                switch op {
                case "<": return v < value
                case ">": return v > value
                case "=": return v == value
                case "<=": return v <= value
                case ">=": return v >= value
                default: return v != value // "<>"
                }
            }
        }

        enum Body {
            /// General number rendering spec.
            case number(NumSpec)
            /// Date/time serial.
            case date(DateParts)
            /// Literal text section (`@` or quoted text only).
            case text
            /// Empty body.
            case empty
        }

        struct NumSpec {
            var prefix = ""
            var suffix = ""
            /// Decimal places after the point (fixed notation).
            var decimals: Int? = nil
            /// Thousands grouping.
            var grouping = false
            /// Percent: multiply by 100 and append '%'.
            var percent = false
            /// Scientific notation.
            var scientific = false
            /// Fraction format (# ?/?).
            var fraction = false
            /// Literal characters to emit around the digits.
            var literal = ""
        }

        /// Parse a format code; nil when outside the grammar.
        static func parse(_ code: String) -> NumberFormat? {
            if code.trimmingCharacters(in: .whitespaces).lowercased() == "general" {
                return nil
            }
            let sections = splitSections(code)
            guard !sections.isEmpty else { return nil }
            var parsed: [Section] = []
            for s in sections {
                guard let sec = parseSection(s) else { return nil }
                parsed.append(sec)
            }
            return NumberFormat(sections: parsed)
        }

        /// Numeric sections (non-text), in order.
        func numericSections() -> [Section] {
            sections.filter { !$0.isText }
        }

        /// Format a numeric value.
        func formatNumber(_ v: Double) -> Rendered {
            let secs = numericSections()
            if secs.isEmpty { return .general(value: v, prefix: "", suffix: "") }
            var chosen: (Section, Double, Bool)? = nil // (section, scaled, negated)
            if secs.count >= 2 {
                // Two sections: first for >=0, second for <0.
                chosen = v < 0 ? (secs[1], -v, true) : (secs[0], v, false)
            } else if secs.count == 3 || secs.count == 4 {
                // Three/four: positive;negative;zero(;text). Conditions
                // select the first matching section.
                for (i, s) in secs.prefix(3).enumerated() {
                    if let c = s.condition {
                        if c.matches(v) { chosen = (s, abs(v), false); break }
                    } else if i == 0 && v > 0 || i == 1 && v < 0 || i == 2 && v == 0 {
                        chosen = (s, abs(v), false); break
                    }
                }
                if chosen == nil { chosen = (secs[min(2, secs.count - 1)], abs(v), false) }
            } else {
                chosen = (secs[0], abs(v), v < 0)
            }
            guard let (sec, val, neg) = chosen else {
                return .general(value: v, prefix: "", suffix: "")
            }
            switch sec.body {
            case .date(let parts): return .dateTime(parts)
            case .text, .empty:
                return .general(value: v, prefix: "", suffix: "")
            case .number(let spec):
                guard let s = renderNumber(spec, vAbs: val, minus: neg || v < 0) else {
                    return .general(value: v, prefix: "", suffix: "")
                }
                return .text(s)
            }
        }

        /// Format text through the text section (`@`-style).
        func formatText(_ text: String) -> String? {
            // Text section is the 4th when present, else the last.
            let textSections = sections.filter { $0.isText }
            guard let sec = textSections.last, case .text = sec.body else {
                return nil
            }
            // Literal decoration around the text.
            return "\(sec.prefix)\(text)\(sec.suffix)"
        }
    }

    /// Split a format code on unquoted ';' into sections.
    private static func splitSections(_ code: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var bracketDepth = 0
        for ch in code {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if !inQuote {
                if ch == "[" { bracketDepth += 1 }
                if ch == "]" { bracketDepth = max(bracketDepth - 1, 0) }
                if ch == ";", bracketDepth == 0 {
                    out.append(cur)
                    cur = ""
                    continue
                }
            }
            cur.append(ch)
        }
        out.append(cur)
        return out
    }

    private static func decoration(_ toks: [Tok]) -> String {
        toks.compactMap { t -> String? in
            if case .literal(let s) = t { return s }
            return nil
        }.joined()
    }

    /// Whether a section's tokens describe a date/time serial.
    private static func dateParts(_ runs: [Character], elapsed: Bool) -> DateParts {
        var parts = DateParts()
        parts.elapsed = elapsed
        for ch in runs {
            switch ch {
            case "y", "d": parts.date = true
            case "m": parts.date = true; parts.time = true // m is ambiguous; treat as both
            case "h", "s": parts.time = true
            default: break
            }
        }
        return parts
    }

    private enum Tok {
        case literal(String)
        case digitPlaceholder(Character) // 0 # ?
        case decimalPoint
        case percent
        case comma
        case scientific // E+ e+
        case dateChar(Character)
        case bracketed(String)
        case textSection // @
        case slash
        case colon
        case ampm
        case condition(String)
    }

    /// Lex one section into tokens, honoring quotes and bracket blocks.
    private static func lex(_ s: String) -> [Tok] {
        var out: [Tok] = []
        let chars = Array(s)
        var i = 0
        var literal = ""
        func flushLit() {
            if !literal.isEmpty { out.append(.literal(literal)); literal = "" }
        }
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    literal.append(chars[i]); i += 1
                }
                i += 1 // closing quote
                continue
            }
            if ch == "[" {
                var j = i + 1
                var inner = ""
                while j < chars.count, chars[j] != "]" {
                    inner.append(chars[j]); j += 1
                }
                if j < chars.count {
                    // Conditions, elapsed markers, and currency brackets
                    // are structural; colors/locales/DBNum drop silently.
                    if inner.hasPrefix("h") || inner.hasPrefix("m") || inner.hasPrefix("s") {
                        flushLit()
                        out.append(.bracketed(inner))
                    } else if inner.hasPrefix("<") || inner.hasPrefix(">")
                        || inner.hasPrefix("=") || inner.hasPrefix("!") {
                        flushLit()
                        out.append(.condition(inner))
                    } else if inner.hasPrefix("$") {
                        // [$<symbol>-<locale>]: keep the currency symbol.
                        let rest = inner.dropFirst()
                        if let dash = rest.firstIndex(of: "-") {
                            let sym = String(rest[..<dash])
                            if !sym.isEmpty { literal += sym }
                        }
                    }
                    i = j + 1
                    continue
                }
            }
            if ch == "\\" {
                if i + 1 < chars.count {
                    literal.append(chars[i + 1])
                    i += 2
                    continue
                }
            }
            if ch == "_" {
                // _(x) emits a space the width of x — approximate as space.
                literal.append(" ")
                i += 1
                continue
            }
            if ch == "*" {
                // * repeats the next char — drop the marker, keep literal.
                i += 1
                continue
            }
            switch ch {
            case "0", "#", "?":
                flushLit(); out.append(.digitPlaceholder(ch))
            case ".":
                flushLit(); out.append(.decimalPoint)
            case "%":
                flushLit(); out.append(.percent)
            case ",":
                flushLit(); out.append(.comma)
            case "E", "e":
                if i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" {
                    flushLit(); out.append(.scientific); i += 2; continue
                }
                literal.append(ch)
            case "y", "Y", "d", "D":
                flushLit(); out.append(.dateChar(ch))
            case "m", "M":
                flushLit(); out.append(.dateChar(ch))
            case "h", "H", "s", "S":
                flushLit(); out.append(.dateChar(ch))
            case "A", "P":
                // AM/PM marker (A/P followed by M).
                if i + 1 < chars.count, chars[i + 1] == "M" {
                    flushLit(); out.append(.ampm); i += 2; continue
                }
                literal.append(ch)
            case "a", "p":
                if i + 1 < chars.count, chars[i + 1] == "m" || chars[i + 1] == "M" {
                    flushLit(); out.append(.ampm); i += 2; continue
                }
                literal.append(ch)
            case "@":
                flushLit(); out.append(.textSection)
            case "/":
                flushLit(); out.append(.slash)
            case ":":
                flushLit(); out.append(.colon)
            case " ", "-", "+", "(", ")", "{", "}", ";":
                literal.append(ch)
            default:
                if ch.isLetter {
                    // Unknown letter: treat as literal (some locales use
                    // currency letters).
                    literal.append(ch)
                } else {
                    literal.append(ch)
                }
            }
            i += 1
        }
        flushLit()
        return out
    }

    private static func parseSection(_ s: String) -> NumberFormat.Section? {
        let toks = lex(s)
        // Leading condition?
        var condition: NumberFormat.Cond? = nil
        var idx = 0
        if case .condition(let c)? = toks.first {
            // [>100] etc.
            var op = String(c.prefix(while: { "<>=!".contains($0) }))
            let body = String(c.dropFirst(op.count))
            // "!=" is the not-equal spelling some producers emit.
            if op == "!=" { op = "<>" }
            if let v = Double(body) {
                condition = NumberFormat.Cond(op: op.isEmpty ? "=" : op, value: v)
            }
            idx = 1
        }
        let rest = Array(toks[idx...])
        if rest.isEmpty { return NumberFormat.Section(body: .empty, condition: condition) }

        // Text section?
        if rest.contains(where: { if case .textSection = $0 { return true }; return false }),
           !rest.contains(where: { if case .digitPlaceholder = $0 { return true }; return false }) {
            return NumberFormat.Section(body: .text, condition: condition)
        }

        // Date/time?
        let hasDateChar = rest.contains { if case .dateChar = $0 { return true }; return false }
        if hasDateChar {
            let elapsed = rest.contains { if case .bracketed(let b) = $0 {
                return b.hasPrefix("h") || b.hasPrefix("m") || b.hasPrefix("s")
            }; return false }
            let chars = rest.compactMap { t -> Character? in
                if case .dateChar(let c) = t { return c }
                return nil
            }
            return NumberFormat.Section(body: .date(dateParts(chars, elapsed: elapsed)), condition: condition)
        }

        // Numeric spec.
        var spec = NumberFormat.NumSpec()
        var sawDigit = false
        var sawDecimal = false
        var scientific = false
        var literal = ""
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case .digitPlaceholder(let p):
                sawDigit = true
                if p == "?" { spec.fraction = true }
            case .decimalPoint:
                sawDecimal = true
            case .percent:
                spec.percent = true
            case .comma:
                spec.grouping = true
            case .scientific:
                scientific = true
            case .literal(let s):
                literal += s
            case .slash:
                spec.fraction = true
            case .bracketed(let b):
                literal += "[\(b)]"
            case .condition:
                break
            default:
                break
            }
            i += 1
        }
        if !sawDigit, !spec.percent, literal.isEmpty {
            return NumberFormat.Section(body: .empty, condition: condition)
        }
        spec.literal = literal
        spec.scientific = scientific
        if sawDecimal {
            // Count placeholders after the decimal point.
            var after = false
            var dp = 0
            for t in rest {
                if case .decimalPoint = t { after = true; continue }
                if after, case .digitPlaceholder(let p) = t, p != "?" { dp += 1 }
            }
            spec.decimals = dp
        }
        // Split literal into prefix/suffix around the number core.
        // Heuristic: text before the first digit placeholder is prefix.
        var pre = ""
        var post = ""
        var seenCore = false
        for t in rest {
            switch t {
            case .digitPlaceholder, .decimalPoint, .percent, .comma, .scientific:
                seenCore = true
            case .literal(let s):
                if seenCore { post += s } else { pre += s }
            case .slash:
                seenCore = true
            default:
                break
            }
        }
        spec.prefix = pre
        spec.suffix = post + (spec.percent ? "%" : "")
        return NumberFormat.Section(body: .number(spec), condition: condition)
    }

    /// Format the absolute value through a numeric spec.
    private static func renderNumber(
        _ spec: NumberFormat.NumSpec, vAbs: Double, minus: Bool
    ) -> String? {
        var v = vAbs
        if spec.percent { v *= 100 }
        if spec.fraction {
            // # ?/? approximation: render as decimal with up to 2 places.
            return "\(spec.prefix)\(formatGeneral(v))\(spec.suffix)"
        }
        if spec.scientific {
            return "\(spec.prefix)\(String(format: "%.\(spec.decimals ?? 2)e", v))\(spec.suffix)"
        }
        let dp = spec.decimals
        var body: String
        if let dp {
            body = String(format: "%.\(dp)f", v)
            if dp == 0 {
                body = String(format: "%.0f", v)
            }
        } else {
            body = formatGeneral(v)
        }
        if spec.grouping {
            body = addGrouping(body)
        }
        if minus {
            // Accounting-style: wrap in parens when the format implies it.
            if spec.prefix.contains("(") || spec.suffix.contains(")") {
                return "\(spec.prefix)\(body)\(spec.suffix)"
            }
            return "-\(spec.prefix)\(body)\(spec.suffix)"
        }
        return "\(spec.prefix)\(body)\(spec.suffix)"
    }

    /// Excel "General" / Rust `{}` float display: round to 15 significant
    /// digits (what a spreadsheet stores), then expand to decimal — no
    /// exponent noise for values a sheet can hold.
    static func formatGeneral(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        let sci = String(format: "%.14e", v) // d.ddddddddddddde±XX
        guard let eIdx = sci.firstIndex(of: "e") else { return sci }
        let mantissa = String(sci[..<eIdx])
        guard let exp = Int(sci[sci.index(after: eIdx)...]) else { return sci }
        let neg = mantissa.hasPrefix("-")
        var digits = mantissa.filter { $0 != "." && $0 != "-" }
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.isEmpty { digits = "0" }
        let pointPos = exp + 1 // digits before the decimal point
        var out = neg ? "-" : ""
        if pointPos <= 0 {
            out += "0." + String(repeating: "0", count: -pointPos) + digits
        } else if pointPos >= digits.count {
            out += digits + String(repeating: "0", count: pointPos - digits.count)
        } else {
            let cut = digits.index(digits.startIndex, offsetBy: pointPos)
            out += String(digits[..<cut]) + "." + String(digits[cut...])
        }
        return out
    }

    private static func addGrouping(_ s: String) -> String {
        var parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return s }
        var intPart = String(parts[0])
        let neg = intPart.hasPrefix("-")
        if neg { intPart.removeFirst() }
        var out = ""
        var count = 0
        for ch in intPart.reversed() {
            if count == 3 {
                out = "," + out
                count = 0
            }
            out = String(ch) + out
            count += 1
        }
        parts[0] = Substring((neg ? "-" : "") + out)
        return parts.joined(separator: ".")
    }
}

/// Format a cell text through a resolved format (port of
/// `format_as_text`).
func sheetFormatAsText(_ fmt: SheetCellFormat, text: String) -> String {
    switch fmt {
    case .general:
        return text
    case .fmt(let f):
        if let s = f.formatText(text) { return SharedText.clean(s) }
        return text
    }
}

/// A cell's resolved number format.
enum SheetCellFormat {
    case general
    case fmt(SheetNumFmt.NumberFormat)
}

/// Render a numeric cell through its resolved format.
func sheetRenderNumber(_ fmt: SheetCellFormat, _ n: Double, date1904: Bool) -> String {
    let text: String
    switch fmt {
    case .general:
        text = SheetNumFmt.formatGeneral(n)
    case .fmt(let f):
        switch f.formatNumber(n) {
        case .general(let value, let prefix, let suffix):
            text = "\(prefix)\(SheetNumFmt.formatGeneral(value))\(suffix)"
        case .text(let s):
            text = s
        case .dateTime(let parts):
            text = sheetRenderSerial(n, parts: parts, date1904: date1904)
        }
    }
    return SharedText.clean(text)
}

/// Render a date/time serial: elapsed formats as a duration, sub-day
/// serials as a time of day, everything else as an ISO-like date.
func sheetRenderSerial(_ serial: Double, parts: SheetNumFmt.DateParts, date1904: Bool) -> String {
    if !serial.isFinite { return SheetNumFmt.formatGeneral(serial) }
    if parts.elapsed { return sheetFormatDurationDays(serial) }
    if !parts.date { return sheetFormatTimeOfDay(serial.truncatingRemainder(dividingBy: 1)) }
    if abs(serial) < 1.0 {
        return parts.time ? sheetFormatTimeOfDay(serial) : SheetNumFmt.formatGeneral(serial)
    }
    if !(0.0..<2_958_466.0).contains(serial) {
        return SheetNumFmt.formatGeneral(serial)
    }
    var days = Int64(serial.rounded(.towardZero))
    // The fictitious 1900-02-29 has no date to render.
    if !date1904 && days == 60 { return SheetNumFmt.formatGeneral(serial) }
    var secs = Int64((serial.truncatingRemainder(dividingBy: 1) * 86_400).rounded())
    if secs >= 86_400 { secs = 0; days += 1 }
    let civilDays = date1904
        ? days + sheetDaysFromCivil(1904, 1, 1)
        : days - (days >= 60 ? 1 : 0) + sheetDaysFromCivil(1899, 12, 31)
    let (y, m, d) = sheetCivilFromDays(civilDays)
    if !(1...9999).contains(y) { return SheetNumFmt.formatGeneral(serial) }
    var out = String(format: "%04d-%02d-%02d", y, m, d)
    if parts.time && secs != 0 {
        out += String(format: " %02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }
    return out
}

/// Render a time-of-day serial (a fraction of a day) as `hh:mm:ss`.
func sheetFormatTimeOfDay(_ days: Double) -> String {
    let totalSecs = UInt64((abs(days) * 86_400).rounded()) % 86_400
    return String(format: "%02d:%02d:%02d", totalSecs / 3600, (totalSecs % 3600) / 60, totalSecs % 60)
}

/// Render an Excel duration (stored in days) as `[h]:mm:ss`.
func sheetFormatDurationDays(_ days: Double) -> String {
    let sign = days < 0 ? "-" : ""
    let totalSecs = UInt64((abs(days) * 86_400).rounded())
    return String(format: "%@%d:%02d:%02d", sign, totalSecs / 3600, (totalSecs % 3600) / 60, totalSecs % 60)
}

/// Days from 1970-01-01 to a civil date (Howard Hinnant's algorithm).
func sheetDaysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
    let y = y0 - (m <= 2 ? 1 : 0)
    let era = y >= 0 ? y / 400 : (y - 399) / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// A civil date from days since 1970-01-01.
func sheetCivilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
    let z = z0 + 719_468
    let era = z >= 0 ? z / 146_097 : (z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (y + (m <= 2 ? 1 : 0), m, d)
}

private extension SheetNumFmt.NumberFormat.Section {
    var isText: Bool {
        if case .text = body { return true }
        return false
    }
    var prefix: String {
        if case .number(let n) = body { return n.prefix }
        return ""
    }
    var suffix: String {
        if case .number(let n) = body { return n.suffix }
        return ""
    }
}
