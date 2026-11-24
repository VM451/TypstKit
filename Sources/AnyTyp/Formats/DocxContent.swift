import Foundation

/// Block and inline walking for WordprocessingML parts
/// (port of `formats/docx/content.rs`).

/// Namespaces whose markup this frontend understands; `mc:Choice` branches
/// requiring anything else fall back to `mc:Fallback`.
private let docxSupportedNS: [String] = [
    XmlNS.w, XmlNS.a, XmlNS.pic, XmlNS.wp, XmlNS.mc, XmlNS.chart,
    XmlNS.dgm, XmlNS.vml, XmlNS.oVml, XmlNS.wps, XmlNS.wpg,
]

final class DocxCtx {
    let pkg: Package
    let rels: Relationships
    let basePart: String
    let styles: DocxStyles
    let numbering: DocxNumbering
    let counters: DocxCounters
    let assets: AssetSink

    init(pkg: Package, rels: Relationships, basePart: String, styles: DocxStyles,
         numbering: DocxNumbering, counters: DocxCounters, assets: AssetSink) {
        self.pkg = pkg
        self.rels = rels
        self.basePart = basePart
        self.styles = styles
        self.numbering = numbering
        self.counters = counters
        self.assets = assets
    }

    /// The same document-wide dependencies scoped to another package part
    /// (notes parts): only the relationships and base path change.
    func forPart(_ rels: Relationships, _ basePart: String) -> DocxCtx {
        DocxCtx(pkg: pkg, rels: rels, basePart: basePart, styles: styles,
                numbering: numbering, counters: counters, assets: assets)
    }

    /// Load an internal relationship target's bytes, resolved against this
    /// part.
    func relPart(_ relId: String) throws -> RelTarget? {
        try relTargetBytes(pkg, rels, basePart: basePart, relId: relId)
    }

    func addAsset(mediaType: String, part: String, bytes: [UInt8]) throws -> Int {
        try assets.add(mediaType: mediaType, originPart: part, bytes: bytes)
    }

    /// Pick the branch of an `mc:AlternateContent` to process.
    func alternateBranch(_ alt: XmlElement) -> XmlElement? {
        mcAlternateBranch(alt, supported: docxSupportedNS)
    }
}

enum DocxParaKind {
    case heading(level: Int, label: String?, base: AnyTypStyle)
    case listItem(ilvl: Int, key: ListKey, number: UInt64, label: String?)
    /// A paragraph whose style names a block container.
    case styled(BlockStyle)
    case plain
}

/// Block runs a following paragraph may extend: a list being built, and a
/// styled container.
final class DocxRuns {
    var list: [ListEntry] = []
    var styled = StyledRun.empty

    func flush(_ blocks: inout [AnyTypBlock]) {
        styled.flush(&blocks)
        flushList(&blocks, &list)
    }
}

/// A paragraph's content in source order: inline runs interleaved with
/// block attachments (text boxes, charts) at their anchor positions.
enum DocxPiece {
    case inlines([AnyTypInline])
    case blocks([AnyTypBlock])
}

func docxParseBlocks(_ parent: XmlElement, _ ctx: DocxCtx) throws -> [AnyTypBlock] {
    var blocks: [AnyTypBlock] = []
    let runs = DocxRuns()
    try collectBlocks(parent, ctx, &blocks, runs)
    runs.flush(&blocks)
    return blocks
}

private func collectBlocks(
    _ parent: XmlElement, _ ctx: DocxCtx,
    _ blocks: inout [AnyTypBlock], _ runs: DocxRuns
) throws {
    for child in parent.childElems {
        if child.is(XmlNS.mc, "AlternateContent") {
            if let branch = ctx.alternateBranch(child) {
                try collectBlocks(branch, ctx, &blocks, runs)
            }
            continue
        }
        if child.is(XmlNS.m, "oMathPara") || child.is(XmlNS.m, "oMath") {
            runs.flush(&blocks)
            blocks.append(contentsOf: Omml.paraToTex(child).map { AnyTypBlock.math($0) })
            continue
        }
        if child.ns != XmlNS.w { continue }
        switch child.local {
        case "p":
            let (kind, pieces) = try parseParagraph(child, ctx)
            emitParagraph(kind, pieces, &blocks, runs)
        case "tbl":
            runs.flush(&blocks)
            blocks.append(contentsOf: try parseTable(child, ctx))
        case "sdt":
            if let content = child.find(XmlNS.w, "sdtContent") {
                try collectBlocks(content, ctx, &blocks, runs)
            }
        case "customXml":
            try collectBlocks(child, ctx, &blocks, runs)
        default:
            break
        }
    }
}

