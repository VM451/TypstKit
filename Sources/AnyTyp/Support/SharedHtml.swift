import Foundation

/// (X)HTML element tree -> model blocks (port of `shared/html.rs`). Used by
/// the HTML and EPUB frontends. Applies a deliberately small CSS subset.

/// Frontend hooks: how hrefs, image sources, and anchor ids resolve in the
/// containing document.
protocol HtmlCtx {
    func linkTarget(_ href: String) -> AnyTypLinkTarget?
    /// A failed load degrades to `nil`; resource-limit errors propagate.
    func imageSource(_ src: String) throws -> AnyTypImageSource?
    func anchorId(_ raw: String) -> String
}

func htmlToBlocks(_ body: XmlElement, css: Stylesheet, ctx: HtmlCtx) throws -> [AnyTypBlock] {
    let builder = HtmlBuilder(blocks: [], inlines: [], css: css, ctx: ctx, startBoundary: true)
    try builder.walkChildren(body, delta: StyleDelta())
    return builder.finish()
}

// MARK: - Minimal CSS

struct StyleProps {
    var delta = StyleDelta()
    /// `display` visibility as a tri-state.
    var hidden: Bool? = nil

    func merge(_ over: StyleProps) -> StyleProps {
        StyleProps(delta: delta.merge(over.delta), hidden: over.hidden ?? hidden)
    }

    var isDefault: Bool {
        delta == StyleDelta() && hidden == nil
    }
}

/// Cascade priority tiers.
private let inlinePriority: UInt32 = 100_000
private let importantPriority: UInt32 = 1_000_000

private struct CssRule {
    var tag: String?
    var `class`: String?
    var priority: UInt32
    var props: StyleProps
}

final class Stylesheet {
    private var rules: [CssRule] = []

    /// Add rules from one stylesheet's text.
    func add(_ css: String) {
        let css = stripCSSComments(css)
        for chunk in css.split(separator: "}", omittingEmptySubsequences: false) {
            guard let braceIdx = chunk.firstIndex(of: "{") else { continue }
            let selectors = String(chunk[..<braceIdx])
            let body = String(chunk[chunk.index(after: braceIdx)...])
            let decls = parseDeclarations(body)
            if decls.normal.isDefault && decls.important.isDefault { continue }
            for selector in selectors.split(separator: ",") {
                let s = selector.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.contains(" ") || s.contains(":") || s.contains("[") { continue }
                let (tag, cls): (String?, String?)
                if let dot = s.firstIndex(of: ".") {
                    let t = String(s[..<dot])
                    let c = String(s[s.index(after: dot)...])
                    tag = t.isEmpty ? nil : t.lowercased()
                    cls = c
                } else {
                    tag = s.lowercased()
                    cls = nil
                }
                let specificity = UInt32(cls != nil ? 10 : 0) + UInt32(tag != nil ? 1 : 0)
                for (props, base) in [(decls.normal, UInt32(0)), (decls.important, importantPriority)] {
                    if !props.isDefault {
                        rules.append(CssRule(tag: tag, class: cls, priority: base + specificity, props: props))
                    }
                }
            }
        }
    }

    /// Matching rules for one element as (priority, props) pairs.
    func matchingRules(_ tag: String, classes: [String]) -> [(UInt32, StyleProps)] {
        rules.compactMap { rule in
            if let t = rule.tag, t != tag { return nil }
            if let c = rule.class, !classes.contains(c) { return nil }
            return (rule.priority, rule.props)
        }
    }
}

private func stripCSSComments(_ css: String) -> String {
    var out = ""
    var rest = css[...]
    while let start = rest.range(of: "/*") {
        out += rest[..<start.lowerBound]
        let afterStart = rest[start.upperBound...]
        if let end = afterStart.range(of: "*/") {
            rest = afterStart[end.upperBound...]
        } else {
            return out
        }
    }
    out += rest
    return out
}

/// A declaration block's properties, split by cascade tier.
private struct DeclProps {
    var normal = StyleProps()
    var important = StyleProps()
}

