import Foundation

/// Block and inline walking for ODF text content (port of `odf/text.rs`).

/// Shared parse context: styles, package, assets, collected notes, and the
/// continuation counters that make `text:continue-*` attributes resolve.
final class OdfCtx {
    let styles: OdfStyles
    let pkg: Package
    let assets: AssetSink
    var notes: [AnyTypNote] = []
    /// Continuation counters per (list style, depth): the next number a
    /// `text:continue-numbering` list resumes at.
    var listCounters: [String: UInt64] = [:]
    /// Next number per list `xml:id`, resolved by `text:continue-list`.
    var listIds: [String: UInt64] = [:]
    /// Heading numbering state for `text:outline-style` (values, started).
    var headingValues = [UInt64](repeating: 0, count: OdfStyles.listLevels)
    var headingStarted = [Bool](repeating: false, count: OdfStyles.listLevels)

    init(styles: OdfStyles, pkg: Package, assets: AssetSink) {
        self.styles = styles
        self.pkg = pkg
        self.assets = assets
    }
}

enum OdfText {
    static func parseContainer(_ parent: XmlElement, _ ctx: OdfCtx) throws -> [AnyTypBlock] {
        var blocks: [AnyTypBlock] = []
        var run = StyledRun.empty
        for child in parent.childElems {
            try parseBlockElem(child, ctx: ctx, blocks: &blocks, run: &run)
        }
        run.flush(&blocks)
        return blocks
    }

    private static func parseBlockElem(
        _ elem: XmlElement, ctx: OdfCtx,
        blocks: inout [AnyTypBlock], run: inout StyledRun
    ) throws {
        let inText = elem.ns == XmlNS.text
        if inText {
            // Only a run of same-styled paragraphs continues a container.
            if !elem.is(XmlNS.text, "p") {
                run.flush(&blocks)
            }
            switch elem.local {
            case "h":
                let level = min(
                    Int(elem.attr(XmlNS.text, "outline-level").flatMap(Int.init) ?? 1), 6)
                let (inlines, boxes) = try parseInlineContent(elem, ctx: ctx)
                if !inlinesAreEmpty(inlines) {
                    var content = inlines
                    rebaseEmphasis(
                        &content, base: try paragraphBase(elem, ctx: ctx).resolve())
                    // ODF outline links target headings by their text;
                    // carry it as the heading's anchor id (without the
                    // number).
                    let anchor = inlinesToPlainText(content)
                    if let label = headingLabel(elem, level: level, ctx: ctx) {
                        content.insert(.text(label, style: .plain), at: 0)
                    }
                    blocks.append(.heading(level: level, anchor: anchor, content: content))
                }
                blocks.append(contentsOf: boxes)
                return
            case "p":
                let (inlines, boxes) = try parseInlineContent(elem, ctx: ctx)
                let style = elem.attr(XmlNS.text, "style-name")
                    .flatMap { ctx.styles.blockStyle($0) }
                if let style {
                    run.push(style, inlines, &blocks)
                } else {
                    run.flush(&blocks)
                    blocks.append(.paragraph(inlines))
                }
                if !boxes.isEmpty {
                    // A frame is not part of the container's text.
                    run.flush(&blocks)
                    blocks.append(contentsOf: boxes)
                }
                return
            case "list":
                blocks.append(contentsOf: try parseList(
                    elem, ctx: ctx, depth: 0, inheritedStyle: nil, ancestors: []))
                return
            case "section", "index-body", "index-title",
                 "table-of-content", "alphabetical-index", "bibliography",
                 "illustration-index":
                // The stored index body is real document text (the
                // generated entries are written into `text:index-body`).
                blocks.append(contentsOf: try parseContainer(elem, ctx))
                return
            default:
                return
            }
        }
        if elem.is(XmlNS.table, "table") {
            run.flush(&blocks)
            blocks.append(contentsOf: try OdfTable.parseTable(elem, ctx))
        }
    }