private func emitParagraph(
    _ kind: DocxParaKind, _ pieces: [DocxPiece],
    _ blocks: inout [AnyTypBlock], _ runs: DocxRuns
) {
    switch kind {
    case .listItem(let ilvl, let key, let number, let label):
        runs.styled.flush(&blocks)
        let item = piecesIntoBlocks(pieces)
        runs.list.append(ListEntry(level: ilvl, key: key, number: number,
                                   label: label, blocks: item))
    case .styled(let style):
        flushList(&blocks, &runs.list)
        for piece in pieces {
            switch piece {
            case .inlines(let inlines): runs.styled.push(style, inlines, &blocks)
            case .blocks(let attachments):
                runs.styled.flush(&blocks)
                blocks.append(contentsOf: attachments)
            }
        }
    case .heading(let level, var label, let base):
        runs.flush(&blocks)
        var emittedHeading = false
        for piece in pieces {
            switch piece {
            case .inlines(var content):
                if inlinesAreEmpty(content) { continue }
                rebaseEmphasis(&content, base: base)
                if !emittedHeading {
                    if let l = label {
                        label = nil
                        content.insert(.text(l, style: .plain), at: 0)
                    }
                    blocks.append(.heading(level: level, anchor: nil, content: content))
                    emittedHeading = true
                } else {
                    blocks.append(.paragraph(content))
                }
            case .blocks(let attachments):
                blocks.append(contentsOf: attachments)
            }
        }
    case .plain:
        runs.flush(&blocks)
        blocks.append(contentsOf: piecesIntoBlocks(pieces))
    }
}

private func parseParagraph(_ p: XmlElement, _ ctx: DocxCtx)
    throws -> (DocxParaKind, [DocxPiece]) {
    let ppr = p.find(XmlNS.w, "pPr")
    let pstyleId = ppr?.find(XmlNS.w, "pStyle")?.attr(XmlNS.w, "val")

    // Direct paragraph properties overlay the style chain: an explicit
    // outlineLvl of 9 turns a style heading off.
    let directOutline: DocxHeadingSpec? = ppr?
        .find(XmlNS.w, "outlineLvl")?
        .attr(XmlNS.w, "val")
        .flatMap { Int($0) }
        .map { $0 < 9 ? .level($0 + 1) : .off }
    let styleHeading = try pstyleId.map { try ctx.styles.headingLevel($0) } ?? nil
    let heading: Int? = {
        let spec = directOutline ?? styleHeading ?? nil
        if case .level(let n)? = spec { return n }
        return nil
    }()
    let styleBlock = try pstyleId.map { try ctx.styles.blockStyle($0) } ?? nil

    // Numbering resolves independently of heading semantics.
    let numbering = try resolveNumbering(ppr, pstyleId, ctx)

    // Toggle properties: the paragraph style chain's true-parity flips the
    // docDefaults base.
    let parity = try pstyleId.map { try ctx.styles.runToggles($0) } ?? DocxToggles()
    let paragraphLevel = parity.applyOver(ctx.styles.docDefaults)

    let kind: DocxParaKind
    if let level = heading {
        let label: String? = {
            guard let (ilvl, key, number, label) = numbering,
                  key.marker.ordered else { return nil }
            return "\(label ?? key.marker.label(number)) "
        }()
        kind = .heading(level: level, label: label, base: paragraphLevel)
    } else if let (ilvl, key, number, label) = numbering {
        kind = .listItem(ilvl: ilvl, key: key, number: number, label: label)
    } else if let style = styleBlock {
        kind = .styled(style)
    } else {
        kind = .plain
    }

    let walker = InlineWalker(ctx: ctx, base: paragraphLevel)
    try walker.walk(p)
    return (kind, walker.finish())
}

