import Foundation

/// OOXML PresentationML (.pptx / .pptm / .ppsx) frontend (port of
/// `formats/pptx/mod.rs`): slides in `sldIdLst` order, with the full text
/// cascade — slide -> layout -> master placeholder / `txStyles` ->
/// presentation defaults. Speaker notes are included (fixed policy),
/// rendered as a quote after each slide's content.
enum PptxFormat {
    private static let layoutRel =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
    private static let masterRel =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
    private static let notesRel =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"
    private static let slideRel =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"

    /// Namespaces whose markup this frontend understands; `mc:Choice`
    /// branches requiring anything else fall back to `mc:Fallback`.
    private static let supportedNS = [XmlNS.p, XmlNS.a, XmlNS.r, XmlNS.mc, XmlNS.a14]

    private struct LayoutInfo {
        var placeholders: [PptxCascade.Placeholder]
        var masterPath: String?
    }

    private struct MasterInfo {
        var title = PptxCascade.LevelStyle()
        var body = PptxCascade.LevelStyle()
        var other = PptxCascade.LevelStyle()
        var placeholders: [PptxCascade.Placeholder] = []
    }

    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let pkg: Package
        do {
            pkg = try Package(bytes: bytes)
        } catch let e as ConvertError {
            return .failure(probeOle(bytes: bytes) ?? e)
        } catch {
            return .failure(.io("\(error)"))
        }

