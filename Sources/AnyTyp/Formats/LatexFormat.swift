import Foundation

/// LaTeX (`.tex`, `.latex`) frontend (port of `formats/latex.rs`).
enum LatexFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        return parseStr(text)
    }

    static func parseStr(_ input: String) -> Result<AnyTypDocument, ConvertError> {
        let stripped = LatexLex.stripComments(input)
        var body = stripped[...]
        var preamble = ""
        if let (before, inner, _) = findEnv(stripped, "document") {
            preamble = before
            body = inner[...]
        } else {
            preamble = ""
            body = stripped[...]
        }

        var parser = LatexParser()
        let title = extractCmdArg(preamble, "\\title") ?? extractCmdArg(String(body), "\\title")
        if let t = title {
            let inlines = parser.parseInlines(t, style: .plain)
            if !inlinesAreEmpty(inlines) {
                parser.blocks.append(.heading(level: 1, anchor: nil, content: inlines))
            }
        }
        let blocks: [AnyTypBlock]
        do {
            blocks = try parser.parseBlocks(String(body))
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.malformed(part: "tex", detail: "\(error)"))
        }
        parser.blocks.append(contentsOf: blocks)
        return .success(AnyTypDocument(blocks: parser.blocks, notes: parser.notes))
    }
}

private final class LatexParser {
    var blocks: [AnyTypBlock] = []
    var notes: [AnyTypNote] = []
    var nextNote = 0

    // MARK: - Block parsing

    func parseBlocks(_ src: String) throws -> [AnyTypBlock] {
        var out: [AnyTypBlock] = []
        var para = ""
        var i = src.startIndex

        func flushPara() {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let inlines = parseInlines(trimmed, style: .plain)
                if !inlinesAreEmpty(inlines) {
                    out.append(.paragraph(inlines))
                }
            }
            para = ""
        }

