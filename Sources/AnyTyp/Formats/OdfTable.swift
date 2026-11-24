import Foundation

/// ODF tables (port of `odf/table.rs`): canonical grid construction with
/// covered-cell consumption, repeats honored in every container, a hard
/// expansion budget for repeat expansion, and typed value-attribute
/// fallback for cells without display text.
///
/// Empty filler runs *inside* the used range materialize fully so every
/// later cell keeps its source coordinates; only trailing filler (empty
/// rows at the end, empty cells at a row's end) is elided. All
/// materialization is charged against the fixed expansion budget.
enum OdfTable {
    static func parseTable(_ elem: XmlElement, _ ctx: OdfCtx) throws -> [AnyTypBlock] {
        let state = TableState(checkboxes: readCheckboxes(elem))
        try walkRows(elem, ctx: ctx, state: state, top: true)
        var table = state.builder.finish(kind: .data)
        if table.grid.isEmpty { return [] }
        table.headerRows = HeaderDetect.resolve(table, declared: state.headerRows)
        return [.table(table)]
    }

    private final class TableState {
        let builder = GridBuilder()
        /// Grid slots produced by expansion, checked against the fixed
        /// budget.
        var expansion: UInt64 = 0
        /// Text bytes duplicated by expansion, checked against their own
        /// budget.
        var expansionBytes: UInt64 = 0
        var pendingRows: UInt64 = 0
        var headerRows = 0
        var rowsEmitted = 0
        /// The sheet's form checkboxes by control id, as the inlines a
        /// `draw:control` in a cell expands to.
        let checkboxes: [String: [AnyTypInline]]

        init(checkboxes: [String: [AnyTypInline]]) {
            self.checkboxes = checkboxes
        }

        func charge(_ cells: UInt64) throws {
            expansion = expansion &+ cells
            if expansion > Limits.maxExpansion {
                throw ConvertError.resourceLimit(
                    limit: "max_expansion",
                    detail: "table repeat expansion exceeds the content budget")
            }
        }

        /// Charge text bytes that repeat expansion duplicates: the slot
        /// budget bounds positions, this bounds the amplified content
        /// itself.
        func chargeBytes(_ bytes: UInt64) throws {
            expansionBytes = expansionBytes &+ bytes
            if expansionBytes > Limits.maxExpansionTextBytes {
                throw ConvertError.resourceLimit(
                    limit: "max_expansion_text_bytes",
                    detail: "table repeat expansion duplicates more text than the budget")
            }
        }
    }

    /// Checkbox controls declared in the table's `office:forms`. The mixed
    /// ("unknown") state has no token and is left out.
    private static func readCheckboxes(_ table: XmlElement) -> [String: [AnyTypInline]] {
        var out: [String: [AnyTypInline]] = [:]
        for forms in table.findAll(XmlNS.office, "forms") {
            for cb in forms.descendants(XmlNS.form, "checkbox") {
                guard let id = cb.attrQualified(XmlNS.xml, "id")
                    ?? cb.attr(XmlNS.form, "id") else { continue }
                let state = cb.attr(XmlNS.form, "current-state")
                    ?? cb.attr(XmlNS.form, "state")
                let checked: Bool
                switch state {
                case "checked": checked = true
                case "unchecked", nil: checked = false
                default: continue
                }
                var inlines: [AnyTypInline] = [.checkbox(checked)]
                let label = cb.attr(XmlNS.form, "label")
                    .map(SharedText.clean) ?? ""
                if !label.isEmpty {
                    inlines.append(.text(" \(label)", style: .plain))
                }
                out[id] = inlines
            }
        }
        return out
    }

    /// Append the checkboxes anchored in a cell after its content, on the
    /// same line. Controls under `table:shapes` are anchored to the page by
    /// coordinates alone, so they are not placed.
    private static func appendCellCheckboxes(
        _ cell: XmlElement, _ checkboxes: [String: [AnyTypInline]],
        _ blocks: inout [AnyTypBlock]
    ) {
        for control in cell.findAll(XmlNS.draw, "control") {
            guard let id = control.attr(XmlNS.draw, "control"),
                  let found = checkboxes[id] else { continue }
            if case .paragraph(var inlines) = blocks.last {
                inlines.append(.text(" ", style: .plain))
                inlines.append(contentsOf: found)
                blocks[blocks.count - 1] = .paragraph(inlines)
            } else {
                blocks.append(.paragraph(found))
            }
        }
    }

