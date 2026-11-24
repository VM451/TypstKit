import Foundation
import TypstSyntax
import TypstUtils

// YAML loading — port of upstream `loading/yaml.rs` (serde_yaml based)
// as a YAML 1.2 subset: block/flow mappings and sequences, plain and
// quoted scalars, comments, and custom tags (ignored, value kept).
// Numbers that overflow i64 decode as floats, matching upstream's
// documented behavior.

/// YAML parse error with a position.
struct YamlError: Error {
    var line: Int
    var col: Int
    var message: String
}

/// Parse a YAML document into a `Value`.
func parseYAML(_ text: String) -> Result<Value, YamlError> {
    var parser = YamlParser(text)
    do {
        return .success(try parser.parseDocument())
    } catch let e as YamlError {
        return .failure(e)
    } catch {
        return .failure(YamlError(line: 1, col: 1, message: "\(error)"))
    }
}

struct YamlParser {
    let scalars: [Character]
    var pos = 0
    var line = 1
    var col = 1

    init(_ text: String) { scalars = Array(text) }

    // MARK: - low-level

    func peek(_ ahead: Int = 0) -> Character? {
        pos + ahead < scalars.count ? scalars[pos + ahead] : nil
    }

    func peekStr(_ s: String) -> Bool {
        let chars = Array(s)
        guard pos + chars.count <= scalars.count else { return false }
        for (i, c) in chars.enumerated() where scalars[pos + i] != c {
            return false
        }
        return true
    }

    @discardableResult
    mutating func advance() -> Character? {
        guard pos < scalars.count else { return nil }
        let c = scalars[pos]
        pos += 1
        if c == "\n" { line += 1; col = 1 } else { col += 1 }
        return c
    }

    mutating func error(_ message: String) -> YamlError {
        YamlError(line: line, col: col, message: message)
    }

    /// Advance past the rest of the current line.
    mutating func skipToEOL() {
        while let c = peek(), c != "\n" { advance() }
    }

    /// Consume one line terminator if present.
    mutating func skipNewline() {
        if matchStr("\r\n") || matchStr("\n") || matchStr("\r") {}
    }

    mutating func match(_ c: Character) -> Bool {
        guard peek() == c else { return false }
        advance()
        return true
    }

    @discardableResult
    mutating func matchStr(_ s: String) -> Bool {
        guard peekStr(s) else { return false }
        for _ in s { advance() }
        return true
    }