/// Resolve a paragraph's effective numbering per ECMA-376: the direct
/// `numPr` children are tri-state and merge property-by-property with the
/// style-inherited `numPr` (a missing `numId`/`ilvl` inherits; an explicit
/// `numId` of 0 suppresses).
private func resolveNumbering(
    _ ppr: XmlElement?, _ pstyleId: String?, _ ctx: DocxCtx
) throws -> (ilvl: Int, key: ListKey, number: UInt64, label: String?)? {
    let direct = ppr?.find(XmlNS.w, "numPr")
    let directNumId = direct?.find(XmlNS.w, "numId")?.attr(XmlNS.w, "val")
        .flatMap { UInt64($0) }
    let directIlvl = direct?.find(XmlNS.w, "ilvl")?.attr(XmlNS.w, "val")
        .flatMap { Int($0) }

    let numId: UInt64? = directNumId ?? (pstyleId.flatMap {
        try? ctx.styles.styleNumPr($0)
    } ?? nil)
    guard let numId else { return nil }
    if numId == 0 { return nil } // explicitly suppressed
    guard let instance = ctx.numbering.instance(numId) else {
        AnyTypLog.debug("paragraph references undefined numbering instance \(numId)")
        return nil
    }
    let ilvl: Int
    if let l = directIlvl {
        ilvl = l
    } else if let sid = pstyleId {
        ilvl = (try? ctx.styles.styleNumberingLevel(sid, instance: instance)) ?? 0
    } else {
        ilvl = 0
    }
    let clamped = min(ilvl, docxLevels - 1)
    guard let marker = instance.levels[clamped].marker else { return nil }
    let key = ListKey(instance: numId, marker: marker)
    if marker.ordered {
        let (number, label) = ctx.counters.next(numId, ilvl, instance: instance)
        return (ilvl, key, number, label)
    }
    return (ilvl, key, 0, nil)
}

private final class InlineWalker {
    let ctx: DocxCtx
    let base: AnyTypStyle
    var pieces: [DocxPiece] = []
    var current: [AnyTypInline] = []
    var fields: [FieldFrame] = []

    init(ctx: DocxCtx, base: AnyTypStyle) {
        self.ctx = ctx
        self.base = base
    }

    func push(_ inline: AnyTypInline) {
        if let last = fields.last {
            if last.inResult {
                fields[fields.count - 1].inlines.append(inline)
            }
        } else {
            current.append(inline)
        }
    }

    /// Attach block content at the current position in run order.
    func pushBlocks(_ blocks: [AnyTypBlock]) {
        if blocks.isEmpty { return }
        if !current.isEmpty {
            pieces.append(.inlines(current))
            current = []
        }
        pieces.append(.blocks(blocks))
    }

    func walk(_ elem: XmlElement) throws {
        for child in elem.childElems {
            if child.is(XmlNS.mc, "AlternateContent") {
                if let branch = ctx.alternateBranch(child) {
                    try walk(branch)
                }
                continue
            }
            if child.is(XmlNS.m, "oMathPara") {
                pushBlocks(Omml.paraToTex(child).map { AnyTypBlock.math($0) })
                continue
            }
            if child.is(XmlNS.m, "oMath") {
                let tex = Omml.toTex(child)
                if !tex.isEmpty { push(.math(tex)) }
                continue
            }
            if child.ns != XmlNS.w { continue }
            switch child.local {
            case "pPr": break
            case "r": try walkRun(child)
            case "hyperlink":
                let target = hyperlinkLinkTarget(child)
                let inner = InlineWalker(ctx: ctx, base: base)
                try inner.walk(child)
                let (content, attachments) = splitPieces(inner.finish())
                if let target {
                    push(.link(content: content, target: target))
                } else {
                    for inline in content { push(inline) }
                }
                pushBlocks(attachments)
            case "fldSimple":
                let instr = child.attr(XmlNS.w, "instr") ?? ""
                let inner = InlineWalker(ctx: ctx, base: base)
                try inner.walk(child)
                let (content, attachments) = splitPieces(inner.finish())
                for inline in fieldResult(instr, content: content) { push(inline) }
                pushBlocks(attachments)
            case "bookmarkStart":
                if let name = child.attr(XmlNS.w, "name"), name != "_GoBack" {
                    push(.anchor(name))
                }
            case "sdt":
                if let content = child.find(XmlNS.w, "sdtContent") {
                    try walk(content)
                }
            // `moveTo` is moved-in text — part of the final document;
            // `customXml` wraps ordinary run content.
            case "smartTag", "ins", "bdo", "dir", "moveTo", "customXml":
                try walk(child)
            default:
                break
            }
        }
    }

    private func hyperlinkLinkTarget(_ link: XmlElement) -> AnyTypLinkTarget? {
        if let id = link.attrQualified(XmlNS.r, "id"),
           let rel = ctx.rels.get(id) {
            return classifyRelTarget(external: rel.mode == .external, target: rel.target)
        }
        return link.attr(XmlNS.w, "anchor").map { .anchor($0) }
    }