/// The semantic subset of a declaration block.
private func parseDeclarations(_ body: String) -> DeclProps {
    var out = DeclProps()
    for decl in body.split(separator: ";") {
        guard let colon = decl.firstIndex(of: ":") else { continue }
        let name = decl[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        var value = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        var important = false
        if let bang = value.firstIndex(of: "!") {
            if value[value.index(after: bang)...].trimmingCharacters(in: .whitespaces) == "important" {
                important = true
            }
            value = String(value[..<bang])
            value = String(value.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        if important {
            applyDeclaration(name: name, value: value, to: &out.important)
        } else {
            applyDeclaration(name: name, value: value, to: &out.normal)
        }
    }
    return out
}

/// Apply one declaration to a cascade tier's props.
private func applyDeclaration(name: String, value: String, to props: inout StyleProps) {
    switch name {
    case "font-weight":
        props.delta.bold = value == "bold" || value == "bolder"
            || Int(value).map { $0 >= 600 } ?? false
    case "font-style":
        props.delta.italic = value == "italic" || value == "oblique"
    case "text-decoration", "text-decoration-line":
        if value == "none" {
            props.delta.strike = false
            props.delta.underline = false
        } else {
            if value.contains("line-through") { props.delta.strike = true }
            if value.contains("underline") { props.delta.underline = true }
        }
    case "vertical-align":
        switch value {
        case "super":
            props.delta.superscript = true
            props.delta.subscriptText = false
        case "sub":
            props.delta.superscript = false
            props.delta.subscriptText = true
        case "baseline":
            props.delta.superscript = false
            props.delta.subscriptText = false
        default: break
        }
    case "display":
        props.hidden = value == "none"
    default: break
    }
}

// MARK: - Walking

/// Content worth keeping: visible text, or an anchor node some link may
/// target.
private func keepsParagraph(_ inlines: [AnyTypInline]) -> Bool {
    !inlinesAreEmpty(inlines) || inlines.contains { if case .anchor = $0 { return true }; return false }
}

/// Whether text appended after `inlines` sits at a whitespace boundary.
private func atSpaceBoundary(_ inlines: [AnyTypInline], start: Bool) -> Bool {
    for inline in inlines.reversed() {
        switch inline {
        case .anchor:
            continue
        case .text(let text, _):
            if text.isEmpty { continue }
            return text.last.map { $0.isWhitespace } ?? false
        case .lineBreak:
            return true
        case .link(let content, _):
            if inlinesAreEmpty(content) { continue }
            return atSpaceBoundary(content, start: false)
        case .image, .noteRef, .math, .checkbox:
            return false
        }
    }
    return start
}

private final class HtmlBuilder {
    var blocks: [AnyTypBlock]
    var inlines: [AnyTypInline]
    let css: Stylesheet
    let ctx: HtmlCtx
    /// Whether text appended while `inlines` is empty sits at a whitespace
    /// boundary.
    var startBoundary: Bool

    init(blocks: [AnyTypBlock], inlines: [AnyTypInline], css: Stylesheet, ctx: HtmlCtx, startBoundary: Bool) {
        self.blocks = blocks
        self.inlines = inlines
        self.css = css
        self.ctx = ctx
        self.startBoundary = startBoundary
    }

    func flushParagraph() {
        if !inlines.isEmpty {
            let taken = inlines
            inlines = []
            if keepsParagraph(taken) {
                blocks.append(.paragraph(taken))
            }
        }
        startBoundary = true
    }

    func finish() -> [AnyTypBlock] {
        flushParagraph()
        return blocks
    }

    /// Sub-walk in a fresh block context (list items, quotes, cells).
    func subBlocks(_ elem: XmlElement, delta: StyleDelta) throws -> [AnyTypBlock] {
        try subBlocksAt(elem, delta: delta, startBoundary: true)
    }

    /// Sub-walk starting at the given whitespace-boundary state.
    func subBlocksAt(_ elem: XmlElement, delta: StyleDelta, startBoundary: Bool) throws -> [AnyTypBlock] {
        let b = HtmlBuilder(blocks: [], inlines: [], css: css, ctx: ctx, startBoundary: startBoundary)
        try b.walkChildren(elem, delta: delta)
        return b.finish()
    }

    /// Element-level props: matching stylesheet rules and the inline `style`
    /// attribute merged in one cascade order.
    func elementProps(_ elem: XmlElement) -> StyleProps {
        let classes = elem.attrAny("class")?.split(whereSeparator: { $0.isWhitespace }).map(String.init) ?? []
        var entries = css.matchingRules(elem.local, classes: classes)
        if let style = elem.attrAny("style") {
            let decls = parseDeclarations(style)
            entries.append((inlinePriority, decls.normal))
            entries.append((importantPriority + inlinePriority, decls.important))
        }
        // Stable sort by priority: decorate with the source index.
        let indexed = entries.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }
        var props = StyleProps()
        for (_, entry) in indexed {
            props = props.merge(entry.1)
        }
        return props
    }

    func pushAnchor(_ elem: XmlElement) {
        if let id = elem.attrAny("id"), !id.isEmpty {
            inlines.append(.anchor(ctx.anchorId(id)))
        }
        if elem.local == "a", let name = elem.attrAny("name"), !name.isEmpty {
            inlines.append(.anchor(ctx.anchorId(name)))
        }
    }

    func walkChildren(_ elem: XmlElement, delta: StyleDelta) throws {
        for node in elem.children {
            switch node {
            case .text(let t): pushText(t, delta: delta)
            case .element(let e): try walkElem(e, delta: delta)
            }
        }
    }

    func pushText(_ text: String, delta: StyleDelta) {
        let collapsed = SharedText.collapseWS(SharedText.clean(text))
        if collapsed.isEmpty { return }
        let textOut: String
        if atSpaceBoundary(inlines, start: startBoundary) {
            textOut = String(collapsed.drop(while: { $0 == " " }))
        } else {
            textOut = collapsed
        }
        if textOut.isEmpty { return }
        inlines.append(.text(textOut, style: delta.resolve()))
        startBoundary = false
    }

    func walkElem(_ elem: XmlElement, delta: StyleDelta) throws {
        let props = elementProps(elem)
        if props.hidden == true { return }
        // Cascade order: inherited delta, then the tag's presentational
        // default, then CSS.
        let delta = mergeInlineTag(elem, delta).merge(props.delta)
        switch elem.local {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flushParagraph()
            let level = Int(elem.local.dropFirst()) ?? 1
            var content = try inlineChildren(elem, delta: delta)
            // The heading element's own styling is how it looks, not markup.
            rebaseEmphasis(&content, base: delta.resolve())
            let anchor = elem.attrAny("id").map { ctx.anchorId($0) }
            if !inlinesAreEmpty(content) {
                blocks.append(.heading(level: level, anchor: anchor, content: content))
            } else {
                var kept: [AnyTypInline] = []
                if let anchor { kept.append(.anchor(anchor)) }
                kept.append(contentsOf: content.filter { if case .anchor = $0 { return true }; return false })
                if !kept.isEmpty {
                    blocks.append(.paragraph(kept))
                }
            }
        case "p":
            flushParagraph()
            pushAnchor(elem)
            var content = inlines
            inlines = []
            content.append(contentsOf: try inlineChildren(elem, delta: delta))
            if keepsParagraph(content) {
                blocks.append(.paragraph(content))
            }
        case "ul", "ol":
            flushParagraph()
            blocks.append(contentsOf: try parseList(elem, delta: delta))
        case "table":
            flushParagraph()
            if let caption = elem.childElems.first(where: { $0.local == "caption" }) {
                let content = try inlineChildren(caption, delta: delta)
                if keepsParagraph(content) {
                    blocks.append(.paragraph(content))
                }
            }
            if let t = try parseTable(elem, delta: delta) {
                blocks.append(t)
            }
        case "blockquote":
            flushParagraph()
            let inner = try subBlocks(elem, delta: delta)
            if !inner.isEmpty {
                blocks.append(.blockQuote(inner))
            }
        case "pre":
            flushParagraph()
            let text = elem.text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.codeBlock(lang: nil, text: text))
            }
        case "hr":
            flushParagraph()
            blocks.append(.rule)
        case "math":
            let tex = MathML.toTex(elem)
            if tex.isEmpty {
                // nothing
            } else if MathML.isDisplay(elem) {
                flushParagraph()
                blocks.append(.math(tex))
            } else {
                inlines.append(.math(tex))
                startBoundary = false
            }
        case "script", "style", "head", "template", "noscript":
            break
        default:
            if isContainerTag(elem.local) {
                pushAnchor(elem)
                if hasBlockChildren(elem) {
                    flushParagraph()
                    try walkChildren(elem, delta: delta)
                    flushParagraph()
                } else {
                    try walkChildren(elem, delta: delta)
                }
            } else {
                try walkInline(elem, delta: delta)
            }
        }
    }

    func walkInline(_ elem: XmlElement, delta: StyleDelta) throws {
        pushAnchor(elem)
        switch elem.local {
        case "br":
            inlines.append(.lineBreak)
            startBoundary = false
        case "img", "image":
            let alt = SharedText.clean(elem.attrAny("alt") ?? "")
            let src = elem.attrAny("src") ?? elem.attrAny("href") ?? ""
            let source = try ctx.imageSource(src)
            if source != nil || !alt.trimmingCharacters(in: .whitespaces).isEmpty {
                inlines.append(.image(alt: alt, source: source ?? .unavailable))
                startBoundary = false
            }
        case "a":
            let target = elem.attrAny("href").flatMap { ctx.linkTarget($0) }
            let content = try inlineChildrenAt(
                elem, delta: delta,
                startBoundary: atSpaceBoundary(inlines, start: startBoundary)
            )
            // An empty label still keeps a resolved target.
            if let target {
                inlines.append(.link(content: content, target: target))
            } else {
                inlines.append(contentsOf: content)
            }
            startBoundary = false
        default:
            try walkChildren(elem, delta: delta)
        }
    }

    func inlineChildren(_ elem: XmlElement, delta: StyleDelta) throws -> [AnyTypInline] {
        try inlineChildrenAt(elem, delta: delta, startBoundary: true)
    }

    /// Inline children starting at the given whitespace-boundary state.
    func inlineChildrenAt(_ elem: XmlElement, delta: StyleDelta, startBoundary: Bool) throws -> [AnyTypInline] {
        let blocks = try subBlocksAt(elem, delta: delta, startBoundary: startBoundary)
        if blocks.count == 1, case .paragraph(let inlines)? = blocks.first {
            return inlines
        }
        var out: [AnyTypInline] = []
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(.lineBreak) }
            switch block {
            case .paragraph(let inlines), .heading(_, _, let inlines):
                out.append(contentsOf: inlines)
            default:
                out.append(.text(SharedText.collapseWS(blockText(block)), style: .plain))
            }
        }
        return out
    }

    /// Ordered/unordered list with `start`, `reversed`, `type`, and per-item
    /// `value`.
    func parseList(_ elem: XmlElement, delta: StyleDelta) throws -> [AnyTypBlock] {
        let ordered = elem.local == "ol"
        let items = elem.childElems.filter { $0.local == "li" }
        if items.isEmpty { return [] }
        if !ordered {
            var listItems: [AnyTypListItem] = []
            for li in items {
                listItems.append(.init(blocks: try subBlocks(li, delta: delta)))
            }
            return [.list(.init(marker: .bullet, start: 1, items: listItems))]
        }
        let marker: AnyTypMarkerKind = switch elem.attrAny("type") {
        case "a": .lowerAlpha
        case "A": .upperAlpha
        case "i": .lowerRoman
        case "I": .upperRoman
        default: .decimal
        }
        let reversed = elem.attrAny("reversed") != nil
        let start = elem.attrAny("start").flatMap { Int64($0) }
            ?? (reversed ? Int64(items.count) : 1)
        var numbers: [Int64] = []
        var next = start
        for li in items {
            if let v = li.attrAny("value").flatMap({ Int64($0) }) {
                next = v
            }
            numbers.append(next)
            next = reversed ? next &- 1 : next &+ 1
        }
        // Zero/negative numbers cannot be a `start`; carry every number as an
        // explicit literal marker instead.
        if numbers.contains(where: { $0 < 1 }) {
            var listItems: [AnyTypListItem] = []
            for (li, n) in zip(items, numbers) {
                listItems.append(.init(blocks: try subBlocks(li, delta: delta),
                                       markerLabel: "\(n)."))
            }
            return [.list(.init(marker: marker, start: 1, items: listItems))]
        }
        var out: [AnyTypBlock] = []
        var currentItems: [AnyTypListItem] = []
        var currentStart: UInt64 = 0
        var lastNumber: Int64 = 0
        var inList = false
        for (li, number) in zip(items, numbers) {
            let item = AnyTypListItem(blocks: try subBlocks(li, delta: delta))
            let nextExpected = lastNumber < Int64.max ? lastNumber + 1 : nil
            let contiguous = inList && nextExpected == number
            if !contiguous {
                if inList {
                    out.append(.list(.init(marker: marker, start: currentStart, items: currentItems)))
                }
                currentItems = []
                currentStart = UInt64(max(0, number))
                inList = true
            }
            currentItems.append(item)
            lastNumber = number
        }
        if inList {
            out.append(.list(.init(marker: marker, start: currentStart, items: currentItems)))
        }
        return out
    }

    func parseTable(_ elem: XmlElement, delta: StyleDelta) throws -> AnyTypBlock? {
        // (row, is thead row, row-group index)
        var rowElems: [(XmlElement, Bool, Int)] = []
        var group = 0
        var inImplicitGroup = false
        for child in elem.childElems {
            switch child.local {
            case "thead", "tbody", "tfoot":
                if inImplicitGroup {
                    inImplicitGroup = false
                    group += 1
                }
                let inHead = child.local == "thead"
                for tr in child.childElems where tr.local == "tr" {
                    rowElems.append((tr, inHead, group))
                }
                group += 1
            case "tr":
                inImplicitGroup = true
                rowElems.append((child, false, group))
            default: break
            }
        }
        if rowElems.isEmpty { return nil }
        // Last row index of each group, for rowspan=0 expansion.
        var groupEnd: [Int: Int] = [:]
        for (i, (_, _, g)) in rowElems.enumerated() {
            groupEnd[g] = i
        }
        let builder = GridBuilder()
        var headerRows = 0
        for (i, (tr, inHead, grp)) in rowElems.enumerated() {
            builder.nextRow()
            var allTh = true
            var anyCell = false
            for cell in tr.childElems where ["td", "th"].contains(cell.local) {
                anyCell = true
                if cell.local != "th" { allTh = false }
                // HTML clamps colspan to 1000 and rowspan to 65534.
                let colSpan = min(1000, max(1, Int(cell.attrAny("colspan") ?? "") ?? 1))
                let rowSpan: Int
                if let rs = cell.attrAny("rowspan").flatMap({ Int($0) }) {
                    rowSpan = rs == 0 ? (groupEnd[grp]! - i + 1) : min(65534, max(1, rs))
                } else {
                    rowSpan = 1
                }
                let blocks = try subBlocks(cell, delta: delta)
                try builder.place(.spanning(blocks, colSpan: colSpan, rowSpan: rowSpan))
            }
            if i == headerRows && (inHead || (allTh && anyCell)) {
                headerRows += 1
            }
        }
        var table = builder.finish(kind: .data)
        if table.grid.isEmpty { return nil }
        table.headerRows = HeaderDetect.resolve(table, declared: headerRows)
        return .table(table)
    }
}

