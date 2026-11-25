import Foundation

/// Options controlling how a document renders to Typst source.
struct RenderOptions {
    /// Emit a standalone Typst document preamble (`#set page(...)`, `#set par(...)`).
    var standalone = false
    /// Optional document title placed in `#set document(title: "...")`.
    var title: String? = nil
    /// Logical directory prefix for extracted assets (for example `"assets"`).
    /// When set, embedded images render as `#image("<dir>/asset-001.png")`.
    var assetsDir: String? = nil
}

/// Mutable render state shared across one document pass.
final class RenderContext {
    let anchors: AnchorMap
    /// Asset id -> relative path used in `#image(...)`.
    let assetPaths: [Int: String]
    /// Note id -> note (blank notes excluded).
    let notes: [String: AnyTypNote]
    /// Note id -> number of references.
    let noteRefCounts: [String: Int]
    /// Note id -> label emitted for multi-reference notes (empty = single ref).
    private(set) var emittedNotes: [String: String] = [:]
    /// Note ids currently being expanded (recursion guard).
    private var activeNotes = Set<String>()
    /// DFS heading counter for `AnchorMap.headingLabel`.
    var headingCounter = 0

    init(anchors: AnchorMap, assetPaths: [Int: String],
         notes: [String: AnyTypNote], noteRefCounts: [String: Int]) {
        self.anchors = anchors
        self.assetPaths = assetPaths
        self.notes = notes
        self.noteRefCounts = noteRefCounts
    }

    /// Emit the footnote for a note reference, or a back-reference when the
    /// note was already emitted under a label (multi-reference notes).
    func renderNoteRef(_ id: String, out: inout String) {
        if activeNotes.contains(id) { return }
        if let existingLabel = emittedNotes[id] {
            if existingLabel.isEmpty { return }
            out += "#footnote(<\(existingLabel)>)"
            return
        }
        guard let note = notes[id] else { return }
        activeNotes.insert(id)
        let body = renderBlocks(note.blocks, rc: self)
        activeNotes.remove(id)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        let multiref = (noteRefCounts[id] ?? 0) > 1
        if trimmed.contains("\n") {
            out += "#footnote[\n"
            for line in trimmed.typstLines() {
                if line.isEmpty {
                    out += "\n"
                } else {
                    out += "  " + line + "\n"
                }
            }
            out += "]"
        } else {
            out += "#footnote[\(trimmed)]"
        }
        if multiref {
            let label = "fn-\(sanitizeLabel(id))"
            out += " <\(label)>"
            emittedNotes[id] = label
        } else {
            emittedNotes[id] = ""
        }
    }
}

/// Serialize a document into clean, composable Typst markup.
func documentToTypst(_ doc: AnyTypDocument) -> String {
    documentToTypstWithOptions(doc, RenderOptions())
}

/// Serialize a document into Typst markup with explicit options.
func documentToTypstWithOptions(_ doc: AnyTypDocument, _ options: RenderOptions) -> String {
    var notesMap: [String: AnyTypNote] = [:]
    for note in doc.notes where !note.blocks.allSatisfy(blockIsBlank) {
        if notesMap[note.id] == nil { notesMap[note.id] = note }
    }
    var noteRefCounts: [String: Int] = [:]
    var visiting = Set<String>()
    countNoteRefs(doc.blocks, notesMap: notesMap, counts: &noteRefCounts, visiting: &visiting)

    let assetPaths = options.assetsDir.map { buildAssetPathMap(doc.assets, dir: $0) } ?? [:]

    let rc = RenderContext(
        anchors: resolveAnchors(blocks: doc.blocks, notes: doc.notes),
        assetPaths: assetPaths,
        notes: notesMap,
        noteRefCounts: noteRefCounts
    )

    var parts: [String] = []
    if options.standalone {
        parts.append(renderPreamble(title: options.title))
    }
    for block in doc.blocks {
        if let rendered = renderBlock(block, rc: rc) {
            parts.append(rendered)
        }
    }

    // Preserve non-empty notes that had no inline reference in the body.
    var seenUnreferenced = Set<String>()
    for note in doc.notes
    where rc.emittedNotes[note.id] == nil
        && notesMap[note.id] != nil
        && seenUnreferenced.insert(note.id).inserted {
        let body = renderBlocks(note.blocks, rc: rc)
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(body)
        }
    }

    var out = parts.joined(separator: "\n\n")
    if !out.isEmpty { out += "\n" }
    return out
}

/// Write supported image assets from `doc.assets` into `dir` with
/// deterministic path-safe names (`asset-001.png`, ...) matching
/// `RenderOptions.assetsDir`.
@discardableResult
func writeAssets(_ doc: AnyTypDocument, to dir: URL) throws -> [URL] {
    let entries = doc.assets.compactMap { asset -> (AnyTypAsset, String)? in
        typstImageExt(asset.mediaType).map { (asset, $0) }
    }
    if entries.isEmpty { return [] }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        throw ConvertError.io("cannot create asset directory \(dir.path): \(error.localizedDescription)")
    }
    var written: [URL] = []
    for (asset, ext) in entries {
        let path = dir.appending(path: assetFilename(asset.id, ext: ext))
        do {
            try asset.data.write(to: path)
        } catch {
            throw ConvertError.io("cannot write asset \(path.path): \(error.localizedDescription)")
        }
        written.append(path)
    }
    return written
}