    /// Skip spaces/tabs (not newlines).
    mutating func skipInlineWS() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }

    /// Skip blank lines and full-line comments. Content lines keep
    /// their leading indentation (position stays at line start).
    mutating func skipBlankAndComments() {
        while true {
            let save = pos
            var i = pos
            while i < scalars.count && scalars[i] == " " { i += 1 }
            if i < scalars.count && scalars[i] == "#" {
                pos = i
                skipToEOL(); skipNewline()
                continue
            }
            if i < scalars.count && (scalars[i] == "\n" || scalars[i] == "\r") {
                pos = i; skipNewline(); continue
            }
            pos = save
            return
        }
    }

    /// Compute the indentation (spaces) of the current line, or nil at EOF.
    /// Assumes we're at line start.
    func currentIndent() -> Int? {
        var i = pos
        var indent = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == " " { indent += 1; i += 1 }
            else if c == "\t" { return nil } // tabs illegal for indent
            else if c == "\n" || c == "\r" { return nil }
            else { break }
        }
        guard i < scalars.count else { return nil }
        return indent
    }

    // MARK: - document

    mutating func parseDocument() throws -> Value {
        skipBlankAndComments()
        guard pos < scalars.count else { return .none }
        // Handle document markers.
        if matchStr("---") { skipToEOL(); skipNewline(); skipBlankAndComments() }
        if matchStr("...") { skipToEOL(); skipNewline() }
        guard pos < scalars.count else { return .none }
        let value = try parseBlock(indent: currentIndent() ?? 0)
        skipBlankAndComments()
        return value
    }

    // MARK: - block parsing

    /// Parse a block node at the given indentation.
    mutating func parseBlock(indent: Int) throws -> Value {
        skipBlankAndComments()
        guard let ind = currentIndent(), ind >= indent, pos < scalars.count else {
            return .none
        }
        // First content char sits `ind` spaces ahead — inspect without
        // moving pos (children expect line-start position).
        var j = pos
        for _ in 0..<ind { j += 1 }
        let c = j < scalars.count ? scalars[j] : nil
        let after = j + 1 < scalars.count ? scalars[j + 1] : "\n"
        // Sequence item? ('-' followed by space/EOL, not '-foo').
        if c == "-", after == " " || after == "\t" || after == "\n" || after == "\r" {
            return try parseSequence(indent: ind)
        }
        // Mapping? Look for 'key:' pattern on this line.
        if findMappingColon(at: pos) != nil {
            return try parseMapping(indent: ind)
        }
        // Otherwise a scalar (possibly multi-line plain).
        pos = j
        return try parseScalarValue()
    }

    /// Find the ':' that ends a mapping key on the current line,
    /// respecting quotes. Returns position or nil.
    func findMappingColon(at start: Int) -> Int? {
        var i = start
        var inSingle = false
        var inDouble = false
        while i < scalars.count {
            let c = scalars[i]
            if c == "\n" || c == "\r" { return nil }
            if inSingle {
                if c == "'" { inSingle = false }
            } else if inDouble {
                if c == "\\" { i += 1 }
                else if c == "\"" { inDouble = false }
            } else {
                if c == "'" { inSingle = true }
                else if c == "\"" { inDouble = true }
                else if c == ":" {
                    // ':' must be followed by space/EOL to be a mapping colon.
                    let next = i + 1 < scalars.count ? scalars[i + 1] : "\n"
                    if next == " " || next == "\t" || next == "\n" || next == "\r" {
                        return i
                    }
                }
                else if c == "#" { return nil } // comment before colon
            }
            i += 1
        }
        return nil
    }

    /// Parse a block sequence at `indent`.
    mutating func parseSequence(indent: Int) throws -> Value {
        var items: [Value] = []
        while true {
            skipBlankAndCommentsPreservingIndent(indent)
            guard let ind = currentIndent(), ind == indent else { break }
            skipInlineWS()
            guard peek() == "-" else { break }
            // Consume '-'.
            advance()
            // After '-', either EOL (nested block) or inline value.
            skipInlineWS()
            if let c = peek(), c == "\n" || c == "\r" {
                skipNewline()
                skipBlankAndComments()
                let nestedIndent = currentIndent() ?? indent + 1
                items.append(try parseBlock(indent: nestedIndent))
            } else {
                // Inline content on the '-' line: could be scalar, flow,
                // or a mapping starting here.
                items.append(try parseInlineOrNested(indent: indent))
            }
        }
        return .array(ArrayValue(items: items))
    }

    /// Skip blank/comment lines but only those with indent >= `min`.
    /// (Comments/blank lines at any indent are allowed inside a block.)
    mutating func skipBlankAndCommentsPreservingIndent(_ min: Int) {
        while true {
            var i = pos
            var ind = 0
            while i < scalars.count && scalars[i] == " " { ind += 1; i += 1 }
            if i < scalars.count && scalars[i] == "#" {
                // Comment line — skip regardless of indent.
                pos = i
                skipToEOL(); skipNewline()
                continue
            }
            if i < scalars.count && (scalars[i] == "\n" || scalars[i] == "\r") {
                pos = i; skipNewline(); continue
            }
            return
        }
        _ = min
    }

    /// Parse content following `- ` on a sequence line: inline value,
    /// or a mapping whose first pair is on this line.
    mutating func parseInlineOrNested(indent: Int) throws -> Value {
        guard pos < scalars.count else { return .none }
        let c = peek()!
        if c == "[" || c == "{" { return try parseFlow() }
        if c == "'" || c == "\"" || c == "|" || c == ">" || c == "!" || c == "&" || c == "*" {
            return try parseScalarValue()
        }
        // Could be `key: value` starting a compact mapping, or scalar.
        if findMappingColon(at: pos) != nil {
            return try parseCompactMapping(seqIndent: indent)
        }
        return try parseScalarValue()
    }

    /// Parse a mapping that starts mid-line (e.g. `- key: value`) with
    /// subsequent pairs at deeper indentation.
    mutating func parseCompactMapping(seqIndent: Int) throws -> Value {
        var dict = Dict()
        // First pair is on the current line.
        try parseMappingPair(into: &dict, lineIndent: seqIndent + 2)
        // Following pairs must be indented > seqIndent.
        while true {
            skipBlankAndComments()
            guard let ind = currentIndent(), ind > seqIndent else { break }
            guard findMappingColon(at: pos) != nil else { break }
            try parseMappingPair(into: &dict, lineIndent: ind)
        }
        return .dict(dict)
    }

    /// Parse a block mapping at `indent`.
    mutating func parseMapping(indent: Int) throws -> Value {
        var dict = Dict()
        while true {
            skipBlankAndCommentsPreservingIndent(indent)
            guard let ind = currentIndent(), ind == indent,
                  findMappingColon(at: pos) != nil else { break }
            try parseMappingPair(into: &dict, lineIndent: ind)
        }
        return .dict(dict)
    }

    /// Parse one `key: value` pair into `dict`.
    mutating func parseMappingPair(into dict: inout Dict, lineIndent: Int) throws {
        // Parse key (plain or quoted).
        let key = try parseKey()
        skipInlineWS()
        guard match(":") else { throw error("expected `:`") }
        skipInlineWS()

        // Value: inline, nested block, or empty (null / nested block).
        var atLineEnd = false
        if let c = peek() {
            if c == "\n" || c == "\r" {
                // Value on following lines — after the nested block,
                // pos is already at the next line start.
                advance()
                skipBlankAndComments()
                if let ind = currentIndent(), ind > lineIndent {
                    dict.insert(key, try parseBlock(indent: ind))
                    atLineEnd = true
                } else {
                    dict.insert(key, .none)
                }
            } else if c == "#" {
                // `key: # comment` → null.
                dict.insert(key, .none)
                skipToEOL()
            } else {
                dict.insert(key, try parseValueAfterKey())
            }
        } else {
            dict.insert(key, .none)
        }
        // Consume rest of line (only when the value ended mid-line).
        if !atLineEnd, let c = peek(), c != "\n", c != "\r" {
            skipToEOL()
        }
        skipNewline()
    }

    mutating func parseKey() throws -> String {
        skipInlineWS()
        guard let c = peek() else { throw error("expected mapping key") }
        if c == "'" {
            var out = ""
            advance()
            while let ch = peek(), ch != "'" { out.append(advance()!) }
            guard match("'") else { throw error("unterminated single-quoted key") }
            return out
        }
        if c == "\"" {
            var out = ""
            advance()
            while let ch = peek(), ch != "\"" {
                if ch == "\\" {
                    advance()
                    out += try parseDoubleEscape()
                } else { out.append(advance()!) }
            }
            guard match("\"") else { throw error("unterminated double-quoted key") }
            return out
        }
        // Plain key: up to ':' or comment.
        var key = ""
        while let ch = peek() {
            if ch == ":" || ch == "#" || ch == "\n" || ch == "\r" { break }
            key.append(advance()!)
        }
        key = String(key.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        // Trim trailing ws (':' check consumed leading already skipped).
        while key.last == " " || key.last == "\t" { key.removeLast() }
        guard !key.isEmpty else { throw error("expected mapping key") }
        return key
    }

    // MARK: - values

    /// Parse a value that starts mid-line (after `key: ` or `- `).
    mutating func parseValueAfterKey() throws -> Value {
        guard let c = peek() else { return .none }
        if c == "[" || c == "{" { return try parseFlow() }
        if c == "|" || c == ">" { return try parseBlockScalar() }
        if c == "!" { _ = try parseTag(); return try parseValueAfterKey() }
        if c == "&" || c == "*" {
            // Anchors/aliases unsupported — skip token, parse inner.
            _ = parseAnchorOrAlias()
            if c == "&" { return try parseValueAfterKey() }
            return .none // alias → null (unsupported)
        }
        return try parseScalarValue()
    }

    /// Parse an anchor (`&name`) or alias (`*name`) token.
    mutating func parseAnchorOrAlias() -> String {
        var out = ""
        while let c = peek(), c != " " && c != "\t" && c != "\n" && c != "\r" && c != "," && c != "]" && c != "}" {
            out.append(advance()!)
        }
        return out
    }

    /// Parse a `!tag` token (custom tags ignored upstream).
    mutating func parseTag() throws -> String {
        var tag = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "!" || c == "-" || c == "/" || c == ":" {
            tag.append(advance()!)
        }
        return tag
    }

    /// Parse a scalar value starting at the cursor, possibly spanning
    /// multiple lines (plain scalar continuation).
    mutating func parseScalarValue() throws -> Value {
        guard pos < scalars.count else { return .none }
        let c = peek()!
        if c == "'" { return try parseSingleQuoted() }
        if c == "\"" { return try parseDoubleQuoted() }
        return try parsePlainScalar()
    }

    mutating func parseSingleQuoted() throws -> Value {
        advance() // opening '
        var out = ""
        while pos < scalars.count {
            let ch = peek()!
            if ch == "'" {
                advance()
                if peek() == "'" { // '' escape
                    advance()
                    out.append("'")
                    continue
                }
                return .str(Str(out))
            }
            out.append(advance()!)
        }
        throw error("unterminated single-quoted string")
    }

    mutating func parseDoubleQuoted() throws -> Value {
        advance() // opening "
        var out = ""
        while pos < scalars.count {
            let ch = peek()!
            if ch == "\"" { advance(); return .str(Str(out)) }
            if ch == "\\" {
                advance()
                out += try parseDoubleEscape()
            } else {
                out.append(advance()!)
            }
        }
        throw error("unterminated double-quoted string")
    }

    mutating func parseDoubleEscape() throws -> String {
        guard let c = peek() else { throw error("unterminated escape") }
        switch c {
        case "0": advance(); return "\0"
        case "a": advance(); return "\u{07}"
        case "b": advance(); return "\u{08}"
        case "t", "\t": advance(); return "\t"
        case "n": advance(); return "\n"
        case "v": advance(); return "\u{0B}"
        case "f": advance(); return "\u{0C}"
        case "r": advance(); return "\r"
        case "e": advance(); return "\u{1B}"
        case "\"": advance(); return "\""
        case "/": advance(); return "/"
        case "\\": advance(); return "\\"
        case " ": advance(); return " "
        case "N": advance(); return "\u{85}"
        case "_": advance(); return "\u{A0}"
        case "L": advance(); return "\u{2028}"
        case "P": advance(); return "\u{2029}"
        case "x":
            advance()
            let hex = try readHex(2)
            guard let cp = UInt32(hex, radix: 16), let s = Unicode.Scalar(cp) else {
                throw error("invalid escape")
            }
            return String(s)
        case "u":
            advance()
            let hex = try readHex(4)
            guard let cp = UInt32(hex, radix: 16), let s = Unicode.Scalar(cp) else {
                throw error("invalid escape")
            }
            return String(s)
        case "U":
            advance()
            let hex = try readHex(8)
            guard let cp = UInt32(hex, radix: 16), let s = Unicode.Scalar(cp) else {
                throw error("invalid escape")
            }
            return String(s)
        default:
            throw error("invalid escape sequence '\\\(c)'")
        }
    }

    mutating func readHex(_ digits: Int) throws -> String {
        var out = ""
        for _ in 0..<digits {
            guard let c = peek(), c.isHexDigit else {
                throw error("expected \(digits) hex digits")
            }
            out.append(advance()!)
        }
        return out
    }

    /// Parse `|` or `>` block scalars (literal / folded).
    mutating func parseBlockScalar() throws -> Value {
        let folded = match(">")
        guard folded || match("|") else { throw error("expected block scalar") }
        // Optional chomping/indent indicators.
        var strip = false, keep = false
        var explicitIndent: Int? = nil
        while let c = peek(), c == "+" || c == "-" || c.isNumber {
            if c == "+" { keep = true; advance() }
            else if c == "-" { strip = true; advance() }
            else { explicitIndent = Int(String(advance()!)) }
        }
        // Rest of header line (comments allowed).
        skipToEOL()
        skipNewline()

        // Determine content indent from first non-blank line.
        skipBlankAndComments()
        var contentIndent = explicitIndent ?? (currentIndent() ?? 1)
        if explicitIndent == nil {
            // Auto-detect: first non-empty line's indent.
            var i = pos
            var ind = 0
            while i < scalars.count {
                let c = scalars[i]
                if c == " " { ind += 1; i += 1 }
                else if c == "\n" || c == "\r" { i += 1; ind = 0 }
                else { break }
            }
            contentIndent = ind
            _ = i
        }

        var lines: [String] = []
        while true {
            guard pos < scalars.count else { break }
            // Measure indent of this line.
            var i = pos
            var ind = 0
            while i < scalars.count && scalars[i] == " " { ind += 1; i += 1 }
            if i >= scalars.count { break }
            let c = scalars[i]
            if c == "\n" || c == "\r" {
                // Blank line inside scalar.
                lines.append("")
                skipNewline()
                continue
            }
            if ind < contentIndent {
                // Dedent ends the scalar.
                break
            }
            // Consume `ind` spaces then the line content.
            pos = i
            var line = ""
            while let ch = peek(), ch != "\n", ch != "\r" {
                // Strip contentIndent leading spaces (we're past them).
                line.append(advance()!)
            }
            // Remove up-to-contentIndent leading spaces from line.
            var trimmed = line
            var removed = 0
            while removed < contentIndent, trimmed.first == " " {
                trimmed.removeFirst(); removed += 1
            }
            lines.append(trimmed)
            skipNewline()
        }

        var result: String
        if folded {
            // Fold: join lines with space, blank lines → newline.
            var out = ""
            var prevBlank = true // leading blank suppressed
            for (idx, l) in lines.enumerated() {
                if l.isEmpty {
                    out += "\n"
                    prevBlank = true
                } else {
                    if !prevBlank && idx > 0 { out += " " }
                    out += l
                    prevBlank = false
                }
            }
            result = out
        } else {
            result = lines.joined(separator: "\n")
        }
        // Chomping.
        if strip {
            while result.hasSuffix("\n") { result.removeLast() }
        } else if !keep {
            // Clip: single trailing newline.
            while result.hasSuffix("\n\n") { result.removeLast() }
            if !result.hasSuffix("\n"), !result.isEmpty { result += "\n" }
        }
        return .str(Str(result))
    }

    /// Parse a plain (unquoted) scalar up to EOL/comment, with
    /// multi-line continuation support.
    mutating func parsePlainScalar() throws -> Value {
        var text = ""
        var firstLine = true
        while pos < scalars.count {
            // Read to EOL or comment.
            var line = ""
            while let c = peek(), c != "\n", c != "\r", c != "#" {
                line.append(advance()!)
            }
            if peek() == "#" {
                // '#' starts a comment only if preceded by whitespace.
                if line.last == " " || line.last == "\t" || line.isEmpty {
                    // Trim trailing ws before '#'.
                } else {
                    line.append(advance()!)
                    continue
                }
            }
            // Trim trailing whitespace.
            while line.last == " " || line.last == "\t" { line.removeLast() }
            if !firstLine {
                text += " "
            }
            text += line
            firstLine = false
            // Check for continuation: next non-blank line more indented.
            let savePos = pos
            skipNewline()
            // Peek next meaningful line.
            var i = pos
            var ind = 0
            var sawContent = false
            var nextIsCommentOrBlank = true
            while i < scalars.count {
                let c = scalars[i]
                if c == " " { ind += 1; i += 1; continue }
                if c == "\n" || c == "\r" { i += 1; ind = 0; continue }
                if c == "#" { i += 1; continue }
                nextIsCommentOrBlank = false
                sawContent = true
                break
            }
            _ = sawContent
            if nextIsCommentOrBlank || ind <= 0 {
                pos = savePos
                break
            }
            // More-indented continuation: probe the next line's
            // content without committing — a mapping/sequence start
            // ends the scalar and the newline must stay for the caller.
            pos = savePos
            skipNewline()
            skipInlineWS()
            if let c = peek(), c == "-" || findMappingColon(at: pos) != nil {
                pos = savePos
                break
            }
        }
        return scalarStringToValue(text)
    }

    // MARK: - flow collections

    mutating func parseFlow() throws -> Value {
        skipInlineWS()
        guard let c = peek() else { throw error("expected flow value") }
        if c == "[" { return try parseFlowSequence() }
        if c == "{" { return try parseFlowMapping() }
        return try parseScalarValue()
    }

    mutating func parseFlowSequence() throws -> Value {
        advance() // '['
        var items: [Value] = []
        while true {
            skipFlowWS()
            if match("]") { break }
            items.append(try parseFlowValue())
            skipFlowWS()
            if match("]") { break }
            guard match(",") else { throw error("expected `,` or `]`") }
        }
        return .array(ArrayValue(items: items))
    }

    mutating func parseFlowMapping() throws -> Value {
        advance() // '{'
        var dict = Dict()
        while true {
            skipFlowWS()
            if match("}") { break }
            let key = try parseFlowKey()
            skipFlowWS()
            guard match(":") else { throw error("expected `:`") }
            skipFlowWS()
            let value = try parseFlowValue()
            dict.insert(key, value)
            skipFlowWS()
            if match("}") { break }
            guard match(",") else { throw error("expected `,` or `}`") }
        }
        return .dict(dict)
    }

    mutating func parseFlowKey() throws -> String {
        skipFlowWS()
        guard let c = peek() else { throw error("expected key") }
        if c == "'" || c == "\"" {
            let v = try parseScalarValue()
            guard case .str(let s) = v else { throw error("expected string key") }
            return s.value
        }
        var key = ""
        while let ch = peek(), ch != ":", ch != ",", ch != "}", ch != "#" {
            key.append(advance()!)
        }
        while key.last == " " || key.last == "\t" { key.removeLast() }
        while key.first == " " || key.first == "\t" { key.removeFirst() }
        guard !key.isEmpty else { throw error("expected key") }
        return key
    }

    mutating func parseFlowValue() throws -> Value {
        skipFlowWS()
        guard pos < scalars.count else { throw error("expected value") }
        let c = peek()!
        if c == "[" || c == "{" { return try parseFlow() }
        if c == "!" { _ = try parseTag(); return try parseFlowValue() }
        if c == "|" || c == ">" { return try parseBlockScalar() }
        if c == "&" {
            _ = parseAnchorOrAlias()
            return try parseFlowValue()
        }
        if c == "*" {
            _ = parseAnchorOrAlias()
            return .none
        }
        if c == "'" || c == "\"" { return try parseScalarValue() }
        // Plain scalar in flow: up to , ] } or #.
        var text = ""
        while let ch = peek(), ch != ",", ch != "]", ch != "}", ch != "\n", ch != "\r", ch != "#" {
            text.append(advance()!)
        }
        while text.last == " " || text.last == "\t" { text.removeLast() }
        while text.first == " " || text.first == "\t" { text.removeFirst() }
        return scalarStringToValue(text)
    }

    /// Skip ws + comments + newlines inside flow collections.
    mutating func skipFlowWS() {
        while true {
            while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            }
            if match("#") { skipToEOL(); continue }
            return
        }
    }

    // MARK: - scalar typing

    /// Convert a plain scalar string to a typed `Value`.
    /// YAML 1.2 core schema: null/bool/int/float/str.
    func scalarStringToValue(_ raw: String) -> Value {
        let s = raw.trimmingCharacters(in: .whitespaces)
        // Null.
        if s.isEmpty || s == "~" || s == "null" || s == "Null" || s == "NULL" {
            return .none
        }
        // Bool.
        switch s {
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        // Int (i64 range; overflow → float per upstream docs).
        if let i = parseYamlInt(s) {
            return .int(i)
        }
        // Float.
        if looksLikeYamlFloat(s), let f = Double(s) {
            return .float(f)
        }
        // Integers too large for i64 → approximate float.
        if looksLikeYamlInt(s), let f = Double(s) {
            return .float(f)
        }
        return .str(Str(s))
    }

    func looksLikeYamlInt(_ s: String) -> Bool {
        var t = s
        if t.hasPrefix("+") || t.hasPrefix("-") { t.removeFirst() }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt64(t.dropFirst(2), radix: 16) != nil }
        if t.hasPrefix("0o") || t.hasPrefix("0O") { return UInt64(t.dropFirst(2), radix: 8) != nil }
        if t.hasPrefix("0b") || t.hasPrefix("0B") { return UInt64(t.dropFirst(2), radix: 2) != nil }
        return !t.isEmpty && t.allSatisfy(\.isNumber)
    }

    func looksLikeYamlFloat(_ s: String) -> Bool {
        let t = s.lowercased()
        if t == ".inf" || t == "+.inf" || t == "-.inf"
            || t == ".nan" || t == "+.nan" || t == "-.nan" { return true }
        // Needs '.' or 'e' to be a float (ints handled above).
        guard t.contains(".") || t.contains("e") else { return false }
        // Reject things like '1.2.3' or 'abc.def'.
        var mantissa = t
        if let eIdx = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(mantissa[..<eIdx])
        }
        var seenDot = false
        var seenDigit = false
        for c in mantissa {
            if c == "+" || c == "-" { continue }
            if c == "." {
                if seenDot { return false }
                seenDot = true
            } else if c.isNumber {
                seenDigit = true
            } else {
                return false
            }
        }
        return seenDigit
    }

    func parseYamlInt(_ s: String) -> Int64? {
        var t = s.replacingOccurrences(of: "_", with: "")
        var negative = false
        if t.hasPrefix("+") { t.removeFirst() }
        else if t.hasPrefix("-") { negative = true; t.removeFirst() }
        // Hex/octal/binary.
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            guard let v = UInt64(t.dropFirst(2), radix: 16) else { return nil }
            if negative { return v <= UInt64(Int64.max) + 1 ? (v == UInt64(Int64.max) + 1 ? Int64.min : -Int64(v)) : nil }
            return v <= UInt64(Int64.max) ? Int64(v) : nil
        }
        if t.hasPrefix("0o") || t.hasPrefix("0O") {
            guard let v = UInt64(t.dropFirst(2), radix: 8) else { return nil }
            if negative { return v <= UInt64(Int64.max) + 1 ? (v == UInt64(Int64.max) + 1 ? Int64.min : -Int64(v)) : nil }
            return v <= UInt64(Int64.max) ? Int64(v) : nil
        }
        if t.hasPrefix("0b") || t.hasPrefix("0B") {
            guard let v = UInt64(t.dropFirst(2), radix: 2) else { return nil }
            if negative { return v <= UInt64(Int64.max) + 1 ? (v == UInt64(Int64.max) + 1 ? Int64.min : -Int64(v)) : nil }
            return v <= UInt64(Int64.max) ? Int64(v) : nil
        }
        guard !t.isEmpty, t.allSatisfy(\.isNumber), let v = UInt64(t) else { return nil }
        if negative {
            guard v <= UInt64(Int64.max) + 1 else { return nil }
            if v == UInt64(Int64.max) + 1 { return Int64.min }
            return -Int64(v)
        }
        guard v <= UInt64(Int64.max) else { return nil }
        return Int64(v)
    }
}