    private func walkRun(_ run: XmlElement) throws {
        let style: AnyTypStyle
        if let rpr = run.find(XmlNS.w, "rPr") {
            // Character-style chain: another toggle layer over the
            // paragraph-level value. Direct formatting is absolute.
            let charParity: DocxToggles
            if let id = rpr.find(XmlNS.w, "rStyle")?.attr(XmlNS.w, "val") {
                charParity = (try? ctx.styles.runToggles(id)) ?? DocxToggles()
            } else {
                charParity = DocxToggles()
            }
            let withChar = charParity.applyOver(base)
            style = rprDelta(rpr).apply(withChar)
        } else {
            style = base
        }
        try walkRunContent(run, style: style)
    }

    private func walkRunContent(_ run: XmlElement, style: AnyTypStyle) throws {
        for child in run.childElems {
            if child.is(XmlNS.mc, "AlternateContent") {
                if let branch = ctx.alternateBranch(child) {
                    try walkRunContent(branch, style: style)
                }
                continue
            }
            if child.ns != XmlNS.w { continue }
            switch child.local {
            case "t":
                // Run edges carry the spacing between words in documents
                // that never mark xml:space, and XML leaves unmarked
                // whitespace to the application, so it is kept.
                let text = SharedText.clean(child.text)
                if !text.isEmpty {
                    push(.text(text, style: style))
                }
            case "tab", "ptab":
                push(.text(" ", style: .plain))
            // Every w:br still separates the runs around it.
            case "br", "cr":
                push(.lineBreak)
            case "footnoteReference":
                if let id = child.attr(XmlNS.w, "id") {
                    push(.noteRef("fn\(id)"))
                }
            case "endnoteReference":
                if let id = child.attr(XmlNS.w, "id") {
                    push(.noteRef("en\(id)"))
                }
            case "drawing", "pict", "object":
                try walkDrawing(child)
            case "fldChar":
                switch child.attr(XmlNS.w, "fldCharType") {
                case "begin":
                    fields.append(FieldFrame())
                case "separate":
                    if !fields.isEmpty { fields[fields.count - 1].inResult = true }
                case "end":
                    if let frame = fields.popLast() {
                        for inline in fieldResult(frame.instr, content: frame.inlines) {
                            push(inline)
                        }
                    }
                default: break
                }
            case "instrText":
                if !fields.isEmpty {
                    fields[fields.count - 1].instr += child.text
                }
            default:
                break
            }
        }
    }

    /// Drawings, VML picts, and embedded objects: text boxes become block
    /// attachments at this position; images/charts/diagrams/objects resolve
    /// through relationships.
    private func walkDrawing(_ elem: XmlElement) throws {
        // Text boxes first: their content is the drawing's content.
        var boxes: [XmlElement] = []
        collectTextBoxes(elem, &boxes)
        if !boxes.isEmpty {
            var blocks: [AnyTypBlock] = []
            for tb in boxes {
                blocks.append(contentsOf: try docxParseBlocks(tb, ctx))
            }
            pushBlocks(blocks)
            return
        }

        let descr = (elem.firstDescendant(XmlNS.wp, "docPr")?
            .attr(XmlNS.wp, "descr")).map { SharedText.clean($0) } ?? ""

        // Charts and SmartArt render their textual content.
        if let chartRef = elem.firstDescendant(XmlNS.chart, "chart"),
           let relId = chartRef.attrQualified(XmlNS.r, "id") {
            pushBlocks(try chartBlocks(relId))
            return
        }
        if let relIds = elem.firstDescendant(XmlNS.dgm, "relIds"),
           let relId = relIds.attrQualified(XmlNS.r, "dm") {
            pushBlocks(try diagramBlocks(relId))
            return
        }

        // Embedded OLE objects come before images.
        if let ole = elem.firstDescendant(XmlNS.oVml, "OLEObject") {
            let progId = ole.attr(XmlNS.oVml, "ProgID") ?? "object"
            let alt = descr.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Embedded object: \(progId)" : descr
            let source: AnyTypImageSource
            if let relId = ole.attrQualified(XmlNS.r, "id"),
               let (part, data) = try ctx.relPart(relId) {
                let id = try ctx.addAsset(mediaType: "application/vnd.ms-ole-object",
                                          part: part, bytes: [UInt8](data))
                source = .asset(id)
            } else {
                source = .unavailable
            }
            push(.image(alt: alt, source: source))
            return
        }

        // Bitmap images: DrawingML blip or VML imagedata.
        let imageRel = elem.firstDescendant(XmlNS.a, "blip").flatMap {
            $0.attrQualified(XmlNS.r, "embed") ?? $0.attrQualified(XmlNS.r, "link")
        } ?? elem.firstDescendant(XmlNS.vml, "imagedata")?
            .attrQualified(XmlNS.r, "id")
        if let relId = imageRel {
            // External-mode targets (`r:link`) become external image
            // sources; embedded targets are retained as assets.
            if let source = try relImageSource(ctx.pkg, ctx.rels, basePart: ctx.basePart,
                                               ctx.assets, relId: relId) {
                push(.image(alt: descr, source: source))
            } else if !descr.trimmingCharacters(in: .whitespaces).isEmpty {
                push(.image(alt: descr, source: .unavailable))
            }
            return
        }

        if !descr.trimmingCharacters(in: .whitespaces).isEmpty {
            push(.image(alt: descr, source: .unavailable))
        }
    }

