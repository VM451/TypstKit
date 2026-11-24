import Foundation

/// One grid row of slot references into the canonical table grid.
private enum SlotRef {
    case origin(AnyTypCell)
    case covered
    case padEmpty
}

private struct GridRow {
    var slots: [SlotRef]
}

/// Serialize a table to `#table(...)` / `#grid(...)`, preserving exact
/// `colspan`/`rowspan` via `table.cell(...)` / `grid.cell(...)`. Covered
/// shadow slots are omitted: Typst's grid engine advances past spanned
/// positions natively.
func renderTable(_ table: AnyTypTable, rc: RenderContext) -> String? {
    if table.grid.isEmpty { return nil }
    let rawWidth = table.grid.map(\.count).max() ?? 0
    if rawWidth == 0 { return nil }

    var rows: [GridRow] = table.grid.map { row in
        var slots: [SlotRef] = row.map { slot in
            switch slot {
            case .origin(let cell): return .origin(cell)
            case .covered: return .covered
            }
        }
        while slots.count < rawWidth { slots.append(.padEmpty) }
        return GridRow(slots: slots)
    }

    // Drop trailing rows that hold only empty cells (covered positions are
    // not empty and keep the row alive).
    while rows.count > 1,
          let last = rows.last,
          last.slots.allSatisfy({ slot in
              switch slot {
              case .origin(let c): return c.isEmpty
              case .padEmpty: return true
              case .covered: return false
              }
          }) {
        rows.removeLast()
    }

    // Effective width: last column holding content, a span, or a covered slot.
    let width = rows.map { row in
        (row.slots.lastIndex(where: { slot in
            switch slot {
            case .origin(let c): return !c.isEmpty || c.colSpan > 1 || c.rowSpan > 1
            case .covered: return true
            case .padEmpty: return false
            }
        }).map { $0 + 1 }) ?? 0
    }.max() ?? 0
    if width == 0 { return nil }

    let rowCount = rows.count
    let isLayout = table.kind == .layout
    let funcName = isLayout ? "grid" : "table"
    let cellFn = isLayout ? "grid.cell" : "table.cell"

    // Emit `table.header(...)` only on data tables when header rows exist,
    // at least one body row survives, and no header cell spans across the
    // header boundary.
    var headerRows = 0
    if !isLayout, table.headerRows > 0, table.headerRows <= rowCount {
        let crossesBoundary = rows[..<table.headerRows].enumerated().contains { (rIdx, row) in
            row.slots[..<width].contains { slot in
                guard case .origin(let c) = slot else { return false }
                let effRowSpan = max(c.rowSpan, 1)
                return rIdx + min(effRowSpan, rowCount - rIdx) > table.headerRows
            }
        }
        headerRows = crossesBoundary ? 0 : table.headerRows
    }

    var out = "#\(funcName)(\n  columns: \(width),\n"
    if isLayout {
        out += "  gutter: 0.65em,\n"
    }

    if headerRows > 0 {
        var headerCells: [String] = []
        for (rIdx, row) in rows[..<headerRows].enumerated() {
            collectRowCells(row, rIdx: rIdx, width: width, rowCount: rowCount,
                            cellFn: cellFn, rc: rc, out: &headerCells)
        }
        if !headerCells.isEmpty {
            out += "  table.header("
            if headerCells.contains(where: { $0.contains("\n") }) || headerCells.count > 6 {
                out += "\n"
                for cellStr in headerCells {
                    pushIndentedArg(&out, arg: cellStr, indent: "    ")
                }
                out += "  ),\n"
            } else {
                out += headerCells.joined(separator: ", ")
                out += "),\n"
            }
        }
    }

    for (offset, row) in rows[headerRows...].enumerated() {
        let rIdx = headerRows + offset
        var rowCells: [String] = []
        collectRowCells(row, rIdx: rIdx, width: width, rowCount: rowCount,
                        cellFn: cellFn, rc: rc, out: &rowCells)
        if rowCells.isEmpty { continue }
        if rowCells.contains(where: { $0.contains("\n") }) {
            for cellStr in rowCells {
                pushIndentedArg(&out, arg: cellStr, indent: "  ")
            }
        } else {
            out += "  " + rowCells.joined(separator: ", ") + ",\n"
        }
    }

    out += ")"
    return out
}

private func collectRowCells(
    _ row: GridRow,
    rIdx: Int,
    width: Int,
    rowCount: Int,
    cellFn: String,
    rc: RenderContext,
    out: inout [String]
) {
    for (cIdx, slot) in row.slots[..<width].enumerated() {
        switch slot {
        case .covered:
            continue
        case .padEmpty:
            out.append("[]")
        case .origin(let cell):
            let colSpan = min(max(cell.colSpan, 1), width - cIdx)
            let rowSpan = min(max(cell.rowSpan, 1), rowCount - rIdx)
            let body = renderBlocks(cell.blocks, rc: rc)
            let contentBlock = formatContentBlock(body)
            if colSpan > 1 || rowSpan > 1 {
                var args: [String] = []
                if colSpan > 1 { args.append("colspan: \(colSpan)") }
                if rowSpan > 1 { args.append("rowspan: \(rowSpan)") }
                out.append("\(cellFn)(\(args.joined(separator: ", ")))\(contentBlock)")
            } else {
                out.append(contentBlock)
            }
        }
    }
}

/// Wrap rendered cell body as a `[...]` Typst content block.
private func formatContentBlock(_ body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "[]"
    }
    if trimmed.contains("\n") {
        var s = "[\n"
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                s += "\n"
            } else {
                s += "  " + line + "\n"
            }
        }
        s += "]"
        return s
    }
    return "[\(trimmed)]"
}

/// Emit `arg` with `indent` on each non-empty line, trailing comma on the last.
private func pushIndentedArg(_ out: inout String, arg: String, indent: String) {
    let lines = arg.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, line) in lines.enumerated() {
        if line.isEmpty {
            out += "\n"
        } else {
            out += indent + line
            if i == lines.count - 1 { out += "," }
            out += "\n"
        }
    }
}
