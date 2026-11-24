import Foundation

// MARK: - Inline helpers (port of model/inline.rs)

/// The Markdown task-list token for a checkbox state.
func checkboxText(_ checked: Bool) -> String {
    checked ? "[x]" : "[ ]"
}

/// Flatten inlines to their text, dropping styling and links but keeping link
/// text, image alt text, and formula source. Line breaks become newlines;
/// anchors and note references contribute nothing.
func inlinesToPlainText(_ inlines: [AnyTypInline]) -> String {
    var out = ""
    collectPlainText(inlines, into: &out)
    return out
}

private func collectPlainText(_ inlines: [AnyTypInline], into out: inout String) {
    for inline in inlines {
        switch inline {
        case .text(let text, _):
            out += text
        case .link(let content, _):
            collectPlainText(content, into: &out)
        case .image(let alt, _):
            out += alt
        case .math(let tex):
            out += tex
        case .checkbox(let checked):
            out += checkboxText(checked)
        case .anchor, .noteRef:
            break
        case .lineBreak:
            out.append("\n")
        }
    }
}

/// True when nothing here would render as visible content: only whitespace,
/// empty-target links, anchors, and line breaks. An image or a note reference
/// always counts as content.
func inlinesAreEmpty(_ inlines: [AnyTypInline]) -> Bool {
    inlines.allSatisfy { inline in
        switch inline {
        case .text(let text, _):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .link(let content, let target):
            return target.isEmpty && inlinesAreEmpty(content)
        case .image, .noteRef, .checkbox:
            return false
        case .math(let tex):
            return tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .anchor, .lineBreak:
            return true
        }
    }
}

// MARK: - Link target

extension AnyTypLinkTarget {
    /// True when the target string is empty, whichever kind it is.
    var isEmpty: Bool {
        switch self {
        case .external(let s), .relative(let s), .anchor(let s):
            return s.isEmpty
        }
    }
}

// MARK: - Marker kinds (port of model/list.rs numbering helpers)

extension AnyTypMarkerKind {
    /// True for every kind but `.bullet`.
    var ordered: Bool { self != .bullet }

    /// The marker text for ordinal `n` (1-based), without trailing space:
    /// `3.`, `c.`, `iv.`; bullets have no ordinal text.
    func label(_ n: UInt64) -> String {
        self == .bullet ? "-" : "\(ordinal(n))."
    }

    /// The bare ordinal text for `n` without punctuation: `3`, `c`, `iv`.
    func ordinal(_ n: UInt64) -> String {
        switch self {
        case .bullet: return "-"
        case .decimal: return "\(n)"
        case .lowerAlpha: return Self.alpha(n)
        case .upperAlpha: return Self.alpha(n).uppercased()
        case .lowerRoman: return Self.roman(n)
        case .upperRoman: return Self.roman(n).uppercased()
        }
    }

    /// 1 -> `a`, 26 -> `z`, 27 -> `aa` (bijective base 26).
    private static func alpha(_ n: UInt64) -> String {
        if n == 0 { return "0" }
        var n = n
        var out: [UInt8] = []
        while n > 0 {
            n -= 1
            out.append(UInt8(ascii: "a") + UInt8(n % 26))
            n /= 26
        }
        return String(decoding: out.reversed(), as: UTF8.self)
    }