// MARK: - yaml()

/// `yaml(source)` — port of upstream `yaml`.
let yamlFunc = nativeFunc(
    "yaml",
    title: "YAML",
    since: .version([0, 1, 0]),
    docs: "Reads structured data from a YAML file.",
    params: [
        NativeParamInfo(name: "source", input: DataSource.input, required: true),
    ],
    returns: Value.output
) { engine, _, args in
    let source: Spanned<DataSource, Span> = try args.expectT("source")
    try args.finishT()
    let loaded = try load(source, engine.world)
    switch parseYAML(String(decoding: loaded.data.storage, as: UTF8.self)) {
    case .success(let v): return v
    case .failure(let e):
        throw SourceDiagnostics([LoadError.text(
            ReportTextPos.lineCol(.oneBased(e.line, e.col)),
            "failed to parse YAML", e.message).within(loaded)])
    }
}

/// `yaml.encode(value)` — port of upstream `yaml.encode`.
let yamlEncode = nativeFunc(
    "encode",
    title: "Encode YAML",
    since: .version([0, 8, 0]),
    docs: "Encodes structured data into a YAML string.",
    params: [
        NativeParamInfo(name: "value", input: Value.input, required: true),
    ],
    returns: Str.output
) { _, _, args in
    let value: Spanned<Value, Span> = try args.expectT("value")
    try args.finishT()
    return Str(encodeYAML(value.value))
}