        // OPC part discovery: the presentation part comes from the
        // package-level officeDocument relationship, with the conventional
        // path as fallback.
        let rootRels: Relationships
        do {
            rootRels = try readRels(pkg, "_rels/.rels")
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        let presPart = rootRels.firstOfType(RelType.officeDocument)
            .flatMap { rel in try? resolvePackageTarget("", rel.target).path }
            ?? "ppt/presentation.xml"
        let pres: XmlElement
        do {
            pres = try pkg.requiredXMLPart(presPart)
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        let presRels: Relationships
        do {
            presRels = try readRels(pkg, relsPartFor(presPart))
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }

        let defaultText = PptxCascade.parseLevelStyles(
            pres.firstDescendant(XmlNS.p, "defaultTextStyle"))

        let slidePaths: [String] = pres.firstDescendant(XmlNS.p, "sldIdLst")
            .map { list in
                list.findAll(XmlNS.p, "sldId").compactMap { s in
                    s.attrQualified(XmlNS.r, "id")
                        .flatMap { presRels.internalTarget($0) }
                        .flatMap { try? resolvePackageTarget(presPart, $0).path }
                }
            } ?? []
        if slidePaths.isEmpty {
            return .failure(.malformed(
                part: presPart, detail: "presentation has no slide list"))
        }

        let assets = AssetSink()
        var layouts: [String: LayoutInfo] = [:]
        var masters: [String: MasterInfo] = [:]
        var blocks: [AnyTypBlock] = []
        var failed = 0
        // Every slide has a start anchor id so internal slide-to-slide links
        // resolve after concatenation; the anchor node is emitted only on
        // slides some link actually targets.
        let slideAnchors: [String: String] = Dictionary(
            uniqueKeysWithValues: slidePaths.enumerated().map {
                ($0.element, "slide-\($0.offset + 1)")
            })
        var allRels: [Relationships] = []
        do {
            for p in slidePaths {
                allRels.append(try readRels(pkg, relsPartFor(p)))
            }
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        var targeted = Set<String>()
        for (p, rels) in zip(slidePaths, allRels) {
            for (_, rel) in rels.all where rel.relType == slideRel && rel.mode == .internal {
                if let t = try? resolvePackageTarget(p, rel.target),
                   slideAnchors[t.path] != nil {
                    targeted.insert(t.path)
                }
            }
        }

        for (slideIndex, slidePath) in slidePaths.enumerated() {
            let tree: XmlElement?
            do {
                tree = try pkg.optionalXMLPart(slidePath)
            } catch {
                return .failure(error as? ConvertError ?? .io("\(error)"))
            }
            guard let tree else {
                AnyTypLog.warn("skipping unusable slide \(slidePath)")
                failed += 1
                continue
            }
            guard let spTree = tree.find(XmlNS.p, "sld")?
                .find(XmlNS.p, "cSld")?
                .find(XmlNS.p, "spTree") else {
                AnyTypLog.warn("skipping slide \(slidePath): no shape tree")
                failed += 1
                continue
            }
            let slideRels = allRels[slideIndex]

            let layoutPath = relTargetOfType(slideRels, slidePath, layoutRel)
            if let lp = layoutPath, layouts[lp] == nil {
                do {
                    let info = try loadLayout(pkg, lp)
                    if let mp = info.masterPath, masters[mp] == nil {
                        masters[mp] = try loadMaster(pkg, mp)
                    }
                    layouts[lp] = info
                } catch {
                    return .failure(error as? ConvertError ?? .io("\(error)"))
                }
            }
            let layout = layoutPath.flatMap { layouts[$0] }
            let master = layout?.masterPath.flatMap { masters[$0] }

            var ctx = SlideCtx(
                pkg: pkg, rels: slideRels, basePart: slidePath,
                assets: assets, defaultText: defaultText,
                layout: layout, master: master,
                slideAnchors: slideAnchors)
            if targeted.contains(slidePath), let anchor = slideAnchors[slidePath] {
                blocks.append(.paragraph([.anchor(anchor)]))
            }
            do {
                try parseShapes(spTree, &ctx, &blocks)
            } catch {
                return .failure(error as? ConvertError ?? .io("\(error)"))
            }

            // Speaker notes, set off as a quote (fixed policy: included).
            if let notesPath = relTargetOfType(slideRels, slidePath, notesRel) {
                do {
                    if let notesTree = try pkg.optionalXMLPart(notesPath) {
                        let notesRels = try readRels(pkg, relsPartFor(notesPath))
                        var notesCtx = ctx
                        notesCtx.rels = notesRels
                        notesCtx.basePart = notesPath
                        notesCtx.layout = nil
                        notesCtx.master = nil
                        var notesBlocks: [AnyTypBlock] = []
                        for sp in notesTree.descendants(XmlNS.p, "sp") {
                            // Keep note text bodies (real producers use a
                            // body placeholder; LibreOffice writes plain text
                            // boxes) but skip the slide-image and chrome
                            // placeholders.
                            if let pt = placeholderType(sp),
                               ["sldImg", "sldNum", "hdr", "ftr", "dt"].contains(pt) {
                                continue
                            }
                            if let tx = sp.find(XmlNS.p, "txBody") {
                                try parseTextBody(tx, &notesCtx, nil, &notesBlocks)
                            }
                        }
                        if !notesBlocks.isEmpty {
                            blocks.append(.blockQuote(notesBlocks))
                        }
                    }
                } catch {
                    return .failure(error as? ConvertError ?? .io("\(error)"))
                }
            }
        }
        if failed == slidePaths.count {
            return .failure(.malformed(part: nil, detail: "no slide in the presentation could be read"))
        }

        return .success(AnyTypDocument(
            blocks: blocks, notes: [], assets: assets.assets))
    }

    private static func relTargetOfType(
        _ rels: Relationships, _ base: String, _ relType: String
    ) -> String? {
        // firstOfType picks the lowest id, so duplicate relationships
        // resolve deterministically.
        rels.firstOfType(relType)
            .flatMap { try? resolvePackageTarget(base, $0.target).path }
    }

    private static func loadLayout(_ pkg: Package, _ layoutPath: String) throws -> LayoutInfo {
        let placeholders: [PptxCascade.Placeholder]
        if let tree = try pkg.optionalXMLPart(layoutPath) {
            placeholders = tree.firstDescendant(XmlNS.p, "spTree")
                .map(PptxCascade.collectPlaceholders) ?? []
        } else {
            placeholders = []
        }
        let rels = try readRels(pkg, relsPartFor(layoutPath))
        return LayoutInfo(
            placeholders: placeholders,
            masterPath: relTargetOfType(rels, layoutPath, masterRel))
    }

    private static func loadMaster(_ pkg: Package, _ masterPath: String) throws -> MasterInfo {
        var info = MasterInfo()
        if let tree = try pkg.optionalXMLPart(masterPath) {
            if let txStyles = tree.firstDescendant(XmlNS.p, "txStyles") {
                info.title = PptxCascade.parseLevelStyles(txStyles.find(XmlNS.p, "titleStyle"))
                info.body = PptxCascade.parseLevelStyles(txStyles.find(XmlNS.p, "bodyStyle"))
                info.other = PptxCascade.parseLevelStyles(txStyles.find(XmlNS.p, "otherStyle"))
            }
            if let spTree = tree.firstDescendant(XmlNS.p, "spTree") {
                info.placeholders = PptxCascade.collectPlaceholders(spTree)
            }
        }
        return info
    }

    private struct SlideCtx {
        var pkg: Package
        var rels: Relationships
        var basePart: String
        var assets: AssetSink
        var defaultText: PptxCascade.LevelStyle
        var layout: LayoutInfo?
        var master: MasterInfo?
        /// Per-text-body list instance ids, unique document-wide.
        var instanceCounter: UInt64 = 0
        /// Slide part path -> the slide's start anchor id, for internal
        /// slide-to-slide links.
        var slideAnchors: [String: String]

        /// Slide-to-slide relationships become anchor links to the target
        /// slide's start anchor; everything else classifies as usual.
        func linkTarget(_ rel: Relationship) -> AnyTypLinkTarget {
            if rel.mode == .internal,
               let t = try? resolvePackageTarget(basePart, rel.target),
               let anchor = slideAnchors[t.path] {
                return .anchor(anchor)
            }
            return classifyRelTarget(external: rel.mode == .external, target: rel.target)
        }

        /// Fold the cascade for a paragraph, outermost first.
        func baseProps(
            _ ph: PhInfo?, shapeStyles: PptxCascade.LevelStyle, lvl: Int
        ) -> PptxCascade.TextProps {
            var props = defaultText.level(lvl)
            if let master {
                let classStyle: PptxCascade.LevelStyle
                switch ph.map({ PptxCascade.titleClass($0.phType) }) {
                case .title: classStyle = master.title
                case .body: classStyle = master.body
                case nil: classStyle = master.other
                }
                props = props.merge(classStyle.level(lvl))
                if let ph,
                   let hit = PptxCascade.matchPlaceholder(
                       master.placeholders, phType: ph.phType, idx: ph.idx) {
                    props = props.merge(hit.styles.level(lvl))
                }
            }
            if let layout, let ph,
               let hit = PptxCascade.matchPlaceholder(
                   layout.placeholders, phType: ph.phType, idx: ph.idx) {
                props = props.merge(hit.styles.level(lvl))
            }
            return props.merge(shapeStyles.level(lvl))
        }

        /// Load an internal relationship target's bytes, resolved against
        /// this part. Failures degrade (log + `nil`) per the unified policy;
        /// resource-limit errors always propagate.
        func relPart(_ relId: String) throws -> (path: String, bytes: Data)? {
            try relTargetBytes(pkg, rels, basePart: basePart, relId: relId)
        }
    }

    private struct PhInfo {
        var phType: String
        var idx: String?
    }

    private static func placeholderType(_ sp: XmlElement) -> String? {
        sp.firstDescendant(XmlNS.p, "ph").map {
            $0.attr(XmlNS.p, "type") ?? "body"
        }
    }

    private static func parseShapes(
        _ parent: XmlElement, _ ctx: inout SlideCtx, _ blocks: inout [AnyTypBlock]
    ) throws {
        for child in parent.childElems {
            if child.is(XmlNS.mc, "AlternateContent") {
                if let branch = mcAlternateBranch(child, supported: supportedNS) {
                    try parseShapes(branch, &ctx, &blocks)
                }
                continue
            }
            if child.ns != XmlNS.p { continue }
            switch child.local {
            // Connector shapes carry the same `p:txBody` as plain shapes.
            case "sp", "cxnSp":
                try parseShape(child, &ctx, &blocks)
            case "grpSp":
                try parseShapes(child, &ctx, &blocks)
            case "graphicFrame":
                try parseGraphicFrame(child, &ctx, &blocks)
            case "pic":
                let descr = child.firstDescendant(XmlNS.p, "cNvPr")
                    .flatMap { $0.attr(XmlNS.p, "descr") }
                    .map(SharedText.clean) ?? ""
                let rid = child.firstDescendant(XmlNS.a, "blip").flatMap {
                    $0.attrQualified(XmlNS.r, "embed") ?? $0.attrQualified(XmlNS.r, "link")
                }
                // External-mode targets (`r:link`) become external image
                // sources; embedded targets are retained as assets.
                let source = try rid.flatMap {
                    try relImageSource(
                        ctx.pkg, ctx.rels, basePart: ctx.basePart,
                        ctx.assets, relId: $0)
                }
                if source != nil || !descr.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.paragraph([.image(
                        alt: descr,
                        source: source ?? .unavailable)]))
                }
            default: break
            }
        }
    }

