import Foundation

/// CommonMark + GFM-flavored Markdown frontend (port of `formats/markdown.rs`).
/// Hand-rolled parser covering the pulldown-cmark feature subset AnyTyp uses:
/// headings (with `{#id}` attributes), paragraphs, emphasis/strong/strike/
/// sup/sub, code spans and fenced/indented code, links/images, lists
/// (bullet/ordered/task), blockquotes, rules, GFM tables, footnotes, math,
/// inline HTML passthrough for `br`/`u`/`ins`/`sup`/`sub`/`a#id`, and
/// YAML/`+++` metadata blocks (skipped).
enum MarkdownFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        return .success(parseStr(text))
    }

    static func parseStr(_ input: String) -> AnyTypDocument {
        var p = MdParser(input)
        return p.parse()
    }
}

private struct MdParser {
    var lines: [String]
    var pos = 0
    var blocks: [AnyTypBlock] = []
    var notes: [AnyTypNote] = []
    var noteSeq = 0

    init(_ input: String) {
        // Normalize newlines; strip a leading BOM.
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    mutating func parse() -> AnyTypDocument {
        skipMetadata()
        while pos < lines.count {
            parseBlock()
        }
        return AnyTypDocument(blocks: blocks, notes: notes)
    }

    // MARK: - Block level

    private mutating func skipMetadata() {
        guard pos < lines.count else { return }
        let first = lines[pos].trimmingCharacters(in: .whitespaces)
        if first == "---" || first == "+++" {
            // Could be YAML metadata, thematic break, or setext heading.
            // Metadata only counts at document start followed by content
            // and a matching close.
            var j = pos + 1
            var found = false
            while j < lines.count {
                if lines[j].trimmingCharacters(in: .whitespaces) == first {
                    found = true
                    break
                }
                if lines[j].trimmingCharacters(in: .whitespaces).isEmpty { break }
                j += 1
            }
            if found, j > pos + 1 {
                pos = j + 1
            }
        }
    }

    private mutating func parseBlock() {
        let line = lines[pos]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            pos += 1
            return
        }

        // Fenced code block.
        if let (lang, rest) = fencedCodeStart(line) {
            parseFencedCode(lang: lang, firstLine: rest)
            return
        }

        // Block quote.
        if trimmed.hasPrefix(">") {
            parseBlockQuote()
            return
        }

        // List item.
        if let item = listItemStart(line) {
            parseList(first: item)
            return
        }

        // Heading (ATX).
        if let (level, text, anchor) = atxHeading(line) {
            blocks.append(.heading(level: level, anchor: anchor,
                                   content: parseInlines(text)))
            pos += 1
            return
        }

        // Thematic break.
        if isThematicBreak(trimmed) {
            blocks.append(.rule)
            pos += 1
            return
        }

        // Table (GFM): header row + delimiter row.
        if pos + 1 < lines.count, isTableDelimiter(lines[pos + 1]),
           line.contains("|") {
            parseTable()
            return
        }

        // Display math `$$...$$`.
        if trimmed.hasPrefix("$$") {
            parseDisplayMath()
            return
        }

        // Paragraph / setext heading.
        parseParagraph()
    }

