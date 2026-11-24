import Foundation

/// Context in which inline markup is rendered.
enum InlineContext {
    /// Ordinary block body (paragraphs, list items, blockquotes, footnotes, table cells).
    case block
    /// Heading line (`= ...`): single line, no hard line breaks.
    case heading
}

/// Escape plain text for safe inclusion in Typst markup mode (including inside
/// `[...]` content blocks).
///
/// Neutralizes every character and line-start sequence that carries syntactic
/// meaning in Typst markup mode so arbitrary source text renders literally
/// inside both top-level markup and `[...]` content blocks without ever
/// breaking `typst-syntax`.
func escapeMarkup(_ text: String, atLineStart: Bool) -> String {
    var out = ""
    out.reserveCapacity(text.count + 8)
    let chars = Array(text.filter { $0 == "\n" || $0 == "\t" || !isControl($0) })

    var atStart = atLineStart
    var i = 0
    while i < chars.count {
        let c = chars[i]
        let next = i + 1 < chars.count ? chars[i + 1] : nil

        if c == "\n" {
            out.append("\n")
            atStart = true
            i += 1
            continue
        }

        if atStart && (c == " " || c == "\t") {
            out.append(c)
            i += 1
            continue
        }

        if atStart {
            switch c {
            case "=":
                out += "\\="
                atStart = false
                i += 1
                continue
            case "-" where next?.isWhitespace ?? true:
                out += "\\-"
                atStart = false
                i += 1
                continue
            case "+" where next?.isWhitespace ?? true:
                out += "\\+"
                atStart = false
                i += 1
                continue
            case "/" where next?.isWhitespace ?? true:
                out += "\\/"
                atStart = false
                i += 1
                continue
            default:
                break
            }
            atStart = false
        }

        switch c {
        case "\\": out += "\\\\"
        case "#": out += "\\#"
        case "$": out += "\\$"
        case "*": out += "\\*"
        case "_": out += "\\_"
        case "`": out += "\\`"
        case "<": out += "\\<"
        case ">": out += "\\>"
        case "@": out += "\\@"
        case "~": out += "\\~"
        case "[": out += "\\["
        case "]": out += "\\]"
        case "/" where next == "/" || next == "*":
            // Prevent line comments (`//`) and block comments (`/*`).
            out += "\\/"
        default: out.append(c)
        }
        i += 1
    }
    return out
}

/// Escape a string for inclusion inside a Typst `"..."` string literal.
func escapeString(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count + 4)
    for c in text {
        switch c {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if isControl(c) { continue }
            out.append(c)
        }
    }
    return out
}

/// Choose a backtick fence strictly longer than any contiguous backtick run in `text`.
func backtickFence(_ text: String, minTicks: Int) -> String {
    var maxRun = 0
    var cur = 0
    for b in text.utf8 {
        if b == UInt8(ascii: "`") {
            cur += 1
            maxRun = max(maxRun, cur)
        } else {
            cur = 0
        }
    }
    return String(repeating: "`", count: max(minTicks, maxRun + 1))
}

/// Sanitize a fenced code block info/language tag so it cannot close or break the fence.
func sanitizeLang(_ lang: String) -> String {
    String(lang.trimmingCharacters(in: .whitespaces).prefix { !$0.isWhitespace }
        .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" || $0 == "." || $0 == "#") })
}

/// Unicode `Cc` control characters (Rust `char::is_control` equivalent).
func isControl(_ c: Character) -> Bool {
    c.unicodeScalars.contains { $0.properties.generalCategory == .control }
}