    /// Textual extraction of a chart part via `DrawingML`.
    private func chartBlocks(_ relId: String) throws -> [AnyTypBlock] {
        guard let (part, data) = try ctx.relPart(relId) else { return [] }
        do {
            return DrawingML.chartBlocks(try parseXML(data))
        } catch let e as ConvertError {
            if e.isFatal { throw e }
            AnyTypLog.warn("skipping corrupt chart part \(part): \(errorDesc(e))")
            return []
        } catch {
            AnyTypLog.warn("skipping corrupt chart part \(part): \(error)")
            return []
        }
    }

    /// Textual extraction of a SmartArt data part via `DrawingML`.
    private func diagramBlocks(_ relId: String) throws -> [AnyTypBlock] {
        guard let (part, data) = try ctx.relPart(relId) else { return [] }
        do {
            return DrawingML.diagramBlocks(try parseXML(data))
        } catch let e as ConvertError {
            if e.isFatal { throw e }
            AnyTypLog.warn("skipping corrupt diagram part \(part): \(errorDesc(e))")
            return []
        } catch {
            AnyTypLog.warn("skipping corrupt diagram part \(part): \(error)")
            return []
        }
    }

    func finish() -> [DocxPiece] {
        while let frame = fields.popLast() {
            for inline in frame.inlines { push(inline) }
        }
        if !current.isEmpty {
            pieces.append(.inlines(current))
            current = []
        }
        return pieces
    }
}

private func splitPieces(_ pieces: [DocxPiece]) -> ([AnyTypInline], [AnyTypBlock]) {
    var inlines: [AnyTypInline] = []
    var blocks: [AnyTypBlock] = []
    for piece in pieces {
        switch piece {
        case .inlines(let i): inlines.append(contentsOf: i)
        case .blocks(let b): blocks.append(contentsOf: b)
        }
    }
    return (inlines, blocks)
}

private func piecesIntoBlocks(_ pieces: [DocxPiece]) -> [AnyTypBlock] {
    var blocks: [AnyTypBlock] = []
    for piece in pieces {
        switch piece {
        // Visually empty inlines still become a paragraph: a
        // bookmark-only one carries the anchor link resolution binds to.
        case .inlines(let inlines): blocks.append(.paragraph(inlines))
        case .blocks(let attachments): blocks.append(contentsOf: attachments)
        }
    }
    return blocks
}

/// Find text-box content (`w:txbxContent`) in a drawing or VML pict,
/// skipping `mc:Fallback` so AlternateContent shapes aren't collected twice.
private func collectTextBoxes(_ elem: XmlElement, _ out: inout [XmlElement]) {
    for child in elem.childElems {
        if child.is(XmlNS.mc, "Fallback") { continue }
        if child.is(XmlNS.w, "txbxContent") {
            out.append(child)
        } else {
            collectTextBoxes(child, &out)
        }
    }
}

// MARK: - Tables

private struct TcInfo {
    var elem: XmlElement?
    /// Legacy `hMerge` continuation cells folded into this origin.
    var merged: [XmlElement] = []
    var colSpan = 1
    var rowSpan = 1
    /// vMerge continuation: this position belongs to the origin above.
    var covered = false

    /// Empty single-column filler for `gridBefore`/`gridAfter` positions.
    static func filler() -> TcInfo { TcInfo(elem: nil) }
}