    /// One `text:list` -> blocks: list headers render without markers (as
    /// plain blocks alongside the list), and every `text:start-value`
    /// restart after the first item splits the run into a new list with
    /// that start. `ancestors` carries the enclosing levels' current
    /// numbers so composite labels (`text:display-levels` > 1) render the
    /// full chain.
    private static func parseList(
        _ elem: XmlElement, ctx: OdfCtx, depth: Int,
        inheritedStyle: String?, ancestors: [UInt64]
    ) throws -> [AnyTypBlock] {
        let styleName = elem.attr(XmlNS.text, "style-name") ?? inheritedStyle
        let level = ctx.styles.listLevel(styleName ?? "", depth: depth)
        let ordered = level.marker.ordered

        let counterKey = "\(styleName ?? "")\u{0}\(depth)"
        var start = level.start
        if ordered {
            // Continuation identity: an explicit target list
            // (`continue-list` by xml:id) wins over the style-scoped
            // `continue-numbering`.
            if let target = elem.attr(XmlNS.text, "continue-list") {
                // (resolved below against listIds once populated — see
                // continueList handling)
                if let resume = ctx.listIds[target] {
                    start = resume
                }
            } else if elem.attr(XmlNS.text, "continue-numbering") == "true",
                      let resume = ctx.listCounters[counterKey] {
                start = resume
            }
        }

        var out: [AnyTypBlock] = []
        let currentMarker = level.marker
        var currentStart = start
        var currentItems: [AnyTypListItem] = []
        var next = start
        var firstItem = true

        func flush(_ newStart: UInt64) {
            if !currentItems.isEmpty {
                out.append(.list(.init(
                    marker: currentMarker, start: currentStart, items: currentItems)))
            }
            currentItems = []
            currentStart = newStart
        }

        for item in elem.childElems {
            let header = item.is(XmlNS.text, "list-header")
            if !(header || item.is(XmlNS.text, "list-item")) { continue }
            // Establish this item's number before walking children:
            // nested lists render composite labels against the ancestor
            // chain.
            if !header && ordered,
               let sv = item.attr(XmlNS.text, "start-value").flatMap(odfParseStart) {
                if firstItem {
                    currentStart = sv
                } else {
                    flush(sv)
                }
            }
            let number = currentStart &+ UInt64(currentItems.count)
            var chain = ancestors
            chain.append(number)
            var itemBlocks: [AnyTypBlock] = []
            var itemRun = StyledRun.empty
            for child in item.childElems {
                if child.is(XmlNS.text, "list") {
                    itemRun.flush(&itemBlocks)
                    itemBlocks.append(contentsOf: try parseList(
                        child, ctx: ctx, depth: depth + 1,
                        inheritedStyle: styleName, ancestors: chain))
                } else {
                    try parseBlockElem(
                        child, ctx: ctx, blocks: &itemBlocks, run: &itemRun)
                }
            }
            itemRun.flush(&itemBlocks)
            if header {
                // A list header has no marker: its blocks sit next to the
                // list and do not consume a number.
                flush(next)
                out.append(contentsOf: itemBlocks)
                continue
            }
            firstItem = false
            let label = itemLabel(ctx, styleName: styleName, depth: depth, chain: chain)
            currentItems.append(.init(blocks: itemBlocks, markerLabel: label))
            next = currentStart &+ UInt64(currentItems.count)
        }
        flush(next)
        if ordered && !out.isEmpty {
            ctx.listCounters[counterKey] = next
            if let id = elem.attrQualified(XmlNS.xml, "id") {
                ctx.listIds[id] = next
            }
        }
        return out
    }

    /// A list item's composite marker label (`num-prefix`/`num-suffix`/
    /// `display-levels`); `nil` when the default `n.` label is faithful.
    private static func itemLabel(
        _ ctx: OdfCtx, styleName: String?, depth: Int, chain: [UInt64]
    ) -> String? {
        guard let styleName, let levels = ctx.styles.listLevels(styleName) else {
            return nil
        }
        let depth = min(depth, OdfStyles.listLevels - 1)
        let lvl = levels[depth]
        if !lvl.marker.ordered { return nil }
        return compositeLabel(
            lvl.pattern(depth),
            ownMarker: lvl.marker,
            ownValue: chain.last ?? 1,
            levelMarker: { levels[min($0, OdfStyles.listLevels - 1)].marker },
            levelValue: { l in
                chain[safe: l] ?? levels[min(l, OdfStyles.listLevels - 1)].start
            })
    }