private func mergeInlineTag(_ elem: XmlElement, _ delta: StyleDelta) -> StyleDelta {
    var d = delta
    switch elem.local {
    case "b", "strong": d.bold = true
    case "i", "em", "cite", "dfn", "var": d.italic = true
    case "u", "ins": d.underline = true
    case "s", "del", "strike": d.strike = true
    case "sup":
        d.superscript = true
        d.subscriptText = false
    case "sub":
        d.subscriptText = true
        d.superscript = false
    case "code", "kbd", "samp", "tt": d.code = true
    default: break
    }
    return d
}

private func blockText(_ block: AnyTypBlock) -> String {
    switch block {
    case .paragraph(let i), .heading(_, _, let i):
        return inlinesToPlainText(i)
    case .list(let list):
        return list.items.flatMap { $0.blocks.map(blockText) }.joined(separator: " ")
    case .blockQuote(let blocks):
        return blocks.map(blockText).joined(separator: " ")
    case .codeBlock(_, let text), .math(let text):
        return text
    case .table(let table):
        return table.grid.flatMap { row in
            row.compactMap { slot -> String? in
                guard case .origin(let cell) = slot else { return nil }
                return cell.blocks.map(blockText).joined(separator: " ")
            }
        }.joined(separator: " ")
    case .rule:
        return ""
    }
}

/// Elements that only group other content, walked through transparently.
private func isContainerTag(_ name: String) -> Bool {
    ["div", "section", "article", "aside", "main", "nav", "header", "footer",
     "figure", "figcaption", "center", "details", "summary", "li", "dl", "dt",
     "dd", "body"].contains(name)
}

private func isBlockTag(_ name: String) -> Bool {
    isContainerTag(name) || ["p", "ul", "ol", "table", "blockquote", "pre", "hr",
                             "h1", "h2", "h3", "h4", "h5", "h6"].contains(name)
}

private func hasBlockChildren(_ elem: XmlElement) -> Bool {
    elem.childElems.contains { isBlockTag($0.local) }
}