/// A `w:trPr` grid filler count (`gridBefore`/`gridAfter`).
private func gridFiller(_ trpr: XmlElement?, _ name: String) -> Int {
    min(Int(trpr?.find(XmlNS.w, name)?.attr(XmlNS.w, "val") ?? "0") ?? 0, 1000)
}

private func parseTable(_ tbl: XmlElement, _ ctx: DocxCtx) throws -> [AnyTypBlock] {
    // Collect the raw cell matrix first so vertical merges can be resolved
    // into row spans before the grid is built.
    var matrix: [[TcInfo]] = []
    for tr in tbl.findAll(XmlNS.w, "tr") {
        let trpr = tr.find(XmlNS.w, "trPr")
        var row: [TcInfo] = []
        row += (0..<gridFiller(trpr, "gridBefore")).map { _ in TcInfo.filler() }
        collectRowCells(tr, &row)
        row += (0..<gridFiller(trpr, "gridAfter")).map { _ in TcInfo.filler() }
        matrix.append(row)
    }
    // Active vertical-merge chains by grid column.
    var active: [Int: (row: Int, idx: Int)] = [:]
    for r in matrix.indices {
        var col = 0
        var nextActive: [(Int, (Int, Int))] = []
        for i in matrix[r].indices {
            let covered = matrix[r][i].covered
            let span = matrix[r][i].colSpan
            if covered {
                if let (orow, oidx) = active[col] {
                    matrix[orow][oidx].rowSpan += 1
                    for c in col..<(col + span) {
                        nextActive.append((c, (orow, oidx)))
                    }
                } else {
                    matrix[r][i].covered = false // stray continuation
                }
            } else {
                for c in col..<(col + span) {
                    nextActive.append((c, (r, i)))
                }
            }
            col += span
        }
        active = Dictionary(uniqueKeysWithValues: nextActive)
    }

    // tblHeader is ST_OnOff: an explicit false value is not a header row.
    let headerRows = tbl.findAll(XmlNS.w, "tr")
        .prefix(while: {
            onOff($0.find(XmlNS.w, "trPr") ?? XmlElement(ns: nil, local: "", attrs: []),
                   "tblHeader") == true
        })
        .count

    let builder = GridBuilder()
    for row in matrix {
        builder.nextRow()
        for tc in row {
            if tc.covered {
                for _ in 0..<tc.colSpan { builder.covered() }
            } else {
                var blocks: [AnyTypBlock] = []
                if let elem = tc.elem {
                    blocks = try docxParseBlocks(elem, ctx)
                }
                for merged in tc.merged {
                    blocks.append(contentsOf: try docxParseBlocks(merged, ctx))
                }
                try builder.place(.spanning(blocks, colSpan: tc.colSpan, rowSpan: tc.rowSpan))
            }
        }
    }
    var table = builder.finish(kind: .data)
    if table.grid.isEmpty { return [] }
    table.headerRows = HeaderDetect.resolve(table, declared: headerRows)
    return [.table(table)]
}

private func collectRowCells(_ parent: XmlElement, _ cells: inout [TcInfo]) {
    for child in parent.childElems {
        if child.ns != XmlNS.w { continue }
        switch child.local {
        case "tc":
            let tcpr = child.find(XmlNS.w, "tcPr")
            let covered = tcpr?.find(XmlNS.w, "vMerge").map {
                $0.attr(XmlNS.w, "val") != "restart"
            } ?? false
            let colSpan = min(max(Int(tcpr?.find(XmlNS.w, "gridSpan")?
                .attr(XmlNS.w, "val") ?? "1") ?? 1, 1), 1000)
            // Legacy hMerge: a non-restart hMerge cell folds into the
            // preceding origin, widening its span.
            let hmergeCont = tcpr?.find(XmlNS.w, "hMerge").map {
                $0.attr(XmlNS.w, "val") != "restart"
            } ?? false
            if hmergeCont, !cells.isEmpty, !cells[cells.count - 1].covered {
                cells[cells.count - 1].colSpan += colSpan
                cells[cells.count - 1].merged.append(child)
                continue
            }
            cells.append(TcInfo(elem: child, colSpan: colSpan, covered: covered))
        case "sdt":
            if let content = child.find(XmlNS.w, "sdtContent") {
                collectRowCells(content, &cells)
            }
        case "customXml":
            collectRowCells(child, &cells)
        default:
            break
        }
    }
}