    private static func parseShape(
        _ sp: XmlElement, _ ctx: inout SlideCtx, _ blocks: inout [AnyTypBlock]
    ) throws {
        let ph: PhInfo? = sp.firstDescendant(XmlNS.p, "ph").map {
            PhInfo(
                phType: $0.attr(XmlNS.p, "type") ?? "body",
                idx: $0.attr(XmlNS.p, "idx"))
        }
        if let ph, ["sldNum", "dt", "ftr"].contains(ph.phType) { return }
        guard let tx = sp.find(XmlNS.p, "txBody") else { return }
        // Titles get heading semantics but keep their shape-order position.
        if ph.map({ PptxCascade.titleClass($0.phType) }) == .title {
            try pushTitleHeading(tx, &ctx, ph, &blocks)
        } else {
            try parseTextBody(tx, &ctx, ph, &blocks)
        }
    }

    /// Collapse a title placeholder's paragraphs into one slide heading.
    /// Runs resolve through the full cascade like body text.
    private static func pushTitleHeading(
        _ tx: XmlElement, _ ctx: inout SlideCtx, _ ph: PhInfo?,
        _ blocks: inout [AnyTypBlock]
    ) throws {
        let shapeStyles = PptxCascade.parseLevelStyles(tx.find(XmlNS.a, "lstStyle"))
        var inlines: [AnyTypInline] = []
        for p in tx.findAll(XmlNS.a, "p") {
            let ppr = p.find(XmlNS.a, "pPr")
            let lvl = ppr?.attr(XmlNS.a, "lvl").flatMap(Int.init) ?? 0
            var props = ctx.baseProps(ph, shapeStyles: shapeStyles, lvl: lvl)
            if let ppr {
                props = props.merge(PptxCascade.paragraphProps(ppr))
            }
            let base = props.delta.resolve()
            var para = parseParaInlines(p, &ctx, base: base)
            if inlinesAreEmpty(para) { continue }
            rebaseEmphasis(&para, base: base)
            if !inlines.isEmpty { inlines.append(.lineBreak) }
            inlines.append(contentsOf: para)
        }
        if !inlinesAreEmpty(inlines) {
            blocks.append(.heading(
                level: 2,
                anchor: inlinesToPlainText(inlines),
                content: inlines))
        }
    }