    private mutating func parseFencedCode(lang: String?, firstLine: String) {
        var text = firstLine
        pos += 1
        while pos < lines.count {
            let l = lines[pos]
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || l.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                pos += 1
                break
            }
            text += "\n" + l
            pos += 1
        }
        blocks.append(.codeBlock(lang: lang, text: text))
    }

    private mutating func parseBlockQuote() {
        var inner: [String] = []
        while pos < lines.count {
            let l = lines[pos]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") {
                var content = String(t.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                inner.append(content)
                pos += 1
            } else if t.isEmpty {
                inner.append("")
                pos += 1
            } else {
                break
            }
        }
        var sub = MdParser(inner.joined(separator: "\n"))
        let doc = sub.parse()
        blocks.append(.blockQuote(doc.blocks))
        notes.append(contentsOf: doc.notes)
    }

    private struct ListItemStart {
        var ordered: Bool
        var marker: AnyTypMarkerKind
        var number: UInt64
        var indent: Int
        var text: String
        var task: Bool?
    }

    private mutating func parseList(first: ListItemStart) {
        var items: [AnyTypListItem] = []
        var marker = first.marker
        let start = first.number
        while pos < lines.count {
            guard let item = listItemStart(lines[pos]) else { break }
            if item.ordered != first.ordered || item.indent != first.indent { break }
            marker = item.marker
            // Collect continuation lines (indented or blank-then-indented).
            var itemLines = [item.text]
            pos += 1
            while pos < lines.count {
                let l = lines[pos]
                if l.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Blank line: include only if followed by indented content.
                    if pos + 1 < lines.count,
                       lines[pos + 1].prefix(while: { $0 == " " }).count >= item.indent + 2 {
                        itemLines.append("")
                        pos += 1
                        continue
                    }
                    break
                }
                let indent = l.prefix(while: { $0 == " " }).count
                if indent >= item.indent + 2 {
                    itemLines.append(String(l.dropFirst(min(indent, item.indent + 2))))
                    pos += 1
                    continue
                }
                break
            }
            var sub = MdParser(itemLines.joined(separator: "\n"))
            let doc = sub.parse()
            notes.append(contentsOf: doc.notes)
            var itemBlocks = doc.blocks
            if let task = item.task {
                // Task marker becomes a checkbox inline at the start.
                if case .paragraph(var inlines)? = itemBlocks.first {
                    inlines.insert(.checkbox(task), at: 0)
                    itemBlocks[0] = .paragraph(inlines)
                } else {
                    itemBlocks.insert(.paragraph([.checkbox(task)]), at: 0)
                }
            }
            items.append(.init(blocks: itemBlocks))
        }
        blocks.append(.list(.init(marker: marker, start: start, items: items)))
    }

    private mutating func parseTable() {
        let headerLine = lines[pos]
        let delimiter = lines[pos + 1]
        let aligns = tableAligns(delimiter)
        let headers = splitTableRow(headerLine)
        pos += 2
        var rows: [[AnyTypCell]] = []
        rows.append(headers.map { .fromInlines(parseInlines($0)) })
        while pos < lines.count {
            let l = lines[pos]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if !l.contains("|") { break }
            let cells = splitTableRow(l)
            rows.append(cells.map { .fromInlines(parseInlines($0)) })
            pos += 1
        }
        _ = aligns
        var table = AnyTypTable.fromRows(rows, headerRows: 1, kind: .data)
        table.headerRows = 1
        blocks.append(.table(table))
    }

    private mutating func parseDisplayMath() {
        var text = ""
        let first = lines[pos].trimmingCharacters(in: .whitespaces)
        if first.count > 2 {
            text = String(first.dropFirst(2))
        }
        pos += 1
        var closed = false
        while pos < lines.count {
            let t = lines[pos].trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("$$") {
                text += "\n" + String(t.dropLast(2))
                closed = true
                pos += 1
                break
            }
            text += "\n" + lines[pos]
            pos += 1
        }
        _ = closed
        let math = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !math.isEmpty {
            blocks.append(.math(math))
        }
    }

    private mutating func parseParagraph() {
        var buf: [String] = []
        while pos < lines.count {
            let l = lines[pos]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            // Setext heading underline (wins over thematic break inside a paragraph).
            if !buf.isEmpty, isSetextUnderline(t) {
                let text = buf.joined(separator: "\n")
                let level: Int = t.hasPrefix("=") ? 1 : 2
                let inlines = parseInlines(text)
                if !inlinesAreEmpty(inlines) {
                    blocks.append(.heading(level: level, anchor: nil, content: inlines))
                } else {
                    blocks.append(.paragraph(inlines))
                }
                buf = []
                pos += 1
                return
            }
            // Stop at any block starter.
            if fencedCodeStart(l) != nil || t.hasPrefix(">")
                || listItemStart(l) != nil || isThematicBreak(t)
                || atxHeading(l) != nil {
                break
            }
            buf.append(l)
            pos += 1
        }
        if !buf.isEmpty {
            // Soft breaks become spaces (matching pulldown-cmark SoftBreak -> " ").
            let text = buf.joined(separator: " ")
            let inlines = parseInlines(text)
            if !inlinesAreEmpty(inlines) {
                blocks.append(.paragraph(inlines))
            }
        }
    }

    // MARK: - Line classifiers

    private func fencedCodeStart(_ line: String) -> (lang: String?, rest: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for fence in ["```", "~~~"] {
            if t.hasPrefix(fence) {
                var info = String(t.dropFirst(fence.count))
                info = info.trimmingCharacters(in: .whitespaces)
                let lang = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                return (lang?.isEmpty == false ? lang : nil, "")
            }
        }
        return nil
    }

    private func atxHeading(_ line: String) -> (level: Int, text: String, anchor: String?)? {
        var t = line
        var level = 0
        while t.hasPrefix("#") {
            level += 1
            t.removeFirst()
            if level > 6 { return nil }
        }
        guard level > 0, t.hasPrefix(" ") || t.isEmpty else { return nil }
        t = t.trimmingCharacters(in: .whitespaces)
        // Strip trailing closing #'s (must be preceded by whitespace).
        var runStart = t.endIndex
        while runStart > t.startIndex {
            let p = t.index(before: runStart)
            if t[p] == "#" { runStart = p } else { break }
        }
        if runStart < t.endIndex,
           runStart == t.startIndex || t[t.index(before: runStart)] == " " {
            t = String(t[..<runStart]).trimmingCharacters(in: .whitespaces)
        }
        // Heading attribute {#id}.
        var anchor: String? = nil
        if t.hasSuffix("}"), let open = t.lastIndex(of: "{") {
            let attr = String(t[t.index(after: open)...].dropLast())
            if attr.hasPrefix("#"), attr.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                anchor = String(attr.dropFirst())
                t = String(t[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (level, t, anchor)
    }

    private func isThematicBreak(_ t: String) -> Bool {
        // *, -, _ runs of 3+ with optional spaces.
        for marker in ["*", "-", "_"] as [Character] {
            let stripped = t.filter { !$0.isWhitespace }
            if stripped.count >= 3, stripped.allSatisfy({ $0 == marker }) {
                return true
            }
        }
        return false
    }

    private func isSetextUnderline(_ t: String) -> Bool {
        !t.isEmpty && (t.allSatisfy { $0 == "=" } || t.allSatisfy { $0 == "-" })
    }

    private func listItemStart(_ line: String) -> ListItemStart? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent < 4 else { return nil }
        var t = String(line.dropFirst(indent))
        // Bullet.
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            t.removeFirst(2)
        } else if t == "-" || t == "*" || t == "+" {
            t = ""
        } else {
            // Ordered: `1.` or `1)`.
            var numStr = ""
            var idx = t.startIndex
            while idx < t.endIndex, t[idx].isNumber {
                numStr.append(t[idx])
                idx = t.index(after: idx)
            }
            guard !numStr.isEmpty, idx < t.endIndex,
                  t[idx] == "." || t[idx] == ")" else { return nil }
            let after = t.index(after: idx)
            guard after == t.endIndex || t[after] == " " else { return nil }
            t = after == t.endIndex ? "" : String(t[t.index(after: after)...])
            let markerKind: AnyTypMarkerKind = numStr == "1" ? .decimal : .decimal
            _ = markerKind
            var taskCheck: Bool? = nil
            if t.hasPrefix("[ ] ") || t.hasPrefix("[x] ") || t.hasPrefix("[X] ") {
                taskCheck = t.hasPrefix("[ ] ") ? false : true
                t = String(t.dropFirst(4))
            }
            return .init(ordered: true, marker: .decimal,
                         number: UInt64(numStr) ?? 1, indent: indent,
                         text: t, task: taskCheck)
        }
        var taskCheck: Bool? = nil
        if t.hasPrefix("[ ] ") || t.hasPrefix("[x] ") || t.hasPrefix("[X] ") {
            taskCheck = t.hasPrefix("[ ] ") ? false : true
            t = String(t.dropFirst(4))
        }
        return .init(ordered: false, marker: .bullet, number: 1,
                     indent: indent, text: t, task: taskCheck)
    }

    private func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        // Each cell: optional :, -{3,}, optional :
        for cell in splitTableRow(t) {
            let c = cell.trimmingCharacters(in: .whitespaces)
            var s = c
            if s.hasPrefix(":") { s.removeFirst() }
            if s.hasSuffix(":") { s.removeLast() }
            guard !s.isEmpty, s.allSatisfy({ $0 == "-" }), s.count >= 3 else { return false }
        }
        return true
    }

    private func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        // Split on unescaped pipes.
        var cells: [String] = []
        var cur = ""
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c == "\\", t.index(after: i) < t.endIndex {
                cur.append(c)
                cur.append(t[t.index(after: i)])
                i = t.index(i, offsetBy: 2)
                continue
            }
            if c == "|" {
                cells.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
            i = t.index(after: i)
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func tableAligns(_ line: String) -> [Any?] {
        splitTableRow(line).map { cell -> Any? in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return nil
        }
    }

    // MARK: - Inline parsing

    /// Parse inline markup: `**bold**`, `*italic*`/`_italic_`, `~~strike~~`,
    /// `^sup^`, `~sub~`, `` `code` ``, `[text](url)`, `![alt](src)`,
    /// `$$..$$`/`$..$` math, `<u>/<ins>/<sup>/<sub>/<br>` passthrough,
    /// `[^footnote]`, escapes, entities.
    func parseInlines(_ src: String) -> [AnyTypInline] {
        var out: [AnyTypInline] = []
        var buf = ""
        var i = src.startIndex
        var style = AnyTypStyle.plain

        func flush() {
            if !buf.isEmpty {
                var s = SharedText.clean(buf)
                buf = ""
                if !s.isEmpty {
                    // Collapse whitespace runs.
                    s = SharedText.collapseWS(s)
                    if !s.isEmpty {
                        out.append(.text(s, style: style))
                    }
                }
            }
        }

        while i < src.endIndex {
            let rest = src[i...]
            let ch = rest.first!

            // Escape.
            if ch == "\\", rest.count > 1 {
                let next = rest[rest.index(after: i)]
                if "\\`*_{}[]()#+-.!|~^$".contains(next) {
                    buf.append(next)
                    i = src.index(i, offsetBy: 2)
                    continue
                }
            }

            // Code span.
            if ch == "`" {
                var ticks = 0
                var j = i
                while j < src.endIndex, src[j] == "`" {
                    ticks += 1
                    j = src.index(after: j)
                }
                let marker = String(repeating: "`", count: ticks)
                if let closeRange = src[j...].range(of: marker) {
                    flush()
                    var code = String(src[j..<closeRange.lowerBound])
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 1 {
                        code = String(code.dropFirst().dropLast())
                    }
                    out.append(.text(code, style: AnyTypStyle(code: true)))
                    i = src.index(closeRange.upperBound, offsetBy: 0)
                    continue
                }
                buf.append(contentsOf: marker)
                i = j
                continue
            }

            // Images/links.
            if ch == "!", rest.count > 1, rest[rest.index(after: i)] == "[" {
                if let (alt, url, after) = parseLinkTail(src, at: src.index(after: i)) {
                    flush()
                    let source: AnyTypImageSource = isAbsoluteURI(url) ? .external(url) : .unavailable
                    let altInlines = parseInlines(alt)
                    let altText = altInlines.map { inline -> String in
                        if case .text(let t, _) = inline { return t }
                        return ""
                    }.joined()
                    _ = altText
                    out.append(.image(alt: alt, source: source))
                    i = after
                    continue
                }
            }
            if ch == "[" {
                if let (label, url, after) = parseLinkTail(src, at: i) {
                    flush()
                    let target: AnyTypLinkTarget
                    let u = url.trimmingCharacters(in: .whitespaces)
                    if u.hasPrefix("#") {
                        target = .anchor(String(u.dropFirst()))
                    } else if isAbsoluteURI(u) {
                        target = .external(u)
                    } else {
                        target = .relative(u)
                    }
                    out.append(.link(content: parseInlines(label), target: target))
                    i = after
                    continue
                }
                // Footnote reference [^id].
                if rest.hasPrefix("[^") {
                    if let close = rest.dropFirst(2).firstIndex(of: "]") {
                        let id = String(rest.dropFirst(2).prefix(upTo: close))
                        if !id.isEmpty {
                            flush()
                            out.append(.noteRef(id))
                            i = src.index(i, offsetBy: 3 + id.count)
                            continue
                        }
                    }
                }
            }

            // Emphasis: **, *, __, _, ~~, ~, ^.
            if let (kind, len) = emphasisMarker(rest) {
                if let closeIdx = findClosingMarker(src, from: src.index(i, offsetBy: len), marker: String(repeating: kind, count: len)) {
                    flush()
                    let inner = String(src[src.index(i, offsetBy: len)..<closeIdx])
                    let innerInlines = parseInlines(inner)
                    switch kind {
                    case "*":
                        out.append(contentsOf: innerInlines.map { applyStyle($0, bold: true) })
                    case "_":
                        out.append(contentsOf: innerInlines.map { applyStyle($0, italic: true) })
                    case "~":
                        out.append(contentsOf: innerInlines.map { applyStyle($0, strike: true) })
                    case "^":
                        out.append(contentsOf: innerInlines.map { applyStyle($0, superscript: true) })
                    default: break
                    }
                    i = src.index(closeIdx, offsetBy: len)
                    continue
                }
            }

            // Math: $$...$$ or $...$.
            if ch == "$" {
                if rest.hasPrefix("$$") {
                    if let close = rest.dropFirst(2).range(of: "$$") {
                        flush()
                        let inner = String(rest.dropFirst(2).prefix(upTo: close.lowerBound))
                        out.append(.math(inner.trimmingCharacters(in: .whitespaces)))
                        i = src.index(i, offsetBy: 2 + inner.count + 2)
                        continue
                    }
                } else if let closeIdx = findClosingDollar(src, from: src.index(after: i)) {
                    flush()
                    let inner = String(src[src.index(after: i)..<closeIdx])
                    out.append(.math(inner.trimmingCharacters(in: .whitespaces)))
                    i = src.index(closeIdx, offsetBy: 1)
                    continue
                }
            }

            // Inline HTML tags.
            if ch == "<" {
                if let end = rest.firstIndex(of: ">"), end < rest.index(rest.startIndex, offsetBy: 20) {
                    let tag = String(rest[...end]).lowercased()
                    switch tag {
                    case "<br>", "<br/>", "<br />":
                        flush()
                        out.append(.lineBreak)
                        i = src.index(after: end)
                        continue
                    case "<u>", "<ins>":
                        style.underline = true
                        i = src.index(after: end)
                        continue
                    case "</u>", "</ins>":
                        style.underline = false
                        i = src.index(after: end)
                        continue
                    case "<sup>":
                        style.superscript = true
                        style.subscriptText = false
                        i = src.index(after: end)
                        continue
                    case "</sup>":
                        style.superscript = false
                        i = src.index(after: end)
                        continue
                    case "<sub>":
                        style.subscriptText = true
                        style.superscript = false
                        i = src.index(after: end)
                        continue
                    case "</sub>":
                        style.subscriptText = false
                        i = src.index(after: end)
                        continue
                    default:
                        if tag.hasPrefix("<a ") {
                            if let id = extractAttr(tag, "id") ?? extractAttr(tag, "name") {
                                flush()
                                out.append(.anchor(id))
                                i = src.index(after: end)
                                continue
                            }
                        }
                    }
                }
            }

            // Entities.
            if ch == "&" {
                if let semi = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semi) <= 32 {
                    let name = String(rest[rest.index(after: rest.startIndex)..<semi])
                    if let decoded = resolveHtmlEntity(name) {
                        buf.append(decoded)
                        i = src.index(after: semi)
                        continue
                    }
                }
            }

            buf.append(ch)
            i = src.index(after: i)
        }
        flush()
        return out
    }

    private func emphasisMarker(_ rest: Substring) -> (Character, Int)? {
        guard let first = rest.first else { return nil }
        switch first {
        case "*":
            if rest.count > 1, rest[rest.index(after: rest.startIndex)] == "*" { return ("*", 2) }
            return ("*", 1)
        case "_":
            if rest.count > 1, rest[rest.index(after: rest.startIndex)] == "_" { return ("_", 2) }
            return ("_", 1)
        case "~":
            if rest.count > 1, rest[rest.index(after: rest.startIndex)] == "~" { return ("~", 2) }
            return ("~", 1)
        case "^":
            return ("^", 1)
        default:
            return nil
        }
    }

    private func findClosingMarker(_ src: String, from start: String.Index, marker: String) -> String.Index? {
        // Find marker not preceded by escape.
        var i = start
        while i < src.endIndex {
            if src[i...].hasPrefix(marker) {
                // Check preceding char isn't a backslash escape.
                if i > src.startIndex {
                    var j = src.index(before: i)
                    var backslashes = 0
                    while j >= src.startIndex, src[j] == "\\" {
                        backslashes += 1
                        if j == src.startIndex { break }
                        j = src.index(before: j)
                    }
                    if backslashes % 2 == 1 {
                        i = src.index(i, offsetBy: marker.count)
                        continue
                    }
                }
                return i
            }
            i = src.index(after: i)
        }
        return nil
    }

    private func findClosingDollar(_ src: String, from start: String.Index) -> String.Index? {
        var i = start
        var prev: Character? = nil
        while i < src.endIndex {
            if src[i] == "$", prev != "\\" {
                return i
            }
            prev = src[i]
            i = src.index(after: i)
        }
        return nil
    }

    /// `[label](url)` starting at `[` index; returns (label, url, afterIndex).
    private func parseLinkTail(_ src: String, at openIdx: String.Index) -> (String, String, String.Index)? {
        // openIdx points at '['
        guard let closeBracket = src[openIdx...].firstIndex(of: "]") else { return nil }
        let label = String(src[src.index(after: openIdx)..<closeBracket])
        var j = src.index(after: closeBracket)
        guard j < src.endIndex, src[j] == "(" else { return nil }
        j = src.index(after: j)
        var url = ""
        var depth = 1
        var escaped = false
        while j < src.endIndex {
            let c = src[j]
            if escaped {
                url.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
                url.append(c)
            } else if c == "(" {
                depth += 1
                url.append(c)
            } else if c == ")" {
                depth -= 1
                if depth == 0 {
                    let target = url.trimmingCharacters(in: .whitespaces)
                    // Strip optional title in quotes.
                    let clean = target.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? target
                    return (label, clean, src.index(after: j))
                }
                url.append(c)
            } else {
                url.append(c)
            }
            j = src.index(after: j)
        }
        return nil
    }

    private func applyStyle(_ inline: AnyTypInline, bold: Bool = false, italic: Bool = false,
                            strike: Bool = false, superscript: Bool = false) -> AnyTypInline {
        switch inline {
        case .text(let t, let s):
            return .text(t, style: AnyTypStyle(
                bold: s.bold || bold, italic: s.italic || italic,
                underline: s.underline, strike: s.strike || strike,
                superscript: s.superscript || superscript,
                subscriptText: s.subscriptText, code: s.code))
        case .link(let content, let target):
            return .link(content: content.map { applyStyle($0, bold: bold, italic: italic, strike: strike, superscript: superscript) },
                         target: target)
        default:
            return inline
        }
    }
}

private func extractAttr(_ tag: String, _ attr: String) -> String? {
    let lower = tag.lowercased()
    let needle = "\(attr)="
    guard let range = lower.range(of: needle) else { return nil }
    var rest = tag[range.upperBound...]
    rest = rest.drop(while: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" })
    guard let first = rest.first else { return nil }
    if first == "\"" || first == "'" {
        rest = rest.dropFirst()
        if let end = rest.firstIndex(of: first) {
            return String(rest[..<end])
        }
        return nil
    }
    let end = rest.firstIndex(where: { $0.isWhitespace || $0 == ">" }) ?? rest.endIndex
    return String(rest[..<end])
}