private func buildAssetPathMap(_ assets: [AnyTypAsset], dir: String) -> [Int: String] {
    let cleanDir = dir.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\+$", with: "", options: .regularExpression)
    var map: [Int: String] = [:]
    for asset in assets {
        if let ext = typstImageExt(asset.mediaType) {
            let name = assetFilename(asset.id, ext: ext)
            let rel = (cleanDir.isEmpty || cleanDir == ".") ? name : "\(cleanDir)/\(name)"
            map[asset.id] = rel
        }
    }
    return map
}

private func assetFilename(_ id: Int, ext: String) -> String {
    String(format: "asset-%03d.%@", id + 1, ext)
}

private func typstImageExt(_ mediaType: String) -> String? {
    switch mediaType.trimmingCharacters(in: .whitespaces).lowercased() {
    case "image/png": return "png"
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/gif": return "gif"
    case "image/svg+xml": return "svg"
    case "image/webp": return "webp"
    default: return nil
    }
}

private func renderPreamble(title: String?) -> String {
    var lines: [String] = []
    if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        lines.append("#set document(title: \"\(escapeString(t))\")")
    }
    lines.append("#set page(numbering: \"1\")")
    lines.append("#set par(justify: true)")
    return lines.joined(separator: "\n")
}

func renderBlocks(_ blocks: [AnyTypBlock], rc: RenderContext) -> String {
    blocks.compactMap { renderBlock($0, rc: rc) }.joined(separator: "\n\n")
}

private func renderBlock(_ block: AnyTypBlock, rc: RenderContext) -> String? {
    switch block {
    case .heading(let level, _, let content):
        let thisIdx = rc.headingCounter
        rc.headingCounter += 1
        let label = rc.anchors.headingLabel(thisIdx)
        var text = renderInlines(content, .heading, rc: rc)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let label { return "#metadata(none) <\(label)>" }
            return nil
        }
        let lvl = max(level, 1)
        var line = lvl <= 6
            ? String(repeating: "=", count: lvl) + " \(text)"
            : "#heading(level: \(lvl))[\(text)]"
        if let label { line += " <\(label)>" }
        return line

    case .paragraph(let inlines):
        let text = renderInlines(inlines, .block, rc: rc)
        let trimmed = trimParagraph(text)
        return trimmed.isEmpty ? nil : trimmed

    case .list(let list):
        return renderList(list, rc: rc)

    case .table(let table):
        if table.kind == .layout, table.isSingleCell,
           case .origin(let cell) = table.grid[0][0] {
            let inner = renderBlocks(cell.blocks, rc: rc)
            return inner.isEmpty ? nil : inner
        }
        return renderTable(table, rc: rc)

    case .blockQuote(let blocks):
        let inner = renderBlocks(blocks, rc: rc)
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("\n") {
            var s = "#quote(block: true)[\n"
            for line in trimmed.typstLines() {
                if line.isEmpty {
                    s += "\n"
                } else {
                    s += "  " + line + "\n"
                }
            }
            s += "]"
            return s
        }
        return "#quote(block: true)[\(trimmed)]"

    case .codeBlock(let lang, let text):
        let fence = backtickFence(text, minTicks: 3)
        let langTag = lang.map(sanitizeLang) ?? ""
        var body = text
        while body.hasSuffix("\n") { body.removeLast() }
        return "\(fence)\(langTag)\n\(body)\n\(fence)"

    case .rule:
        return "#line(length: 100%)"

    case .math(let tex):
        return renderBlockMath(tex)
    }
}