        let bytes = Array(src.utf8)
        while i < src.endIndex {
            let rest = String(src[i...])

            // Blank line -> paragraph boundary.
            if src[i] == "\n" {
                var j = src.index(after: i)
                while j < src.endIndex, [" ", "\t", "\r"].contains(src[j]) {
                    j = src.index(after: j)
                }
                if j < src.endIndex, src[j] == "\n" {
                    flushPara()
                    while j < src.endIndex, src[j].isWhitespace {
                        j = src.index(after: j)
                    }
                    i = j
                    continue
                }
            }

            // Display math `$$...$$`
            if rest.hasPrefix("$$"),
               let end = rest.dropFirst(2).range(of: "$$") {
                flushPara()
                let math = String(rest.dropFirst(2).prefix(upTo: end.lowerBound))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !math.isEmpty { out.append(.math(math)) }
                i = src.index(i, offsetBy: 2 + mathSourceLen(rest, end) + 2, limitedBy: src.endIndex) ?? src.endIndex
                continue
            }

            // Display math `\[...\]`
            if rest.hasPrefix("\\["),
               let end = rest.dropFirst(2).range(of: "\\]") {
                flushPara()
                let inner = rest.dropFirst(2).prefix(upTo: end.lowerBound)
                let math = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                if !math.isEmpty { out.append(.math(math)) }
                i = src.index(i, offsetBy: 2 + inner.count + 2, limitedBy: src.endIndex) ?? src.endIndex
                continue
            }

            // Environments `\begin{...}`
            if rest.hasPrefix("\\begin{"),
               let (envName, afterBegin) = LatexLex.readBraced(String(rest.dropFirst(6))) {
                let headerLen = 6 + (rest.dropFirst(6).count - afterBegin.count)
                let afterHeader = String(rest.dropFirst(headerLen))
                if let (inner, consumed) = LatexLex.extractMatchingEnd(afterHeader, envName) {
                    flushPara()
                    try handleEnv(envName, inner: inner, out: &out)
                    i = src.index(i, offsetBy: headerLen + consumed, limitedBy: src.endIndex) ?? src.endIndex
                    continue
                }
            }

            // Sectioning commands & horizontal rules
            if src[i] == "\\" {
                let (cmd, afterCmd) = LatexLex.readCommand(String(rest.dropFirst()))
                let cmdLen = 1 + (rest.dropFirst().count - afterCmd.count)
                let baseCmd = cmd.hasSuffix("*") ? String(cmd.dropLast()) : cmd
                if let level = sectionLevel(baseCmd) {
                    let afterOpt = LatexLex.skipOptionalBracket(String(afterCmd.drop(while: { $0 == " " || $0 == "\t" })))
                    if let (arg, tail) = LatexLex.readBraced(afterOpt) {
                        flushPara()
                        var anchor: String? = nil
                        var rem = String(tail.drop(while: { $0 == " " || $0 == "\t" }))
                        if rem.hasPrefix("\\label"),
                           let (lbl, afterLbl) = LatexLex.readBraced(String(rem.dropFirst(6).drop(while: { $0 == " " || $0 == "\t" }))) {
                            anchor = lbl.trimmingCharacters(in: .whitespaces)
                            rem = afterLbl
                        }
                        let content = parseInlines(arg, style: .plain)
                        if !inlinesAreEmpty(content) {
                            out.append(.heading(level: level, anchor: anchor, content: content))
                        }
                        i = src.index(src.endIndex, offsetBy: -rem.count)
                        continue
                    }
                } else if ["hrule", "hline", "newpage", "clearpage"].contains(baseCmd) {
                    flushPara()
                    out.append(.rule)
                    i = src.index(i, offsetBy: cmdLen, limitedBy: src.endIndex) ?? src.endIndex
                    continue
                } else if ["maketitle", "tableofcontents", "documentclass", "usepackage", "bibliographystyle"].contains(baseCmd) {
                    let rem = LatexLex.skipCmdArgs(afterCmd)
                    i = src.index(src.endIndex, offsetBy: -rem.count)
                    continue
                } else if ["title", "author", "date"].contains(baseCmd) {
                    let afterOpt = LatexLex.skipOptionalBracket(String(afterCmd.drop(while: { $0 == " " || $0 == "\t" })))
                    if let (_, tail) = LatexLex.readBraced(afterOpt) {
                        i = src.index(src.endIndex, offsetBy: -tail.count)
                        continue
                    }
                }
            }

            let ch = src[i]
            para.append(ch)
            i = src.index(after: i)
        }
        _ = bytes
        flushPara()
        return out
    }

    private func mathSourceLen(_ rest: String, _ end: Range<String.Index>) -> Int {
        // `end` is a range in `rest.dropFirst(2)`; its lowerBound distance from
        // the substring start equals the byte/char offset we need.
        rest.dropFirst(2).distance(from: rest.dropFirst(2).startIndex, to: end.lowerBound)
    }

    // MARK: - Environments

    private func handleEnv(_ env: String, inner: String, out: inout [AnyTypBlock]) throws {
        let base = env.hasSuffix("*") ? String(env.dropLast()) : env
        switch base {
        case "itemize":
            let items = try parseListItems(inner, isDescription: false)
            if !items.isEmpty {
                out.append(.list(.init(marker: .bullet, start: 1, items: items)))
            }
        case "enumerate":
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            let skipped = LatexLex.skipOptionalBracket(trimmed)
            let items = try parseListItems(skipped, isDescription: false)
            if !items.isEmpty {
                out.append(.list(.init(marker: .decimal, start: 1, items: items)))
            }
        case "description":
            let items = try parseListItems(inner, isDescription: true)
            if !items.isEmpty {
                out.append(.list(.init(marker: .bullet, start: 1, items: items)))
            }
        case "quote", "quotation", "abstract":
            let blocks = try parseBlocks(inner)
            if !blocks.isEmpty { out.append(.blockQuote(blocks)) }
        case "verbatim", "lstlisting", "minted":
            var lang: String? = nil
            var code = inner
            if base == "minted" {
                let s = LatexLex.skipOptionalBracket(inner.trimmingCharacters(in: .whitespaces))
                if let (l, rest) = LatexLex.readBraced(s) {
                    lang = l.trimmingCharacters(in: .whitespaces)
                    code = rest
                }
            } else {
                code = LatexLex.skipOptionalBracket(inner.trimmingCharacters(in: .whitespaces))
            }
            let trimmedCode = code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            out.append(.codeBlock(lang: (lang?.isEmpty == false) ? lang : nil, text: trimmedCode))
        case "equation", "displaymath", "math":
            let m = stripLabels(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty { out.append(.math(m)) }
        case "align", "aligned", "gather", "multline", "eqnarray":
            let m = stripLabels(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty {
                out.append(.math("\\begin{\(env)}\n\(m)\n\\end{\(env)}"))
            }
        case "tabular", "tabularx", "longtable":
            var body = LatexLex.skipOptionalBracket(inner.trimmingCharacters(in: .whitespaces))
            if base == "tabularx", let (_, rest) = LatexLex.readBraced(body) {
                body = rest.trimmingCharacters(in: .whitespaces)
            }
            if let (_, rest) = LatexLex.readBraced(body) {
                body = rest
            }
            if let table = try parseTabular(body) {
                out.append(.table(table))
            }
        case "table", "figure", "center", "flushleft", "flushright":
            let body = LatexLex.skipOptionalBracket(inner.trimmingCharacters(in: .whitespaces))
            out.append(contentsOf: try parseBlocks(body))
        default:
            out.append(contentsOf: try parseBlocks(inner))
        }
    }

    // MARK: - Lists

    private func parseListItems(_ inner: String, isDescription: Bool) throws -> [AnyTypListItem] {
        var items: [AnyTypListItem] = []
        var chunks: [String] = []
        var depth = 0
        var cur = ""
        var started = false
        var i = inner.startIndex

        while i < inner.endIndex {
            let rest = String(inner[i...])
            if rest.hasPrefix("\\begin{") {
                depth += 1
            } else if rest.hasPrefix("\\end{") {
                depth = max(0, depth - 1)
            } else if depth == 0 && rest.hasPrefix("\\item") {
                let after = rest.dropFirst(5)
                if after.isEmpty || !(after.first!.isASCII && after.first!.isLetter) {
                    if started { chunks.append(cur); cur = "" }
                    started = true
                    i = inner.index(i, offsetBy: 5)
                    continue
                }
            }
            if started { cur.append(inner[i]) }
            i = inner.index(after: i)
        }
        if started { chunks.append(cur) }

        for chunk in chunks {
            let trimmed = chunk.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
            var labelPrefix: String? = nil
            var body = String(trimmed)
            if trimmed.first == "[", let close = trimmed.firstIndex(of: "]") {
                labelPrefix = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                body = String(trimmed[trimmed.index(after: close)...])
            }

            var blocks = try parseBlocks(body)
            var markerLabel: String? = nil
            if let lbl = labelPrefix {
                if isDescription {
                    var head = parseInlines(lbl.trimmingCharacters(in: .whitespaces),
                                            style: AnyTypStyle(bold: true))
                    head.append(.text(": ", style: .plain))
                    if case .paragraph(var inlines)? = blocks.first {
                        inlines.insert(contentsOf: head, at: 0)
                        blocks[0] = .paragraph(inlines)
                    } else {
                        blocks.insert(.paragraph(head), at: 0)
                    }
                } else {
                    markerLabel = lbl.trimmingCharacters(in: .whitespaces)
                }
            }
            if !blocks.isEmpty {
                items.append(.init(blocks: blocks, markerLabel: markerLabel))
            }
        }
        return items
    }

    // MARK: - Tabular

    private func parseTabular(_ body: String) throws -> AnyTypTable? {
        let builder = GridBuilder()
        var headerRows = 0
        var sawMidRule = false
        var rowCount = 0

        for rawRow in LatexLex.splitRows(body) {
            var row = rawRow.trimmingCharacters(in: .whitespacesAndNewlines)
            while let stripped = LatexLex.stripTableRule(row) {
                if rowCount > 0 && !sawMidRule {
                    headerRows = rowCount
                    sawMidRule = true
                }
                row = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if row.isEmpty { continue }
            builder.nextRow()
            rowCount += 1
            for rawCell in LatexLex.splitCells(row) {
                let c = rawCell.trimmingCharacters(in: .whitespacesAndNewlines)
                if c.hasPrefix("\\multicolumn"),
                   let (spanStr, rest1) = LatexLex.readBraced(String(c.dropFirst(12).drop(while: { $0 == " " || $0 == "\t" }))),
                   let (_, rest2) = LatexLex.readBraced(String(rest1.drop(while: { $0 == " " || $0 == "\t" }))),
                   let (contentStr, _) = LatexLex.readBraced(String(rest2.drop(while: { $0 == " " || $0 == "\t" }))) {
                    let colSpan = max(1, Int(spanStr.trimmingCharacters(in: .whitespaces)) ?? 1)
                    let inlines = parseInlines(contentStr.trimmingCharacters(in: .whitespacesAndNewlines), style: .plain)
                    try builder.place(.spanning([.paragraph(inlines)], colSpan: colSpan, rowSpan: 1))
                } else {
                    let inlines = parseInlines(c, style: .plain)
                    try builder.place(.fromInlines(inlines))
                }
            }
        }

        var table = builder.finish(kind: .data)
        if table.grid.isEmpty { return nil }
        table.headerRows = HeaderDetect.resolve(table, declared: headerRows)
        return table
    }

    // MARK: - Inlines

    func parseInlines(_ src: String, style: AnyTypStyle) -> [AnyTypInline] {
        var out: [AnyTypInline] = []
        var buf = ""
        var i = src.startIndex

        func flush() {
            if !buf.isEmpty {
                let collapsed = collapseInlineWS(buf)
                buf = ""
                if !collapsed.isEmpty {
                    out.append(.text(collapsed, style: style))
                }
            }
        }

        while i < src.endIndex {
            let rest = String(src[i...])

            if rest.hasPrefix("\\\\") {
                flush()
                out.append(.lineBreak)
                i = src.index(i, offsetBy: 2)
                let after = LatexLex.skipOptionalBracket(String(src[i...]))
                i = src.index(src.endIndex, offsetBy: -after.count)
                continue
            }

            if rest.hasPrefix("\\("),
               let end = rest.dropFirst(2).range(of: "\\)") {
                flush()
                let inner = rest.dropFirst(2).prefix(upTo: end.lowerBound)
                let math = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(.math(math))
                i = src.index(i, offsetBy: 2 + inner.count + 2, limitedBy: src.endIndex) ?? src.endIndex
                continue
            }

            if rest.hasPrefix("$"), !rest.hasPrefix("$$"),
               let end = LatexLex.findClosingDollar(String(rest.dropFirst())) {
                flush()
                let inner = rest.dropFirst().prefix(end)
                let math = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(.math(math))
                i = src.index(i, offsetBy: 1 + inner.count + 1, limitedBy: src.endIndex) ?? src.endIndex
                continue
            }

            if rest.hasPrefix("~") {
                buf.append("\u{a0}")
                i = src.index(after: i)
                continue
            }
            if rest.hasPrefix("---") {
                buf.append("—")
                i = src.index(i, offsetBy: 3)
                continue
            }
            if rest.hasPrefix("--") {
                buf.append("–")
                i = src.index(i, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("``") {
                buf.append("“")
                i = src.index(i, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("''") {
                buf.append("”")
                i = src.index(i, offsetBy: 2)
                continue
            }

            if rest.hasPrefix("\\"), rest.count > 1 {
                let next = rest[rest.index(after: rest.startIndex)]
                if ["%", "$", "&", "#", "_", "{", "}"].contains(next) {
                    buf.append(next)
                    i = src.index(i, offsetBy: 2)
                    continue
                }
                let (cmd, afterCmd) = LatexLex.readCommand(String(rest.dropFirst()))
                if !cmd.isEmpty {
                    let trimmed = String(afterCmd.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
                    var handled = false
                    switch cmd {
                    case "textbf", "mathbf":
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: AnyTypStyle(bold: true, italic: style.italic, underline: style.underline, strike: style.strike, superscript: style.superscript, subscriptText: style.subscriptText, code: style.code)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "textit", "emph", "mathit":
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: AnyTypStyle(bold: style.bold, italic: true, underline: style.underline, strike: style.strike, superscript: style.superscript, subscriptText: style.subscriptText, code: style.code)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "underline":
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: AnyTypStyle(bold: style.bold, italic: style.italic, underline: true, strike: style.strike, superscript: style.superscript, subscriptText: style.subscriptText, code: style.code)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "sout", "st":
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: AnyTypStyle(bold: style.bold, italic: style.italic, underline: style.underline, strike: true, superscript: style.superscript, subscriptText: style.subscriptText, code: style.code)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "textsuperscript":
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: AnyTypStyle(bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, superscript: true, subscriptText: false, code: style.code)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "textsubscript":
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: AnyTypStyle(bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, superscript: false, subscriptText: true, code: style.code)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "texttt", "verb":
                        if cmd == "texttt", let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(.text(arg, style: AnyTypStyle(bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, superscript: style.superscript, subscriptText: style.subscriptText, code: true)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        } else if cmd == "verb", let delim = afterCmd.first,
                                  let endIdx = afterCmd.dropFirst().firstIndex(of: delim) {
                            flush()
                            let inner = afterCmd.dropFirst().prefix(upTo: endIdx)
                            out.append(.text(String(inner), style: AnyTypStyle(bold: style.bold, italic: style.italic, underline: style.underline, strike: style.strike, superscript: style.superscript, subscriptText: style.subscriptText, code: true)))
                            i = src.index(src.endIndex, offsetBy: -(afterCmd.count - inner.count - 2))
                            handled = true
                        }
                    case "href":
                        if let (url, rest1) = LatexLex.readBraced(trimmed),
                           let (label, tail) = LatexLex.readBraced(String(rest1.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))) {
                            flush()
                            let target = latexLinkTarget(url.trimmingCharacters(in: .whitespaces))
                            let content = parseInlines(label, style: style)
                            out.append(.link(content: content, target: target))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "url":
                        if let (url, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            let u = url.trimmingCharacters(in: .whitespaces)
                            out.append(.link(content: [.text(u, style: .plain)], target: latexLinkTarget(u)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "label":
                        if let (lid, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(.anchor(lid.trimmingCharacters(in: .whitespaces)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "ref", "autoref", "eqref", "nameref":
                        if let (lid, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            let targetId = lid.trimmingCharacters(in: .whitespaces)
                            out.append(.link(content: [.text(targetId, style: .plain)], target: .anchor(targetId)))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "cite", "citep", "citet":
                        let afterOpt = LatexLex.skipOptionalBracket(trimmed)
                        if let (keys, tail) = LatexLex.readBraced(afterOpt) {
                            buf.append("[")
                            buf.append(keys.trimmingCharacters(in: .whitespaces))
                            buf.append("]")
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "footnote":
                        if let (noteSrc, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            nextNote += 1
                            let id = "fn\(nextNote)"
                            let blocks = (try? parseBlocks(noteSrc)) ?? [.paragraph([.text(noteSrc, style: .plain)])]
                            notes.append(.init(id: id, kind: .footnote, blocks: blocks))
                            out.append(.noteRef(id))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        }
                    case "textbackslash", "LaTeX", "TeX":
                        buf.append(cmd == "textbackslash" ? "\\" : cmd)
                        let rem = trimmed.hasPrefix("{}") ? String(trimmed.dropFirst(2)) : afterCmd
                        i = src.index(src.endIndex, offsetBy: -rem.count)
                        handled = true
                    default:
                        if let (arg, tail) = LatexLex.readBraced(trimmed) {
                            flush()
                            out.append(contentsOf: parseInlines(arg, style: style))
                            i = src.index(src.endIndex, offsetBy: -tail.count)
                            handled = true
                        } else {
                            let rem = String(afterCmd.drop(while: { $0 == " " }))
                            i = src.index(src.endIndex, offsetBy: -rem.count)
                            handled = true
                        }
                    }
                    if handled { continue }
                }
            }

            if rest.hasPrefix("{"),
               let (inner, tail) = LatexLex.readBraced(rest) {
                flush()
                out.append(contentsOf: parseInlines(inner, style: style))
                i = src.index(src.endIndex, offsetBy: -tail.count)
                continue
            }

            let ch = src[i]
            buf.append(ch)
            i = src.index(after: i)
        }

        flush()
        return out
    }
}

// MARK: - Lexical helpers

private enum LatexLex {
    static func stripComments(_ src: String) -> String {
        var out = String()
        out.reserveCapacity(src.count)
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            var backslashes = 0
            var cut = line.endIndex
            for idx in line.indices {
                let ch = line[idx]
                if ch == "%", backslashes % 2 == 0 {
                    cut = idx
                    break
                }
                backslashes = ch == "\\" ? backslashes + 1 : 0
            }
            out.append(contentsOf: line[..<cut])
            out.append("\n")
        }
        return out
    }

    static func findEnv(_ src: String, _ name: String) -> (String, String, String)? {
        let open = "\\begin{\(name)}"
        guard let start = src.range(of: open) else { return nil }
        let bodyStart = start.upperBound
        guard let (inner, consumed) = extractMatchingEnd(String(src[bodyStart...]), name) else { return nil }
        let before = String(src[..<start.lowerBound])
        let after = String(src[bodyStart...].dropFirst(consumed))
        return (before, inner, after)
    }

    static func extractMatchingEnd(_ src: String, _ name: String) -> (String, Int)? {
        let open = "\\begin{\(name)}"
        let close = "\\end{\(name)}"
        var depth = 1
        var pos = src.startIndex
        while pos < src.endIndex {
            let rest = String(src[pos...])
            guard let nextCloseRange = rest.range(of: close) else { return nil }
            let nextClose = rest.distance(from: rest.startIndex, to: nextCloseRange.lowerBound)
            var nextOpen: Int? = nil
            if let r = rest.range(of: open) {
                let d = rest.distance(from: rest.startIndex, to: r.lowerBound)
                if d < nextClose { nextOpen = d }
            }
            if let o = nextOpen {
                depth += 1
                pos = src.index(pos, offsetBy: o + open.count, limitedBy: src.endIndex) ?? src.endIndex
            } else {
                depth -= 1
                if depth == 0 {
                    let innerEnd = src.index(pos, offsetBy: nextClose)
                    let inner = String(src[..<innerEnd])
                    let consumed = nextClose + close.count
                    return (inner, consumed)
                }
                pos = src.index(pos, offsetBy: nextClose + close.count, limitedBy: src.endIndex) ?? src.endIndex
            }
        }
        return nil
    }

    /// `\command` letters (+ optional trailing `*`); returns (name, rest).
    static func readCommand(_ s: String) -> (String, String) {
        var len = 0
        for ch in s {
            if ch.isASCII && ch.isLetter || (len > 0 && ch == "*") {
                len += 1
                if ch == "*" { break }
            } else {
                break
            }
        }
        let idx = s.index(s.startIndex, offsetBy: len)
        return (String(s[..<idx]), String(s[idx...]))
    }

    /// `{...}` with brace-depth and backslash-escape awareness.
    static func readBraced(_ s: String) -> (String, String)? {
        guard s.first == "{" else { return nil }
        var depth = 1
        var escaped = false
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let ch = s[idx]
            if escaped {
                escaped = false
            } else {
                switch ch {
                case "\\": escaped = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let inner = String(s[s.index(after: s.startIndex)..<idx])
                        let tail = String(s[s.index(after: idx)...])
                        return (inner, tail)
                    }
                default: break
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    /// `[...]` with bracket-depth awareness (no escapes).
    static func skipOptionalBracket(_ s: String) -> String {
        guard s.first == "[" else { return s }
        var depth = 1
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return String(s[s.index(after: idx)...])
                }
            }
            idx = s.index(after: idx)
        }
        return s
    }

    /// Skip repeated `[...]` and `{...}` argument groups.
    static func skipCmdArgs(_ s: String) -> String {
        var cur = s
        while true {
            let trimmed = String(cur.drop(while: { $0 == " " || $0 == "\t" }))
            if trimmed.first == "[" {
                let next = skipOptionalBracket(trimmed)
                if next.count < trimmed.count {
                    cur = next
                    continue
                }
            }
            if let (_, next) = readBraced(trimmed) {
                cur = next
                continue
            }
            return cur
        }
    }

    static func extractCmdArg(_ src: String, _ cmd: String) -> String? {
        guard let range = src.range(of: cmd) else { return nil }
        let after = src[range.upperBound...]
        if let first = after.first, first.isASCII && first.isLetter { return nil }
        let skipped = skipOptionalBracket(String(after.drop(while: { $0 == " " || $0 == "\t" })))
        return readBraced(skipped)?.0
    }

    static func findClosingDollar(_ s: String) -> Int? {
        var escaped = false
        var idx = 0
        for ch in s {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "$" {
                return idx
            }
            idx += 1
        }
        return nil
    }

    /// Split a tabular body on `\\` row separators at brace depth 0.
    static func splitRows(_ body: String) -> [String] {
        var rows: [String] = []
        var depth = 0
        var start = body.startIndex
        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth = max(0, depth - 1) }
            if ch == "\\", depth == 0 {
                let next = body.index(after: i)
                if next < body.endIndex, body[next] == "\\" {
                    rows.append(String(body[start..<i]))
                    i = body.index(after: next)
                    let after = skipOptionalBracket(String(body[i...]))
                    i = body.index(body.endIndex, offsetBy: -after.count)
                    start = i
                    continue
                }
            }
            i = body.index(after: i)
        }
        rows.append(String(body[start...]))
        return rows
    }

    /// Split a tabular row on `&` cell separators at brace depth 0.
    static func splitCells(_ row: String) -> [String] {
        var cells: [String] = []
        var depth = 0
        var escaped = false
        var start = row.startIndex
        var i = row.startIndex
        while i < row.endIndex {
            let ch = row[i]
            if escaped {
                escaped = false
            } else {
                switch ch {
                case "\\": escaped = true
                case "{": depth += 1
                case "}": depth = max(0, depth - 1)
                case "&" where depth == 0:
                    cells.append(String(row[start..<i]))
                    start = row.index(after: i)
                default: break
                }
            }
            i = row.index(after: i)
        }
        cells.append(String(row[start...]))
        return cells
    }

    /// Strip a leading `\toprule`/`\midrule`/`\bottomrule`/`\hline` or a
    /// `\cline`/`\cmidrule` spec, returning the remainder.
    static func stripTableRule(_ row: String) -> String? {
        for rule in ["\\toprule", "\\midrule", "\\bottomrule", "\\hline"] {
            if row.hasPrefix(rule) { return String(row.dropFirst(rule.count)) }
        }
        for rule in ["\\cline", "\\cmidrule"] {
            if row.hasPrefix(rule) {
                var rest = skipOptionalBracket(String(row.dropFirst(rule.count).drop(while: { $0 == " " || $0 == "\t" })))
                if rest.first == "(" {
                    if let close = rest.firstIndex(of: ")") {
                        rest = String(rest[rest.index(after: close)...])
                    }
                }
                if let (_, tail) = readBraced(String(rest.drop(while: { $0 == " " || $0 == "\t" }))) {
                    return tail
                }
            }
        }
        return nil
    }
}

private func stripLabels(_ s: String) -> String {
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        let rest = String(s[i...])
        if rest.hasPrefix("\\label"),
           let (_, tail) = LatexLex.readBraced(String(rest.dropFirst(6).drop(while: { $0 == " " || $0 == "\t" }))) {
            i = s.index(s.endIndex, offsetBy: -tail.count)
            continue
        }
        out.append(s[i])
        i = s.index(after: i)
    }
    return out
}

private func sectionLevel(_ cmd: String) -> Int? {
    switch cmd {
    case "part", "chapter", "section": return 1
    case "subsection": return 2
    case "subsubsection": return 3
    case "paragraph": return 4
    case "subparagraph": return 5
    default: return nil
    }
}

private func extractCmdArg(_ src: String, _ cmd: String) -> String? {
    LatexLex.extractCmdArg(src, cmd)
}

private func findEnv(_ src: String, _ name: String) -> (String, String, String)? {
    LatexLex.findEnv(src, name)
}

private func latexLinkTarget(_ url: String) -> AnyTypLinkTarget {
    if let frag = url.first == "#" ? String(url.dropFirst()) : nil {
        return .anchor(frag)
    }
    if isAbsoluteURI(url) { return .external(url) }
    return .relative(url)
}

private func collapseInlineWS(_ s: String) -> String {
    var out = ""
    var prevWS = false
    for ch in s {
        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
            if !prevWS { out.append(" "); prevWS = true }
        } else {
            out.append(ch)
            prevWS = false
        }
    }
    return out
}