    private static func parseTextBody(
        _ tx: XmlElement, _ ctx: inout SlideCtx, _ ph: PhInfo?,
        _ blocks: inout [AnyTypBlock]
    ) throws {
        let shapeStyles = PptxCascade.parseLevelStyles(tx.find(XmlNS.a, "lstStyle"))
        ctx.instanceCounter += 1
        let instance = ctx.instanceCounter
        var counters = [UInt64](repeating: 0, count: PptxCascade.levels)
        var started = [Bool](repeating: false, count: PptxCascade.levels)
        var listRun: [ListEntry] = []

        for p in tx.findAll(XmlNS.a, "p") {
            let ppr = p.find(XmlNS.a, "pPr")
            let lvl = ppr?.attr(XmlNS.a, "lvl").flatMap(Int.init) ?? 0
            var props = ctx.baseProps(ph, shapeStyles: shapeStyles, lvl: lvl)
            if let ppr {
                props = props.merge(PptxCascade.paragraphProps(ppr))
            }
            let base = props.delta.resolve()
            let inlines = parseParaInlines(p, &ctx, base: base)
            if inlinesAreEmpty(inlines) {
                flushList(&blocks, &listRun)
                continue
            }
            switch props.bullet {
            case .autoNum(let marker, let start, let wrap):
                let lvlIdx = min(lvl, PptxCascade.levels - 1)
                let number: UInt64
                if started[lvlIdx] {
                    number = counters[lvlIdx] &+ 1
                } else {
                    started[lvlIdx] = true
                    number = start
                }
                counters[lvlIdx] = number
                for i in (lvlIdx + 1)..<started.count { started[i] = false }
                listRun.append(ListEntry(
                    level: lvl,
                    key: ListKey(instance: instance, marker: marker),
                    number: number,
                    label: wrap.label(marker, number),
                    blocks: [.paragraph(inlines)]))
            case .char:
                listRun.append(ListEntry(
                    level: lvl,
                    key: ListKey(instance: instance, marker: .bullet),
                    number: 0,
                    label: nil,
                    blocks: [.paragraph(inlines)]))
            case .none, .inherit:
                flushList(&blocks, &listRun)
                if let lines = mathLines(inlines) {
                    blocks.append(contentsOf: lines.map { .math($0) })
                } else {
                    blocks.append(.paragraph(inlines))
                }
            }
        }
        flushList(&blocks, &listRun)
    }

