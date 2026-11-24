import Foundation

/// Spreadsheet frontend (port of `formats/sheet/`): SpreadsheetML (.xlsx,
/// .xlsm) as XML, BIFF8 (.xls) and BIFF12 (.xlsb) as record streams. All
/// three share the grid assembly and number formats. Hidden rows, columns,
/// and sheets are omitted; merge regions remap onto the surviving grid.
enum SheetFormat {
    private static let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        if bytes.starts(with: oleMagic) {
            // An encrypted OOXML package is an OLE container carrying no
            // BIFF workbook stream, so it has to be named first.
            if let ole = try? OleFile(bytes: bytes),
               ole.exists("EncryptionInfo") || ole.exists("EncryptedPackage") {
                return .failure(.encrypted)
            }
            do {
                return .success(try SheetBiff.parseXls(bytes))
            } catch let e as ConvertError {
                return .failure(e)
            } catch {
                return .failure(.io("\(error)"))
            }
        }
        let pkg: Package
        do {
            pkg = try Package(bytes: bytes)
        } catch let e as ConvertError {
            if case .malformed = e { return .failure(notAWorkbook()) }
            return .failure(e)
        } catch {
            return .failure(notAWorkbook())
        }
        let wbPart: String?
        do {
            wbPart = try sheetMainPart(pkg)
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        guard let wbPart else { return .failure(notAWorkbook()) }
        do {
            guard let data = try pkg.part(wbPart) else {
                return .failure(notAWorkbook())
            }
            // A UTF-16 part opens on its BOM rather than the tag.
            let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            let isXML = body.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) })
                .map { $0 == UInt8(ascii: "<") || $0 == 0xFF || $0 == 0xFE } ?? false
            if isXML {
                return try SheetXlsx.parse(pkg, wbPart: wbPart)
            }
            return SheetBiff.parseXlsb(pkg, wbPart: wbPart)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }
    }

    private static func notAWorkbook() -> ConvertError {
        .malformed(part: nil, detail: "not a readable workbook container")
    }

    /// The package's main part: the root relationship names it wherever it
    /// lives, ahead of the conventional locations.
    private static func sheetMainPart(_ pkg: Package) throws -> String? {
        if let rel = try readRels(pkg, "_rels/.rels")
            .firstOfType(RelType.officeDocument),
           let target = try? resolvePackageTarget("", rel.target) {
            return target.path
        }
        for name in ["xl/workbook.xml", "xl/workbook.bin"] where pkg.hasPart(name) {
            return name
        }
        return nil
    }
}

// MARK: - Shared sheet content and grid assembly

/// One form-control checkbox anchored in a cell.
struct SheetCheckbox {
    var checked: Bool
    var caption: String
}

/// Zero-based (row, col) cell coordinate.
struct SheetCellKey: Hashable {
    var row: UInt32
    var col: UInt32
}

/// Checkboxes anchored in each cell, in drawing order.
typealias SheetCheckboxes = [SheetCellKey: [SheetCheckbox]]

/// One worksheet, parsed but not yet filtered or gridded. Shared with the
/// BIFF readers, which fill it from records instead of XML.
struct SheetContent {
    /// Rendered text by zero-based (row, col); empty results are absent.
    var cells: [SheetCellKey: String] = [:]
    /// Form control checkboxes by the cell they are anchored in.
    var checkboxes: SheetCheckboxes = [:]
    var hiddenRows: Set<UInt32> = []
    /// Inclusive zero-based column ranges hidden by `cols/col` entries.
    var hiddenCols: [(UInt32, UInt32)] = []
    /// Inclusive zero-based merge regions (r1, c1, r2, c2), area > 1.
    var merges: [(UInt32, UInt32, UInt32, UInt32)] = []
}

/// Cell inlines: its own text, then each checkbox with its caption.
func sheetCellInlines(_ text: String?, _ boxes: [SheetCheckbox]) -> [AnyTypInline] {
    var out: [AnyTypInline] = []
    if let text, !text.isEmpty { out.append(.text(text, style: .plain)) }
    for b in boxes {
        if !out.isEmpty { out.append(.text(" ", style: .plain)) }
        out.append(.checkbox(b.checked))
        if !b.caption.isEmpty {
            out.append(.text(" \(b.caption)", style: .plain))
        }
    }
    return out
}