    private static func roman(_ n: UInt64) -> String {
        if n == 0 || n > 3999 { return "\(n)" }
        let numerals: [(UInt64, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var n = n
        var out = ""
        for (value, numeral) in numerals {
            while n >= value {
                out += numeral
                n -= value
            }
        }
        return out
    }
}

// MARK: - Cells and tables

extension AnyTypCell {
    /// A cell spanning one position.
    static func single(_ blocks: [AnyTypBlock]) -> AnyTypCell {
        AnyTypCell(blocks: blocks, colSpan: 1, rowSpan: 1)
    }

    /// A one-paragraph cell spanning one position.
    static func fromInlines(_ inlines: [AnyTypInline]) -> AnyTypCell {
        single([.paragraph(inlines)])
    }

    /// A cell covering `colSpan` by `rowSpan` positions; either span given
    /// as <= 0 is raised to 1.
    static func spanning(_ blocks: [AnyTypBlock], colSpan: Int, rowSpan: Int) -> AnyTypCell {
        AnyTypCell(blocks: blocks, colSpan: max(1, colSpan), rowSpan: max(1, rowSpan))
    }

    /// True when the cell holds nothing that would render: only paragraphs
    /// count toward emptiness, so a cell with a table or list in it is not
    /// empty even if that content is blank.
    var isEmpty: Bool {
        blocks.allSatisfy { block in
            if case .paragraph(let inlines) = block {
                return inlinesAreEmpty(inlines)
            }
            return false
        }
    }
}

extension AnyTypTable {
    /// Build a plain span-less table from rows of cells (spreadsheets, CSV).
    static func fromRows(
        _ rows: [[AnyTypCell]],
        headerRows: Int = 0,
        kind: AnyTypTableKind = .data
    ) -> AnyTypTable {
        let builder = GridBuilder()
        for row in rows {
            builder.nextRow()
            for cell in row {
                // Span-less placement never charges the expansion budget.
                builder.placeUnchecked(AnyTypCell(
                    blocks: cell.blocks,
                    colSpan: 1,
                    rowSpan: 1
                ))
            }
        }
        var table = builder.finish(kind: kind)
        table.headerRows = headerRows
        return table
    }

    /// True when the table is a single origin cell (any covered padding aside).
    var isSingleCell: Bool {
        guard grid.count == 1, grid[0].count == 1,
              case .origin = grid[0][0] else { return false }
        return true
    }
}

// MARK: - GridBuilder (port of model/table.rs)

/// Sole constructor for table grids. Enforces the exactly-once invariant:
/// spans register their covered positions, later placements skip over them,
/// and overlapping spans are clamped rather than double-counted.
final class GridBuilder {
    private struct Point: Hashable {
        let row: Int
        let col: Int
    }

    private var grid: [[AnyTypCellSlot]] = []
    /// Positions in future rows covered by an earlier row-spanning origin.
    private var pending: [Point: Point] = [:]
    /// Covered positions claimed by span expansion, charged against
    /// `Limits.maxExpansion` *before* any per-position work.
    private var expansion: UInt64 = 0
    /// Whether trailing rows holding only covered positions survive `finish`.
    private var keepCoveredTail = false

    init() {}

    func nextRow() {
        grid.append([])
    }

    /// Treat covered positions as content when trimming trailing rows. A
    /// spreadsheet merge region is real extent even where every covered
    /// cell is empty; other sources treat such rows as filler and keep the
    /// default trim.
    func keepCoveredTailRows() {
        keepCoveredTail = true
    }

    private func rowIndex() -> Int {
        if grid.isEmpty {
            grid.append([])
        }
        return grid.count - 1
    }

    /// Materialize pending covered positions at the cursor, so the next
    /// placement lands on the first genuinely free column.
    private func skipPending(_ row: Int) {
        while let origin = pending[Point(row: row, col: grid[row].count)] {
            pending.removeValue(forKey: Point(row: row, col: grid[row].count))
            grid[row].append(.covered(originRow: origin.row, originCol: origin.col))
        }
    }

    /// Place a cell at the next free position of the current row.
    ///
    /// The complete span area is charged against the expansion budget before
    /// any expansion happens; `resourceLimit` when the budget is exceeded.
    func place(_ cell: AnyTypCell) throws {
        let col = UInt64(max(1, cell.colSpan))
        let row = UInt64(max(1, cell.rowSpan))
        let (area, mulOverflow) = col.multipliedReportingOverflow(by: row)
        let area64 = mulOverflow ? UInt64.max : area
        let add = area64 > 0 ? area64 - 1 : 0
        let (sum, addOverflow) = expansion.addingReportingOverflow(add)
        expansion = addOverflow ? .max : sum
        if expansion > Limits.maxExpansion {
            throw ConvertError.resourceLimit(
                limit: "max_expansion",
                detail: "table span expansion exceeds the content budget"
            )
        }
        placeUnchecked(cell)
    }

    /// Placement that skips the expansion charge (span-less grids).
    func placeUnchecked(_ cell: AnyTypCell) {
        let row = rowIndex()
        skipPending(row)
        let col = grid[row].count
        var colSpan = max(1, cell.colSpan)
        var rowSpan = max(1, cell.rowSpan)
        // Clamp the spans to positions this origin can actually own - an
        // overlap with an earlier span would break the exactly-once
        // invariant.
        for dc in 1..<colSpan {
            if pending[Point(row: row, col: col + dc)] != nil {
                colSpan = dc
                break
            }
        }
        rowLoop: for dr in 1..<rowSpan {
            for dc in 0..<colSpan {
                if pending[Point(row: row + dr, col: col + dc)] != nil {
                    rowSpan = dr
                    break rowLoop
                }
            }
        }
        grid[row].append(.origin(AnyTypCell(
            blocks: cell.blocks,
            colSpan: colSpan,
            rowSpan: rowSpan
        )))
        for dr in 0..<rowSpan {
            for dc in 0..<colSpan where !(dr == 0 && dc == 0) {
                pending[Point(row: row + dr, col: col + dc)] = Point(row: row, col: col)
            }
        }
    }

    /// Consume one explicitly-written covered position (ODF
    /// `covered-table-cell`). Returns `false` when no span accounts for the
    /// position - the stray marker then becomes an empty cell.
    @discardableResult
    func covered() -> Bool {
        let row = rowIndex()
        let col = grid[row].count
        let point = Point(row: row, col: col)
        guard let origin = pending.removeValue(forKey: point) else {
            grid[row].append(.origin(AnyTypCell(blocks: [], colSpan: 0, rowSpan: 0)))
            return false
        }
        grid[row].append(.covered(originRow: origin.row, originCol: origin.col))
        return true
    }

    func finish(kind: AnyTypTableKind) -> AnyTypTable {
        // Materialize every pending covered position in surviving rows,
        // including tails behind a gap: intervening slots fill with empty
        // cells so each covered marker lands on its true column.
        var byRow: [Int: [Int]] = [:]
        for key in pending.keys where key.row < grid.count {
            byRow[key.row, default: []].append(key.col)
        }
        for (row, cols) in byRow {
            for col in cols.sorted() {
                while grid[row].count < col {
                    grid[row].append(.origin(AnyTypCell(blocks: [], colSpan: 0, rowSpan: 0)))
                }
                let point = Point(row: row, col: col)
                guard let origin = pending.removeValue(forKey: point) else { continue }
                grid[row].append(.covered(originRow: origin.row, originCol: origin.col))
            }
        }
        // Drop trailing all-empty rows.
        while let last = grid.last, last.allSatisfy({ slot in
            switch slot {
            case .origin(let cell): return cell.isEmpty
            case .covered: return !keepCoveredTail
            }
        }) {
            _ = last
            grid.removeLast()
        }
        // Clamp stored spans to the surviving grid so every claimed
        // position is backed by a covered marker (exactly-once invariant).
        let rows = grid.count
        for r in 0..<rows {
            let width = grid[r].count
            for c in 0..<width {
                if case .origin(let cell) = grid[r][c] {
                    grid[r][c] = .origin(AnyTypCell(
                        blocks: cell.blocks,
                        colSpan: min(cell.colSpan, width - c),
                        rowSpan: min(cell.rowSpan, rows - r)
                    ))
                }
            }
        }
        return AnyTypTable(grid: grid, headerRows: 0, kind: kind)
    }
}