    /// The equations of a paragraph that holds nothing else, for formats
    /// whose math paragraphs arrive as inline content (port of
    /// `shared/math/mod.rs::math_lines`).
    private static func mathLines(_ inlines: [AnyTypInline]) -> [String]? {
        var lines: [String] = []
        for i in inlines {
            switch i {
            case .math(let tex): lines.append(tex)
            case .lineBreak: continue
            case .text(let t, _) where t.trimmingCharacters(in: .whitespaces).isEmpty:
                continue
            default: return nil
            }
        }
        return lines.isEmpty ? nil : lines
    }

    private static func parseParaInlines(
        _ p: XmlElement, _ ctx: inout SlideCtx, base: AnyTypStyle
    ) -> [AnyTypInline] {
        var out: [AnyTypInline] = []
        for child in p.childElems {
            if child.is(XmlNS.a14, "m") {
                let para = child.find(XmlNS.m, "oMathPara") ?? child
                for (i, tex) in Omml.paraToTex(para).enumerated() {
                    if i > 0 { out.append(.lineBreak) }
                    out.append(.math(tex))
                }
                continue
            }
            if child.ns != XmlNS.a { continue }
            switch child.local {
            case "r", "fld":
                let rpr = child.find(XmlNS.a, "rPr")
                let text = SharedText.clean(child.find(XmlNS.a, "t")?.text ?? "")
                if text.isEmpty { continue }
                let style = rpr.map { PptxCascade.rprDelta($0).apply(base) } ?? base
                let inline: AnyTypInline = .text(text, style: style)
                var target: AnyTypLinkTarget? = nil
                if let rid = rpr?
                    .find(XmlNS.a, "hlinkClick")?
                    .attrQualified(XmlNS.r, "id"),
                   let rel = ctx.rels.get(rid) {
                    target = ctx.linkTarget(rel)
                }
                if let target {
                    out.append(.link(content: [inline], target: target))
                } else {
                    out.append(inline)
                }
            case "br":
                out.append(.lineBreak)
            default: break
            }
        }
        return out
    }