// MARK: - YAML encoder

/// Escape a string for YAML double-quoted style when needed.
func yamlQuote(_ s: String) -> String {
    // Plain style is fine unless the string would re-parse as another
    // type or contains YAML-significant characters.
    if yamlNeedsQuotes(s) {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(c)
            }
        }
        return out + "\""
    }
    return s
}

/// Whether `s` must be quoted to survive a YAML round-trip.
func yamlNeedsQuotes(_ s: String) -> Bool {
    if s.isEmpty { return true }
    // Would parse as non-string.
    switch s {
    case "~", "null", "Null", "NULL", "true", "True", "TRUE",
         "false", "False", "FALSE", ".inf", ".Inf", ".INF",
         "+.inf", "-.inf", ".nan", ".NaN", ".NAN": return true
    default: break
    }
    // Numeric-looking.
    var t = s
    var neg = false
    if t.hasPrefix("-") || t.hasPrefix("+") { neg = true; t.removeFirst() }
    _ = neg
    if !t.isEmpty && (t.allSatisfy(\.isNumber) || t.contains(".") || t.lowercased().contains("e")) {
        // Conservative: quote anything that looks numeric.
        return true
    }
    // Leading/trailing space, special leading chars, ': ' or ' #' inside.
    if s.first == " " || s.last == " " { return true }
    if let first = s.first, "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
    if s.contains(": ") || s.contains(" #") || s.contains("\n") { return true }
    return false
}

