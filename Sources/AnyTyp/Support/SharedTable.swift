import Foundation

// MARK: - Edge-based table assembly (port of shared/grid.rs)

/// Merge/boundary properties of one cell.
struct CellProp {
    /// First cell of a horizontally merged set.
    var mergeFirst = false
    /// Horizontal continuation: folds into the preceding first cell.
    var mergeCont = false
    /// First cell of a vertically merged chain.
    var vmergeFirst = false
    /// Vertical continuation: covered by the chain's origin above.
    var vmergeCont = false
    /// The cell's right boundary in twips.
    var right: Int64 = 0
}

/// One logical row: cells with their properties, and header flag.
struct GridRowInput {
    var cells: [(blocks: [AnyTypBlock], prop: CellProp)]
    var header: Bool
}

/// Assemble logical rows into the canonical grid: clustered union of
/// every row's cell edges, horizontal merges collapse into column spans,
/// vertical chains start at an explicit restart flag.
func buildEdgeTable(_ rows: [GridRowInput]) throws -> AnyTypBlock? {
    struct Origin {
        var blocks: [AnyTypBlock]
        var colL: Int
        var colR: Int
        var rowSpan: Int
        var vmergeFirst: Bool
        var covered: Bool
    }
    // Producer boundary jitter under this threshold clusters into one edge.
    let edgeTolerance: Int64 = 10
    let headerRows = rows.prefix { $0.header }.count

    // Normalize each row's right edges to be strictly increasing.
    let rowsEdged: [[(blocks: [AnyTypBlock], prop: CellProp)]] = rows.map { row in
        var last = Int64.min
        return row.cells.map { cell in
            var prop = cell.prop
            if prop.right <= last { prop.right = last + 1 }
            last = prop.right
            return (cell.blocks, prop)
        }
    }
    var edges = rowsEdged.flatMap { $0.map { $0.prop.right } }
    edges.sort()
    var clusters: [Int64] = []
    for e in edges {
        if let last = clusters.last, e - last <= edgeTolerance {
            continue
        }
        clusters.append(e)
    }
    func colOf(_ x: Int64) -> Int {
        // First cluster index whose edge >= x - tolerance.
        var lo = 0, hi = clusters.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clusters[mid] < x - edgeTolerance { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    var grid: [[Origin]] = []
    for row in rowsEdged {
        var out: [Origin] = []
        var col = 0
        var i = 0
        while i < row.count {
            var (blocks, prop) = row[i]
            var right = prop.right
            if prop.mergeFirst {
                var j = i + 1
                while j < row.count, row[j].prop.mergeCont {
                    blocks += row[j].blocks
                    right = row[j].prop.right
                    j += 1
                }
                i = j - 1
            }
            let colR = max(colOf(right) + 1, col + 1)
            out.append(Origin(
                blocks: blocks, colL: col, colR: colR,
                rowSpan: 1, vmergeFirst: prop.vmergeFirst,
                covered: prop.vmergeCont))
            col = colR
            i += 1
        }
        grid.append(out)
    }

    // Vertical chains keyed by the origin's exact column range.
    var active: [String: (Int, Int)] = [:]
    for r in grid.indices {
        var nextActive: [String: (Int, Int)] = [:]
        for i in grid[r].indices {
            let range = "\(grid[r][i].colL):\(grid[r][i].colR)"
            if grid[r][i].covered, let (orow, oidx) = active[range] {
                grid[orow][oidx].rowSpan += 1
                nextActive[range] = (orow, oidx)
                continue
            }
            // Continuation without a matching chain: keep it visible.
            if grid[r][i].covered { grid[r][i].covered = false }
            if grid[r][i].vmergeFirst {
                nextActive[range] = (r, i)
            }
        }
        active = nextActive
    }

    let builder = GridBuilder()
    for row in grid {
        builder.nextRow()
        for origin in row {
            let span = origin.colR - origin.colL
            if origin.covered {
                for _ in 0..<span { _ = builder.covered() }
            } else {
                try builder.place(AnyTypCell(
                    blocks: origin.blocks, colSpan: span, rowSpan: origin.rowSpan))
            }
        }
    }
    var table = builder.finish(kind: .data)
    if table.grid.isEmpty { return nil }
    table.headerRows = HeaderDetect.resolve(table, declared: headerRows)
    return .table(table)
}