    private static func parseGraphicFrame(
        _ frame: XmlElement, _ ctx: inout SlideCtx, _ blocks: inout [AnyTypBlock]
    ) throws {
        if let tbl = frame.firstDescendant(XmlNS.a, "tbl") {
            try parseTable(tbl, &ctx, &blocks)
            return
        }
        // Embedded OLE objects: retain identity, media type, and payload.
        if let ole = frame.firstDescendant(XmlNS.p, "oleObj") {
            let progId = ole.attr(XmlNS.p, "progId") ?? "object"
            let name = ole.attr(XmlNS.p, "name")?.trimmingCharacters(in: .whitespaces) ?? ""
            let alt = name.isEmpty ? "Embedded object: \(progId)" : name
            let source: AnyTypImageSource?
            if let rid = ole.attrQualified(XmlNS.r, "id"),
               let (part, bytes) = try ctx.relPart(rid) {
                source = try .asset(ctx.assets.add(
                    mediaType: "application/vnd.ms-ole-object",
                    originPart: part, bytes: [UInt8](bytes)))
            } else {
                source = nil
            }
            blocks.append(.paragraph([.image(alt: alt, source: source ?? .unavailable)]))
            return
        }
        if let chartRef = frame.firstDescendant(XmlNS.chart, "chart"),
           let rid = chartRef.attrQualified(XmlNS.r, "id"),
           let (part, bytes) = try ctx.relPart(rid) {
            do {
                let root = try parseXML([UInt8](bytes))
                blocks.append(contentsOf: DrawingML.chartBlocks(root))
            } catch let e as ConvertError {
                if e.isFatal { throw e }
                AnyTypLog.warn("skipping corrupt chart part \(part): \(e)")
            } catch {
                AnyTypLog.warn("skipping corrupt chart part \(part): \(error)")
            }
            return
        }
        if let relIds = frame.firstDescendant(XmlNS.dgm, "relIds"),
           let rid = relIds.attrQualified(XmlNS.r, "dm"),
           let (part, bytes) = try ctx.relPart(rid) {
            do {
                let root = try parseXML([UInt8](bytes))
                blocks.append(contentsOf: DrawingML.diagramBlocks(root))
            } catch let e as ConvertError {
                if e.isFatal { throw e }
                AnyTypLog.warn("skipping corrupt diagram part \(part): \(e)")
            } catch {
                AnyTypLog.warn("skipping corrupt diagram part \(part): \(error)")
            }
        }
    }

    /// DrawingML slide table: origins carry `gridSpan`/`rowSpan`; merged
    /// continuation cells (`hMerge`/`vMerge`) consume covered positions.
    private static func parseTable(
        _ tbl: XmlElement, _ ctx: inout SlideCtx, _ blocks: inout [AnyTypBlock]
    ) throws {
        let firstRow = tbl.find(XmlNS.a, "tblPr")
            .flatMap { $0.attr(XmlNS.a, "firstRow") }
            .map { ["1", "true"].contains($0) } ?? false
        let headerRows = firstRow ? 1 : 0
        let builder = GridBuilder()
        for tr in tbl.findAll(XmlNS.a, "tr") {
            builder.nextRow()
            for tc in tr.findAll(XmlNS.a, "tc") {
                let merged = ["1", "true"].contains(tc.attr(XmlNS.a, "hMerge") ?? "")
                    || ["1", "true"].contains(tc.attr(XmlNS.a, "vMerge") ?? "")
                if merged {
                    _ = builder.covered()
                    continue
                }
                let colSpan = max(tc.attr(XmlNS.a, "gridSpan").flatMap(Int.init) ?? 1, 1)
                let rowSpan = max(tc.attr(XmlNS.a, "rowSpan").flatMap(Int.init) ?? 1, 1)
                var cellBlocks: [AnyTypBlock] = []
                if let tx = tc.find(XmlNS.a, "txBody") {
                    try parseTextBody(tx, &ctx, nil, &cellBlocks)
                }
                try builder.place(.spanning(cellBlocks, colSpan: colSpan, rowSpan: rowSpan))
            }
        }
        var table = builder.finish(kind: .data)
        if table.grid.isEmpty { return }
        table.headerRows = HeaderDetect.resolve(table, declared: headerRows)
        blocks.append(.table(table))
    }
}