/// Encode a scalar as a YAML flow value.
func yamlScalar(_ value: Value) -> String {
    switch value {
    case .none: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return "\(i)"
    case .float(let f):
        if f.isNaN { return ".nan" }
        if f == .infinity { return ".inf" }
        if f == -.infinity { return "-.inf" }
        return String(f)
    case .str(let s): return yamlQuote(s.value)
    case .array, .dict:
        return encodeYAMLFlow(value)
    default:
        // All other types serialize via repr (upstream
        // `Value::serialize` fallback).
        return yamlQuote(value.repr())
    }
}

/// Encode a value in YAML flow style (for nested/inline use).
func encodeYAMLFlow(_ value: Value) -> String {
    switch value {
    case .array(let a):
        return "[" + a.items.map(yamlScalar).joined(separator: ", ") + "]"
    case .dict(let d):
        let inner = d.map { "\(yamlQuote($0.key.value)): \(yamlScalar($0.value))" }
            .joined(separator: ", ")
        return "{ \(inner) }"
    default:
        return yamlScalar(value)
    }
}

/// Encode any `Value` as a YAML document (block style).
/// Port of `serde_yaml::to_string` — approximately: dicts/arrays in
/// block style, scalars inline.
func encodeYAML(_ value: Value) -> String {
    var out = ""
    encodeYAMLBlock(value, indent: 0, into: &out, isRoot: true)
    return out
}