    /// One parsed cell of a row template, reused across row repeats.
    private enum RowCell {
        case covered(repeat: UInt64)
        case cell(repeat: UInt64, colSpan: Int, rowSpan: Int,
                  blocks: [AnyTypBlock], bytes: UInt64)
    }

    /// Approximate retained text bytes of parsed cell content.
    private static func blockBytes(_ blocks: [AnyTypBlock]) -> UInt64 {
        func inlineBytes(_ inlines: [AnyTypInline]) -> UInt64 {
            inlines.reduce(0) { acc, i in
                switch i {
                case .text(let t, _): return acc &+ UInt64(t.utf8.count)
                case .link(let content, let target):
                    let targetLen: UInt64
                    switch target {
                    case .external(let s), .relative(let s), .anchor(let s):
                        targetLen = UInt64(s.utf8.count)
                    }
                    return acc &+ inlineBytes(content) &+ targetLen
                case .image(let alt, _): return acc &+ UInt64(alt.utf8.count)
                case .math(let tex): return acc &+ UInt64(tex.utf8.count)
                case .anchor(let id), .noteRef(let id):
                    return acc &+ UInt64(id.utf8.count)
                case .checkbox: return acc &+ 3
                case .lineBreak: return acc &+ 1
                }
            }
        }
        return blocks.reduce(0) { acc, b in
            switch b {
            case .paragraph(let i), .heading(_, _, let i):
                return acc &+ inlineBytes(i)
            case .math(let tex): return acc &+ UInt64(tex.utf8.count)
            case .list(let list):
                return acc &+ list.items.reduce(0) {
                    $0 &+ blockBytes($1.blocks)
                }
            case .table(let t):
                return acc &+ t.grid.flatMap { $0 }.reduce(0) { a, slot in
                    if case .origin(let c) = slot { return a &+ blockBytes(c.blocks) }
                    return a
                }
            case .blockQuote(let blocks): return acc &+ blockBytes(blocks)
            case .codeBlock(_, let text): return acc &+ UInt64(text.utf8.count)
            case .rule: return acc
            }
        }
    }

    private static func walkRows(
        _ container: XmlElement, ctx: OdfCtx, state: TableState, top: Bool
    ) throws {
        for child in container.childElems {
            guard child.ns == XmlNS.table else { continue }
            switch child.local {
            case "table-header-rows":
                let before = state.rowsEmitted
                try walkRows(child, ctx: ctx, state: state, top: false)
                if top && state.headerRows == 0 {
                    state.headerRows = state.rowsEmitted - before
                }
            case "table-rows", "table-row-group":
                try walkRows(child, ctx: ctx, state: state, top: false)
            case "table-row":
                let repeatCount = max(
                    UInt64(child.attr(XmlNS.table, "number-rows-repeated").flatMap(UInt64.init) ?? 1),
                    1)
                try emitRow(child, ctx: ctx, state: state, repeat: repeatCount)
            default: break
            }
        }
    }

    private static func emitRow(
        _ row: XmlElement, ctx: OdfCtx, state: TableState, repeat repeatCount: UInt64
    ) throws {
        if rowIsEmpty(row) {
            state.pendingRows = state.pendingRows &+ repeatCount
            return
        }
        // Materialize any buffered empty gap first, in full: rows after the
        // gap keep their source coordinates. The rows are charged so a
        // pathological gap hits the budget instead of memory.
        if state.pendingRows > 0 {
            try state.charge(state.pendingRows)
            for _ in 0..<state.pendingRows {
                state.builder.nextRow()
                state.rowsEmitted += 1
            }
            state.pendingRows = 0
        }
        // Parse the row template exactly once: repeated rows clone the
        // parsed cells instead of reparsing, so per-parse side effects
        // (notes, assets) happen once and the duplicated text bytes are
        // charged up front.
        let cells = try parseRowCells(row, ctx: ctx, checkboxes: state.checkboxes)
        try state.charge(repeatCount &- 1)
        for cell in cells {
            if case .cell(let cellRepeat, _, _, _, let bytes) = cell {
                let copies = repeatCount &* cellRepeat &- 1
                try state.chargeBytes(bytes &* copies)
            }
        }
        for _ in 0..<repeatCount {
            state.builder.nextRow()
            state.rowsEmitted += 1
            try emitParsedCells(cells, state: state)
        }
    }