    /// ODF heading numbering: the `text:outline-style` level formats with
    /// the heading's `restart-numbering`/`start-value`/`is-list-header`
    /// controls. Advances the outline sequence; `nil` for unnumbered
    /// headings.
    private static func headingLabel(
        _ elem: XmlElement, level: Int, ctx: OdfCtx
    ) -> String? {
        guard let levels = ctx.styles.outlineLevels() else { return nil }
        let idx = min(max(level, 1) - 1, OdfStyles.listLevels - 1)
        let lvl = levels[idx]
        if !lvl.marker.ordered { return nil }
        // An unnumbered heading displays no number and consumes none.
        if elem.attr(XmlNS.text, "is-list-header") == "true" { return nil }
        let restart = elem.attr(XmlNS.text, "restart-numbering") == "true"
        let explicit = elem.attr(XmlNS.text, "start-value").flatMap(odfParseStart)
        let value: UInt64
        if let explicit {
            value = explicit
        } else if ctx.headingStarted[idx] && !restart {
            value = ctx.headingValues[idx] &+ 1
        } else {
            value = lvl.start
        }
        ctx.headingValues[idx] = value
        ctx.headingStarted[idx] = true
        for i in (idx + 1)..<OdfStyles.listLevels { ctx.headingStarted[i] = false }
        let label = compositeLabel(
            lvl.pattern(idx),
            ownMarker: lvl.marker,
            ownValue: value,
            levelMarker: { levels[min($0, OdfStyles.listLevels - 1)].marker },
            levelValue: { l in
                let l = min(l, OdfStyles.listLevels - 1)
                return ctx.headingStarted[l] ? ctx.headingValues[l] : levels[l].start
            })
        // Headings have no native numbering in the output, so the default
        // label is rendered too.
        return "\(label ?? lvl.marker.label(value)) "
    }

    /// Inline content of a paragraph plus block attachments (text boxes)
    /// that were anchored in it.
    private static func parseInlineContent(
        _ elem: XmlElement, ctx: OdfCtx
    ) throws -> ([AnyTypInline], [AnyTypBlock]) {
        let base = try paragraphBase(elem, ctx: ctx)
        var out: [AnyTypInline] = []
        var boxes: [AnyTypBlock] = []
        try walkInlines(elem, ctx: ctx, delta: base, out: &out, boxes: &boxes)
        return (out, boxes)
    }

    /// The style a paragraph's runs cascade from. An unstyled paragraph
    /// still sits on the family's default style.
    private static func paragraphBase(_ elem: XmlElement, ctx: OdfCtx) throws -> StyleDelta {
        try ctx.styles.delta(
            "paragraph", elem.attr(XmlNS.text, "style-name") ?? "")
    }

    private static func walkInlines(
        _ elem: XmlElement, ctx: OdfCtx, delta: StyleDelta,
        out: inout [AnyTypInline], boxes: inout [AnyTypBlock]
    ) throws {
        let style = delta.resolve()
        for node in elem.children {
            switch node {
            case .text(let t):
                let text = SharedText.collapseWS(SharedText.clean(t))
                if !text.isEmpty {
                    out.append(.text(text, style: style))
                }
            case .element(let child):
                let inText = child.ns == XmlNS.text
                if inText {
                    switch child.local {
                    case "span":
                        let merged: StyleDelta
                        if let name = child.attr(XmlNS.text, "style-name") {
                            merged = delta.merge(try ctx.styles.delta("text", name))
                        } else {
                            merged = delta
                        }
                        try walkInlines(
                            child, ctx: ctx, delta: merged, out: &out, boxes: &boxes)
                        continue
                    case "a":
                        let href = child.attr(XmlNS.xlink, "href") ?? ""
                        var content: [AnyTypInline] = []
                        try walkInlines(
                            child, ctx: ctx, delta: delta, out: &content, boxes: &boxes)
                        if let target = classifyHref(href),
                           !inlinesAreEmpty(content) {
                            out.append(.link(content: content, target: target))
                        } else {
                            out.append(contentsOf: content)
                        }
                        continue
                    case "s":
                        let n = min(
                            child.attr(XmlNS.text, "c").flatMap(Int.init) ?? 1, 20)
                        out.append(.text(
                            String(repeating: " ", count: n), style: .plain))
                        continue
                    case "tab":
                        out.append(.text(" ", style: .plain))
                        continue
                    case "line-break":
                        out.append(.lineBreak)
                        continue
                    case "bookmark", "bookmark-start":
                        if let name = child.attr(XmlNS.text, "name") {
                            out.append(.anchor(name))
                        }
                        continue
                    case "note":
                        let idx = ctx.notes.count
                        let id = child.attr(XmlNS.text, "id") ?? "odt\(idx)"
                        let kind: AnyTypNoteKind =
                            child.attr(XmlNS.text, "note-class") == "endnote"
                            ? .endnote : .footnote
                        let noteBlocks = try child.find(XmlNS.text, "note-body")
                            .map { try parseContainer($0, ctx) } ?? []
                        ctx.notes.append(.init(id: id, kind: kind, blocks: noteBlocks))
                        out.append(.noteRef(id))
                        continue
                    case "annotation", "tracked-changes", "soft-page-break":
                        continue
                    default:
                        break
                    }
                }
                if child.is(XmlNS.draw, "frame") {
                    try walkFrame(child, ctx: ctx, out: &out, boxes: &boxes)
                    continue
                }
                try walkInlines(child, ctx: ctx, delta: delta, out: &out, boxes: &boxes)
            }
        }
    }

