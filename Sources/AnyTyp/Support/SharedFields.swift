import Foundation

/// Word field-instruction parsing (DOC, DOCX, RTF)
/// (port of `shared/fields.rs`).
struct FieldFrame {
    var instr = ""
    var inResult = false
    var inlines: [AnyTypInline] = []
}

/// Finish a field: wrap the result in a link when the instruction is a
/// hyperlink, otherwise pass the result content through.
func fieldResult(_ instr: String, content: [AnyTypInline]) -> [AnyTypInline] {
    if let target = hyperlinkTarget(instr), !inlinesAreEmpty(content) {
        return [.link(content: content, target: target)]
    }
    return content
}

private enum FieldToken {
    case word(String)
    case `switch`(Character)
}

/// Tokenize a field instruction: quoted strings (with `\"` and `\\`
/// escapes), backslash switches, bare words.
private func tokenizeField(_ instr: String) -> [FieldToken] {
    var out: [FieldToken] = []
    let chars = Array(instr)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c.isWhitespace {
            i += 1
        } else if c == "\"" {
            i += 1
            var word = ""
            while i < chars.count {
                let ch = chars[i]
                i += 1
                if ch == "\"" { break }
                if ch == "\\" {
                    if i < chars.count {
                        let esc = chars[i]
                        i += 1
                        if esc == "\"" || esc == "\\" {
                            word.append(esc)
                        } else {
                            word.append("\\")
                            word.append(esc)
                        }
                    } else {
                        break
                    }
                } else {
                    word.append(ch)
                }
            }
            out.append(.word(word))
        } else if c == "\\" {
            i += 1
            if i < chars.count {
                out.append(.switch(Character(chars[i].lowercased())))
                i += 1
            }
        } else {
            var word = ""
            while i < chars.count, !chars[i].isWhitespace {
                word.append(chars[i])
                i += 1
            }
            out.append(.word(word))
        }
    }
    return out
}

/// Switches of the HYPERLINK field that take an argument.
private func hyperlinkSwitchTakesArg(_ s: Character) -> Bool {
    s == "l" || s == "o" || s == "t"
}

/// Interpret a HYPERLINK field instruction as a link target.
func hyperlinkTarget(_ instr: String) -> AnyTypLinkTarget? {
    var tokens = tokenizeField(instr)
    guard case .word(let first)? = tokens.first,
          first.caseInsensitiveCompare("HYPERLINK") == .orderedSame else {
        return nil
    }
    tokens.removeFirst()
    var url: String? = nil
    var anchor: String? = nil
    var i = 0
    while i < tokens.count {
        let token = tokens[i]
        i += 1
        switch token {
        case .word(let w):
            if url == nil, !w.trimmingCharacters(in: .whitespaces).isEmpty {
                url = w.trimmingCharacters(in: .whitespaces)
            }
        case .switch(let s):
            // The argument is the next token only when it is a word; a
            // following switch means the argument was omitted.
            var arg: String? = nil
            if hyperlinkSwitchTakesArg(s), i < tokens.count,
               case .word(let w) = tokens[i] {
                arg = w
                i += 1
            }
            if s == "l", let a = arg, !a.trimmingCharacters(in: .whitespaces).isEmpty {
                anchor = a.trimmingCharacters(in: .whitespaces)
            }
        }
    }
    if let url, let frag = anchor {
        return classifyLinkTarget("\(url)#\(frag)")
    }
    if let url { return classifyLinkTarget(url) }
    if let frag = anchor { return .anchor(frag) }
    return nil
}

/// Classify an OPC relationship target as a link target. External-mode
/// targets are parsed like hyperlink field targets; internal-mode targets
/// stay package-relative.
func classifyRelTarget(external: Bool, target: String) -> AnyTypLinkTarget {
    external ? classifyLinkTarget(target) : .relative(target)
}

private func classifyLinkTarget(_ url: String) -> AnyTypLinkTarget {
    if url.hasPrefix("#") {
        return .anchor(String(url.dropFirst()))
    }
    return isAbsoluteURI(url) ? .external(url) : .relative(url)
}