    /// Parse one row's cells into the reusable template.
    private static func parseRowCells(
        _ row: XmlElement, ctx: OdfCtx, checkboxes: [String: [AnyTypInline]]
    ) throws -> [RowCell] {
        var out: [RowCell] = []
        for cell in row.childElems {
            let repeatCount = max(
                UInt64(cell.attr(XmlNS.table, "number-columns-repeated").flatMap(UInt64.init) ?? 1),
                1)
            if cell.is(XmlNS.table, "covered-table-cell") {
                out.append(.covered(repeat: repeatCount))
                continue
            }
            if !cell.is(XmlNS.table, "table-cell") { continue }
            let colSpan = max(
                cell.attr(XmlNS.table, "number-columns-spanned").flatMap(Int.init) ?? 1, 1)
            let rowSpan = max(
                cell.attr(XmlNS.table, "number-rows-spanned").flatMap(Int.init) ?? 1, 1)
            var blocks = try OdfText.cellBlocks(cell, ctx: ctx)
            appendCellCheckboxes(cell, checkboxes, &blocks)
            let bytes = blockBytes(blocks)
            out.append(.cell(
                repeat: repeatCount, colSpan: colSpan, rowSpan: rowSpan,
                blocks: blocks, bytes: bytes))
        }
        return out
    }

    private static func emitParsedCells(_ cells: [RowCell], state: TableState) throws {
        var pendingCells: UInt64 = 0
        for cell in cells {
            switch cell {
            case .covered(let repeatCount):
                try flushGap(state, pending: &pendingCells)
                // One explicitly written covered position each; a stray
                // one (no span accounts for it) becomes an empty cell
                // inside covered().
                try state.charge(repeatCount)
                for _ in 0..<repeatCount {
                    if !state.builder.covered() {
                        AnyTypLog.debug("covered table cell without a spanning origin")
                    }
                }
            case .cell(let repeatCount, let colSpan, let rowSpan, let blocks, _):
                if blocks.isEmpty && colSpan == 1 && rowSpan == 1 {
                    pendingCells = pendingCells &+ repeatCount
                    continue
                }
                try flushGap(state, pending: &pendingCells)
                try state.charge(repeatCount &* UInt64(colSpan))
                for _ in 0..<repeatCount {
                    try state.builder.place(
                        .spanning(blocks, colSpan: colSpan, rowSpan: rowSpan))
                }
            }
        }
    }

    /// Materialize a buffered empty-cell run in full so the next cell
    /// lands on its source column. Trailing runs are never flushed and
    /// stay elided.
    private static func flushGap(
        _ state: TableState, pending: inout UInt64
    ) throws {
        if pending == 0 { return }
        try state.charge(pending)
        for _ in 0..<pending {
            try state.builder.place(.init(blocks: []))
        }
        pending = 0
    }

    private static func rowIsEmpty(_ row: XmlElement) -> Bool {
        row.childElems.allSatisfy { cell in
            if cell.is(XmlNS.table, "covered-table-cell") {
                return false // structural: belongs to a span
            }
            if !cell.is(XmlNS.table, "table-cell") { return true }
            return cell.attr(XmlNS.table, "number-columns-spanned") == nil
                && cell.attr(XmlNS.table, "number-rows-spanned") == nil
                && cell.attr(XmlNS.office, "value-type") == nil
                && cell.children.isEmpty
        }
    }

    /// One sheet of a spreadsheet body.
    static func parseSpreadsheet(_ sheet: XmlElement, _ ctx: OdfCtx) throws -> [AnyTypBlock] {
        let tables = sheet.childElems.filter { $0.is(XmlNS.table, "table") }
        let multiSheet = tables.count > 1
        var blocks: [AnyTypBlock] = []
        for table in tables {
            let name = table.attr(XmlNS.table, "name") ?? ""
            let content = try parseTable(table, ctx)
            if content.isEmpty { continue }
            if multiSheet {
                blocks.append(.heading(level: 2, anchor: nil, content: [.text(name, style: .plain)]))
            }
            blocks.append(contentsOf: content)
        }
        return blocks
    }
}