    /// A draw:frame inline in text: an image (resolved into the asset
    /// store) or a text box (attached as blocks after the paragraph).
    static func walkFrame(
        _ frame: XmlElement, ctx: OdfCtx,
        out: inout [AnyTypInline], boxes: inout [AnyTypBlock]
    ) throws {
        if let textBox = frame.find(XmlNS.draw, "text-box") {
            boxes.append(contentsOf: try parseContainer(textBox, ctx))
            return
        }
        if let object = frame.find(XmlNS.draw, "object"),
           let tex = try formulaTex(ctx, object: object) {
            out.append(.math(tex))
            return
        }
        var altText = frame.firstDescendant(XmlNS.svgCompat, "title")?.text
            ?? frame.firstDescendant(XmlNS.svgCompat, "desc")?.text ?? ""
        altText = SharedText.clean(altText.trimmingCharacters(in: .whitespaces))
        if let image = frame.firstDescendant(XmlNS.draw, "image") {
            let href = image.attr(XmlNS.xlink, "href") ?? ""
            let source = try loadImage(ctx, href: href)
            if source != nil || !altText.isEmpty {
                out.append(.image(
                    alt: altText, source: source ?? .unavailable))
            }
            return
        }
        if !altText.isEmpty {
            out.append(.image(alt: altText, source: .unavailable))
        }
    }

    /// The LaTeX of a `draw:object` holding a formula: MathML inline in
    /// the object, or in the `content.xml` of the object directory it
    /// links to. `nil` for any other embedded object.
    static func formulaTex(_ ctx: OdfCtx, object: XmlElement) throws -> String? {
        if let math = object.find(XmlNS.mathML, "math") {
            let t = MathML.toTex(math)
            return t.isEmpty ? nil : t
        }
        let href = object.attr(XmlNS.xlink, "href") ?? ""
        if href.isEmpty || isAbsoluteURI(href) { return nil }
        guard let target = try? resolvePackageTarget(
            "content.xml", "\(href)/content.xml") else {
            AnyTypLog.warn("skipping unresolvable object reference \(href)")
            return nil
        }
        guard let tree = try ctx.pkg.optionalXMLPart(target.path),
              let math = tree.firstDescendant(XmlNS.mathML, "math") else {
            return nil
        }
        let t = MathML.toTex(math)
        return t.isEmpty ? nil : t
    }

    /// A cell's blocks: its text content, or a typed value-attribute
    /// fallback when the producer wrote no display text.
    static func cellBlocks(_ cell: XmlElement, ctx: OdfCtx) throws -> [AnyTypBlock] {
        let blocks = try parseContainer(cell, ctx)
        let hasContent = blocks.contains { b in
            if case .paragraph(let inlines) = b {
                return !inlinesAreEmpty(inlines)
            }
            return true
        }
        if hasContent { return blocks }
        if let text = valueText(cell) {
            return [.paragraph([.text(text, style: .plain)])]
        }
        return []
    }