/// Materialize a sheet's grid: visibility filtering, merge widening and
/// remapping, and the grid-slot budget charged across the workbook.
func sheetBuildTable(
    _ sheet: SheetContent, slots: inout UInt64
) throws -> AnyTypTable? {
    let hiddenRows = sheet.hiddenRows.sorted()
    var hiddenColRanges = sheet.hiddenCols
    hiddenColRanges.sort { $0.0 < $1.0 }
    // Flatten inclusive ranges into a sorted coordinate list.
    var hiddenColsList: [UInt32] = []
    var nextCol: UInt32 = 0
    for (a, b) in hiddenColRanges {
        if b < nextCol { continue }
        let lo = max(a, nextCol)
        if lo <= b {
            hiddenColsList.append(contentsOf: lo...b)
        }
        nextCol = max(nextCol, b &+ 1)
    }
    let hiddenCol = { (c: UInt32) in hiddenColsList.contains(c) }
    let hiddenRow = { (r: UInt32) in hiddenRows.contains(r) }

    // Cell text and anchored checkboxes become one inline map.
    var cells: [SheetCellKey: [AnyTypInline]] = [:]
    for (at, boxes) in sheet.checkboxes {
        if at.row < SheetXlsx.maxRows, at.col < SheetXlsx.maxCols {
            cells[at] = sheetCellInlines(sheet.cells[at], boxes)
        }
    }
    for (at, text) in sheet.cells where cells[at] == nil {
        cells[at] = [.text(text, style: .plain)]
    }
    // Merges: drop those with no surviving row/column; content at a hidden
    // origin moves to the first surviving position it covers.
    var merges = sheet.merges
    merges.removeAll { m in
        firstVisible(hiddenRows, lo: m.0, hi: m.2) == nil
            || firstVisible(hiddenColsList, lo: m.1, hi: m.3) == nil
    }
    for m in merges {
        guard let vr = firstVisible(hiddenRows, lo: m.0, hi: m.2),
              let vc = firstVisible(hiddenColsList, lo: m.1, hi: m.3) else { continue }
        if (vr, vc) != (m.0, m.1), let text = cells[SheetCellKey(row: m.0, col: m.1)] {
            cells[SheetCellKey(row: vr, col: vc)] = text
            cells.removeValue(forKey: SheetCellKey(row: m.0, col: m.1))
        }
    }

    // Populated extent over visible cells only.
    var bounds: (UInt32, UInt32, UInt32, UInt32)? = nil
    for key in cells.keys {
        let (r, c) = (key.row, key.col)
        if hiddenRow(r) || hiddenCol(c) { continue }
        if let b = bounds {
            bounds = (min(b.0, r), min(b.1, c), max(b.2, r), max(b.3, c))
        } else {
            bounds = (r, c, r, c)
        }
    }
    guard var (r1, c1, r2, c2) = bounds else { return nil }
    // Merge regions touching the populated extent widen it to full size.
    merges.removeAll { m in !(m.0 <= r2 && m.2 >= r1 && m.1 <= c2 && m.3 >= c1) }
    for m in merges {
        r1 = min(r1, m.0); c1 = min(c1, m.1); r2 = max(r2, m.2); c2 = max(c2, m.3)
    }

    let rowMap = (r1...r2).filter { !hiddenRow($0) }
    let colMap = (c1...c2).filter { !hiddenCol($0) }
    if rowMap.isEmpty || colMap.isEmpty { return nil }
    slots = slots &+ UInt64(rowMap.count) &* UInt64(colMap.count)
    if slots > Limits.maxGridSlots {
        throw ConvertError.resourceLimit(
            limit: "max_grid_slots",
            detail: "workbook extent covers \(slots) grid positions")
    }

    // Remap merges onto surviving coordinates; charge expansion first.
    func visibleSpan(_ map: [UInt32], _ lo: UInt32, _ hi: UInt32) -> (Int, Int) {
        let a = map.firstIndex { $0 >= lo } ?? map.count
        let b = map.firstIndex { $0 > hi } ?? map.count
        return (a, b - a)
    }
    struct Pt: Hashable { var r: Int; var c: Int }
    var origins: [Pt: (UInt32, UInt32)] = [:]
    var covered: Set<Pt> = []
    var expansion: UInt64 = 0
    for m in merges {
        let (r0, rn) = visibleSpan(rowMap, m.0, m.2)
        let (c0, cn) = visibleSpan(colMap, m.1, m.3)
        if rn * cn <= 1 { continue }
        expansion = expansion &+ UInt64(rn * cn - 1)
        if expansion > Limits.maxExpansion {
            throw ConvertError.resourceLimit(
                limit: "max_expansion",
                detail: "merge region expansion exceeds the content budget")
        }
        origins[Pt(r: r0, c: c0)] = (UInt32(cn), UInt32(rn))
        for r in r0..<(r0 + rn) {
            for c in c0..<(c0 + cn) where !(r == r0 && c == c0) {
                covered.insert(Pt(r: r, c: c))
            }
        }
    }

    let builder = GridBuilder()
    builder.keepCoveredTailRows()
    for (ri, row) in rowMap.enumerated() {
        builder.nextRow()
        for (ci, col) in colMap.enumerated() {
            if covered.contains(Pt(r: ri, c: ci)) {
                _ = builder.covered()
                continue
            }
            let cell = cells[SheetCellKey(row: row, col: col)]
                .map { AnyTypCell.fromInlines($0) }
                ?? AnyTypCell(blocks: [], colSpan: 1, rowSpan: 1)
            if let (cs, rs) = origins[Pt(r: ri, c: ci)] {
                try builder.place(.spanning(cell.blocks, colSpan: Int(cs), rowSpan: Int(rs)))
            } else {
                try builder.place(cell)
            }
        }
    }
    let table = builder.finish(kind: .data)
    if table.grid.isEmpty { return nil }
    var result = table
    result.headerRows = HeaderDetect.resolve(result, declared: 0)
    return result
}

/// First coordinate in `lo...hi` absent from the sorted hidden list.
func firstVisible(_ hidden: [UInt32], lo: UInt32, hi: UInt32) -> UInt32? {
    // First index where hidden[i] != lo + i (run still holds).
    let start = hidden.firstIndex { $0 >= lo } ?? hidden.count
    let tail = Array(hidden[start...])
    var a = 0, b = tail.count
    while a < b {
        let mid = (a + b) / 2
        if tail[mid] == lo &+ UInt32(mid) { a = mid + 1 } else { b = mid }
    }
    let (first, overflow) = lo.addingReportingOverflow(UInt32(a))
    guard !overflow, first <= hi else { return nil }
    return first
}