private func renderList(_ list: AnyTypList, rc: RenderContext) -> String? {
    if list.items.isEmpty { return nil }

    let hasCustomLabels = list.items.contains { $0.markerLabel != nil }
    if !hasCustomLabels,
       (list.marker == .bullet || (list.marker == .decimal && list.start == 1)) {
        let prefix = list.marker == .bullet ? "- " : "+ "
        var renderedItems: [String] = []
        var loose = false
        for item in list.items {
            let body = renderBlocks(item.blocks, rc: rc)
            if item.blocks.count > 1 { loose = true }
            var lines = body.typstLines()
            let first = lines.isEmpty ? "" : lines.removeFirst()
            var s = first.isEmpty ? String(prefix.dropLast()) : "\(prefix)\(first)"
            for line in lines {
                s += "\n"
                if line.isEmpty {
                    loose = true
                } else {
                    s += "  " + line
                }
            }
            renderedItems.append(s)
        }
        return renderedItems.joined(separator: loose ? "\n\n" : "\n")
    }

    // Non-default numbering or explicit composite labels.
    if hasCustomLabels {
        var renderedItems: [String] = []
        for (idx, item) in list.items.enumerated() {
            let (sum, overflow) = list.start.addingReportingOverflow(UInt64(idx))
            let ordinal = overflow ? UInt64.max : sum
            let rawLabel = item.markerLabel ?? list.marker.label(ordinal)
            let cleanedLabel = String(rawLabel.map { isControl($0) ? " " : $0 })
            let escapedLabel = escapeMarkup(cleanedLabel.trimmingCharacters(in: .whitespacesAndNewlines), atLineStart: false)
            let body = renderBlocks(item.blocks, rc: rc)
            var lines = body.typstLines()
            let first = lines.isEmpty ? "" : lines.removeFirst()
            var s: String
            if escapedLabel.isEmpty {
                s = "- \(first)"
            } else if first.isEmpty {
                s = "- *\(escapedLabel)*"
            } else {
                s = "- *\(escapedLabel)* \(first)"
            }
            for line in lines {
                s += "\n"
                if !line.isEmpty {
                    s += "  " + line
                }
            }
            renderedItems.append(s)
        }
        return renderedItems.joined(separator: "\n")
    }

    let numbering: String?
    switch list.marker {
    case .bullet, .decimal: numbering = nil
    case .lowerAlpha: numbering = "a."
    case .upperAlpha: numbering = "A."
    case .lowerRoman: numbering = "i."
    case .upperRoman: numbering = "I."
    }
    var out = "#enum(\n"
    if let pat = numbering {
        out += "  numbering: \"\(pat)\",\n"
    }
    if list.start != 1 {
        out += "  start: \(list.start),\n"
    }
    for item in list.items {
        let body = renderBlocks(item.blocks, rc: rc)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") {
            out += "  [\n"
            for line in trimmed.typstLines() {
                if line.isEmpty {
                    out += "\n"
                } else {
                    out += "    " + line + "\n"
                }
            }
            out += "  ],\n"
        } else {
            out += "  [\(trimmed)],\n"
        }
    }
    out += ")"
    return out
}

/// Trim paragraph text: strip line-leading whitespace (keeping hard-break
/// `\` lines intact), drop trailing empty lines, remove a trailing odd `\`.
private func trimParagraph(_ text: String) -> String {
    func rtrim(_ s: String) -> String {
        var s = s[...]
        while s.last?.isWhitespace == true { s = s.dropLast() }
        return String(s)
    }
    var lines = text.typstLines().map { line -> String in
        let trimmedStart = String(line.drop(while: { $0.isWhitespace }))
        if trimmedStart.hasSuffix("\\") {
            return trimmedStart
        }
        return rtrim(trimmedStart)
    }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    if let last = lines.last {
        let trailingBS = last.reversed().prefix(while: { $0 == "\\" }).count
        if trailingBS % 2 == 1 {
            lines[lines.count - 1] = rtrim(String(last.dropLast()))
        }
    }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func blockIsBlank(_ block: AnyTypBlock) -> Bool {
    if case .paragraph(let inlines) = block {
        return inlinesAreEmpty(inlines)
    }
    return false
}

private func countNoteRefs(
    _ blocks: [AnyTypBlock],
    notesMap: [String: AnyTypNote],
    counts: inout [String: Int],
    visiting: inout Set<String>
) {
    func walkInlines(_ inlines: [AnyTypInline]) {
        for inline in inlines {
            switch inline {
            case .noteRef(let id):
                if let note = notesMap[id] {
                    counts[id, default: 0] += 1
                    if counts[id] == 1, visiting.insert(id).inserted {
                        countNoteRefs(note.blocks, notesMap: notesMap, counts: &counts, visiting: &visiting)
                        visiting.remove(id)
                    }
                }
            case .link(let content, _):
                walkInlines(content)
            default:
                break
            }
        }
    }

    for block in blocks {
        switch block {
        case .paragraph(let inlines), .heading(_, _, let inlines):
            walkInlines(inlines)
        case .list(let list):
            for item in list.items {
                countNoteRefs(item.blocks, notesMap: notesMap, counts: &counts, visiting: &visiting)
            }
        case .table(let table):
            for row in table.grid {
                for slot in row {
                    if case .origin(let cell) = slot {
                        countNoteRefs(cell.blocks, notesMap: notesMap, counts: &counts, visiting: &visiting)
                    }
                }
            }
        case .blockQuote(let inner):
            countNoteRefs(inner, notesMap: notesMap, counts: &counts, visiting: &visiting)
        case .codeBlock, .rule, .math:
            break
        }
    }
}

/// Rust `str::lines()`: split on `\n`, strip one trailing `\r`, no phantom
/// empty line after a trailing newline, and zero lines for an empty string.
extension String {
    func typstLines() -> [String] {
        if isEmpty { return [] }
        var lines = components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