    private static func valueText(_ cell: XmlElement) -> String? {
        guard let valueType = cell.attr(XmlNS.office, "value-type") else {
            return nil
        }
        switch valueType {
        case "percentage":
            guard let v = cell.attr(XmlNS.office, "value").flatMap(Double.init) else {
                return nil
            }
            return "\(trimFloat(v * 100))%"
        case "currency":
            guard let raw = cell.attr(XmlNS.office, "value"),
                  let v = Double(raw) else { return nil }
            let cur = cell.attr(XmlNS.office, "currency") ?? ""
            return cur.isEmpty ? trimFloat(v) : "\(trimFloat(v)) \(cur)"
        case "float":
            return cell.attr(XmlNS.office, "value").flatMap(Double.init).map(trimFloat)
        case "date":
            return cell.attr(XmlNS.office, "date-value")
        case "time":
            return cell.attr(XmlNS.office, "time-value").map(durationText)
        case "boolean":
            return cell.attr(XmlNS.office, "boolean-value").map {
                $0 == "true" ? "TRUE" : "FALSE"
            }
        case "string":
            return cell.attr(XmlNS.office, "string-value")
        default:
            return nil
        }
    }

    /// Shortest round-trip float formatting — no fixed-precision rounding.
    private static func trimFloat(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(v)
    }

    /// Full ISO 8601 duration -> clock text: `P1DT2H` -> `26:00:00`,
    /// `PT26H30M15S` -> `26:30:15`, weeks are 7 days, and fractional values
    /// are valid on any component (`PT1.5H` -> `1:30:00`). Year/month
    /// components have no fixed length, and unrepresentably large values
    /// overflow the clock format, so both keep their raw ISO text.
    private static func durationText(_ iso: String) -> String {
        var total = 0.0 // seconds
        var number = ""
        var inTime = false
        var negative = false
        for c in iso {
            if c == "-" && total == 0.0 && number.isEmpty {
                negative = true
            } else if c == "P" {
                // designator
            } else if c == "T" {
                inTime = true
                number = ""
            } else if (c == "Y" || c == "M") && !inTime {
                if let n = Double(number), n != 0.0 { return iso }
                number = ""
            } else if (c == "W" || c == "D") && !inTime {
                let unit = c == "W" ? 604_800.0 : 86_400.0
                total += (Double(number) ?? 0.0) * unit
                number = ""
            } else if (c == "H" || c == "M" || c == "S") && inTime {
                let unit: Double
                if c == "H" { unit = 3600.0 }
                else if c == "M" { unit = 60.0 }
                else { unit = 1.0 }
                total += (Double(number) ?? 0.0) * unit
                number = ""
            } else if c.isNumber || c == "." {
                number.append(c)
            } else {
                number = ""
            }
        }
        // Round to milliseconds; a value the clock format cannot
        // represent exactly keeps its source text instead of silently
        // degrading.
        let totalMsRounded = (total * 1000.0).rounded()
        if !(0.0..<1e18).contains(totalMsRounded) { return iso }
        let totalMs = UInt64(totalMsRounded)
        let sign = negative ? "-" : ""
        let hours = totalMs / 3_600_000
        let rest = totalMs % 3_600_000
        let minutes = rest / 60_000
        let ms = rest % 60_000
        if ms % 1000 != 0 {
            return String(
                format: "%@%llu:%02llu:%06.3f", sign, hours, minutes,
                Double(ms) / 1000.0)
        }
        return String(format: "%@%llu:%02llu:%02llu", sign, hours, minutes, ms / 1000)
    }

    /// Failures degrade (log + `nil`) per the unified policy;
    /// resource-limit errors always propagate.
    private static func loadImage(_ ctx: OdfCtx, href: String) throws -> AnyTypImageSource? {
        if href.isEmpty { return nil }
        if isAbsoluteURI(href) { return .external(href) }
        guard let target = try? resolvePackageTarget("content.xml", href) else {
            AnyTypLog.warn("skipping unresolvable image reference \(href)")
            return nil
        }
        guard let data = try ctx.pkg.optionalPart(target.path) else {
            AnyTypLog.warn("image part \(target.path) is missing")
            return nil
        }
        let id = try ctx.assets.add(
            mediaType: mediaTypeFor(target.path),
            originPart: target.path, bytes: [UInt8](data))
        return .asset(id)
    }

    /// ODF hrefs: external URLs, package-relative paths, or `#target`
    /// internal references (with `|outline`-style suffixes on generated
    /// links).
    private static func classifyHref(_ href: String) -> AnyTypLinkTarget? {
        if href.isEmpty { return nil }
        if href.hasPrefix("#") {
            let fragment = String(href.dropFirst())
            let target = fragment.split(separator: "|", maxSplits: 1).first
                .map(String.init) ?? fragment
            if target.isEmpty { return nil }
            return .anchor(decodeFragment(target))
        }
        return isAbsoluteURI(href) ? .external(href) : .relative(href)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