/// Encode `value` at `indent` spaces into `out`.
func encodeYAMLBlock(_ value: Value, indent: Int, into out: inout String,
                     isRoot: Bool = false) {
    let pad = String(repeating: " ", count: indent)
    switch value {
    case .dict(let d):
        if d.isEmpty { out += pad + "{}\n"; return }
        for (key, val) in d {
            out += pad + yamlQuote(key.value) + ":"
            switch val {
            case .dict(let sub) where !sub.isEmpty:
                out += "\n"
                encodeYAMLBlock(.dict(sub), indent: indent + 2, into: &out)
            case .array(let a) where !a.items.isEmpty
                    && a.items.contains(where: { isBlockYAML($0) }):
                out += "\n"
                encodeYAMLBlock(.array(a), indent: indent + 2, into: &out)
            case .none:
                out += " null\n"
            default:
                out += " " + yamlScalar(val) + "\n"
            }
        }
    case .array(let a):
        if a.items.isEmpty { out += pad + "[]\n"; return }
        for item in a.items {
            switch item {
            case .dict(let sub) where !sub.isEmpty:
                // `- key: value` compact or `-` + nested.
                out += pad + "-"
                // Emit first pair inline if possible.
                var first = true
                var tmp = ""
                for (k, v) in sub {
                    if first {
                        tmp += " " + yamlQuote(k.value) + ":"
                        if case .dict(let sd) = v, !sd.isEmpty {
                            tmp += "\n"
                            encodeYAMLBlock(.dict(sd), indent: indent + 4, into: &tmp)
                        } else if case .array(let sa) = v, !sa.items.isEmpty,
                                  sa.items.contains(where: { isBlockYAML($0) }) {
                            tmp += "\n"
                            encodeYAMLBlock(.array(sa), indent: indent + 4, into: &tmp)
                        } else {
                            tmp += " " + yamlScalar(v) + "\n"
                        }
                        first = false
                    } else {
                        tmp += String(repeating: " ", count: indent + 2)
                            + yamlQuote(k.value) + ":"
                        if case .dict(let sd) = v, !sd.isEmpty {
                            tmp += "\n"
                            encodeYAMLBlock(.dict(sd), indent: indent + 4, into: &tmp)
                        } else if case .array(let sa) = v, !sa.items.isEmpty,
                                  sa.items.contains(where: { isBlockYAML($0) }) {
                            tmp += "\n"
                            encodeYAMLBlock(.array(sa), indent: indent + 4, into: &tmp)
                        } else {
                            tmp += " " + yamlScalar(v) + "\n"
                        }
                    }
                }
                out += tmp
            case .array(let sub) where !sub.items.isEmpty
                    && sub.items.contains(where: { isBlockYAML($0) }):
                out += pad + "-\n"
                encodeYAMLBlock(.array(sub), indent: indent + 2, into: &out)
            case .none:
                out += pad + "- null\n"
            default:
                out += pad + "- " + yamlScalar(item) + "\n"
            }
        }
    default:
        out += pad + yamlScalar(value) + "\n"
        _ = isRoot
    }
}

/// Whether a value is emitted in block style when nested.
func isBlockYAML(_ value: Value) -> Bool {
    switch value {
    case .dict(let d): return !d.isEmpty
    case .array(let a):
        return a.items.contains { isBlockYAML($0) }
    default: return false
    }
}
