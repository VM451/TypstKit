import Foundation

/// SpreadsheetML reader (.xlsx/.xlsm): workbook sheets, shared strings,
/// cell number formats from `xl/styles.xml`, and merge regions (port of
/// `sheet/xlsx.rs`).
enum SheetXlsx {
    static let maxRows: UInt32 = 1_048_576
    static let maxCols: UInt32 = 16_384

    static let sharedStringsRel =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"

    /// Part name for a workbook-level sibling: the relationship of the
    /// given type when present, else the conventional name.
    static func siblingPartName(
        _ rels: Relationships, _ base: String, _ rel: String, _ conventional: String
    ) -> String {
        if let r = rels.firstOfType(rel),
           let t = try? resolvePackageTarget(base, r.target) {
            return t.path
        }
        if let slash = base.lastIndex(of: "/") {
            return String(base[..<slash]) + "/" + conventional
        }
        return conventional
    }

    static func parse(_ pkg: Package, wbPart: String) throws -> Result<AnyTypDocument, ConvertError> {
        let workbook: XmlElement
        do {
            workbook = try pkg.requiredXMLPart(wbPart)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.malformed(part: wbPart, detail: "\(error)"))
        }
        // Any OOXML main part resolves here; a document or presentation
        // would otherwise convert to an empty workbook.
        guard workbook.childElems.first?.is(XmlNS.sml, "workbook") == true else {
            return .failure(.malformed(part: wbPart, detail: "main part is not a workbook"))
        }
        let wbRels = try readRels(pkg, relsPartFor(wbPart))
        let date1904 = workbook.firstDescendant(XmlNS.sml, "workbookPr")
            .flatMap { $0.attrUnqualified("date1904") }
            .map { ["1", "true"].contains($0.trimmingCharacters(in: .whitespaces)) } ?? false

        let shared: [String]
        let sharedName = siblingPartName(wbRels, wbPart, sharedStringsRel, "sharedStrings.xml")
        if let root = try pkg.optionalXMLPart(sharedName) {
            shared = sharedStrings(root)
        } else {
            shared = []
        }
        let stylesName = siblingPartName(wbRels, wbPart, RelType.styles, "styles.xml")
        let styles = Styles(try pkg.optionalXMLPart(stylesName))

        // Visible sheets in workbook order.
        var sheets: [(String, String)] = []
        if let sheetsEl = workbook.firstDescendant(XmlNS.sml, "sheets") {
            for sheet in sheetsEl.descendants(XmlNS.sml, "sheet") {
                if let state = sheet.attrUnqualified("state"),
                   ["hidden", "veryHidden"].contains(state) { continue }
                let name = sheet.attrUnqualified("name") ?? ""
                guard let rid = sheet.attrQualified(XmlNS.r, "id"),
                      let target = wbRels.internalTarget(rid),
                      let resolved = try? resolvePackageTarget(wbPart, target) else {
                    AnyTypLog.warn("skipping sheet \(name.debugDescription) with no worksheet relationship")
                    continue
                }
                sheets.append((name, resolved.path))
            }
        }

        let multiSheet = sheets.count > 1
        var doc = AnyTypDocument()
        var failed = 0
        var slots: UInt64 = 0
        for (name, part) in sheets {
            guard let wsRoot = try pkg.optionalXMLPart(part),
                  let worksheet = wsRoot.descendantElems().first(where: { $0.is(XmlNS.sml, "worksheet") })
                    ?? (wsRoot.is(XmlNS.sml, "worksheet") ? wsRoot : nil) else {
                AnyTypLog.warn("skipping unreadable sheet \(name.debugDescription)")
                failed += 1
                continue
            }
            var content = readSheet(worksheet, shared: shared, styles: styles, date1904: date1904)
            content.checkboxes = try readVmlCheckboxes(pkg, sheetPart: part)
            guard let table = try sheetBuildTable(content, slots: &slots) else { continue }
            if multiSheet {
                doc.blocks.append(.heading(
                    level: 2, anchor: nil, content: [.text(name, style: .plain)]))
            }
            doc.blocks.append(.table(table))
        }
        if !sheets.isEmpty && failed == sheets.count {
            return .failure(.malformed(part: nil, detail: "no sheet in the workbook could be read"))
        }
        return .success(doc)
    }

    /// The shared string table, one cleaned entry per `si`.
    private static func sharedStrings(_ root: XmlElement) -> [String] {
        guard let sst = root.firstDescendant(XmlNS.sml, "sst") else { return [] }
        return sst.descendants(XmlNS.sml, "si").map { SharedText.clean(richText($0)) }
    }

    /// Text of an `si`/`is`: a single `t`, or rich-text `r` runs
    /// concatenated. Phonetic guides (`rPh`) are not content.
    static func richText(_ item: XmlElement) -> String {
        var out = ""
        for child in item.childElems {
            if child.is(XmlNS.sml, "t") {
                out += child.text
            } else if child.is(XmlNS.sml, "r"),
                      let t = child.find(XmlNS.sml, "t") {
                out += t.text
            }
        }
        return out
    }

    /// `xl/styles.xml` reduced to what rendering needs: `cellXfs` entries,
    /// each numFmtId resolved to a parsed format.
    struct Styles {
        var xfs: [SheetCellFormat] = []

        init(_ root: XmlElement?) {
            guard let root else { return }
            var custom: [UInt32: String] = [:]
            for nf in root.descendants(XmlNS.sml, "numFmt") {
                if let idStr = nf.attrUnqualified("numFmtId"),
                   let id = UInt32(idStr),
                   let code = nf.attrUnqualified("formatCode") {
                    custom[id] = code
                }
            }
            var cache: [UInt32: SheetCellFormat] = [:]
            if let xfsEl = root.firstDescendant(XmlNS.sml, "cellXfs") {
                xfs = xfsEl.findAll(XmlNS.sml, "xf").map { xf in
                    let id = xf.attrUnqualified("numFmtId").flatMap(UInt32.init) ?? 0
                    if let hit = cache[id] { return hit }
                    let fmt = resolveFormat(id, custom: custom)
                    cache[id] = fmt
                    return fmt
                }
            }
        }

        /// The format for a cell's `s` attribute (default 0).
        func forCell(_ s: String?) -> SheetCellFormat {
            let i = s.flatMap(Int.init) ?? 0
            return xfs.indices.contains(i) ? xfs[i] : .general
        }
    }

    /// A numFmtId's format: the file's `numFmt` entries first, then the
    /// built-in table. Unknown ids fall back to General.
    static func resolveFormat(_ id: UInt32, custom: [UInt32: String]) -> SheetCellFormat {
        let code = custom[id] ?? SheetNumFmt.builtinCode(id)
        guard let code else {
            if id != 0 {
                AnyTypLog.debug("numFmtId \(id) has no resolvable code, rendering as General")
            }
            return .general
        }
        guard let f = SheetNumFmt.NumberFormat.parse(code) else {
            AnyTypLog.debug("unsupported number format \(code.debugDescription), rendering as General")
            return .general
        }
        return .fmt(f)
    }

    static func readSheet(
        _ worksheet: XmlElement, shared: [String], styles: Styles, date1904: Bool
    ) -> SheetContent {
        var out = SheetContent()
        for col in worksheet.descendants(XmlNS.sml, "col") {
            guard let hidden = col.attrUnqualified("hidden"),
                  ["1", "true"].contains(hidden.trimmingCharacters(in: .whitespaces)) else { continue }
            func bound(_ name: String) -> UInt32? {
                col.attrUnqualified(name).flatMap(UInt32.init).map { $0 > 0 ? $0 - 1 : 0 }
            }
            if let lo = bound("min"), let hi = bound("max"), lo <= hi {
                out.hiddenCols.append((lo, min(hi, maxCols - 1)))
            }
        }
        var nextRow: UInt32 = 0
        for sd in worksheet.findAll(XmlNS.sml, "sheetData") {
            for row in sd.findAll(XmlNS.sml, "row") {
                let r = row.attrUnqualified("r").flatMap(UInt32.init)
                    .map { $0 > 0 ? $0 - 1 : 0 } ?? nextRow
                if r >= maxRows { continue }
                nextRow = r &+ 1
                if let hidden = row.attrUnqualified("hidden"),
                   ["1", "true"].contains(hidden.trimmingCharacters(in: .whitespaces)) {
                    out.hiddenRows.insert(r)
                }
                var nextCol: UInt32 = 0
                for c in row.findAll(XmlNS.sml, "c") {
                    // Position comes from the cell's own reference.
                    let (cr, cc): (UInt32, UInt32)
                    if let ref = c.attrUnqualified("r") {
                        guard let rc = parseRef(ref) else { continue }
                        (cr, cc) = rc
                    } else {
                        (cr, cc) = (r, nextCol)
                    }
                    nextCol = cc &+ 1
                    if cr >= maxRows || cc >= maxCols { continue }
                    let text = cellText(c, shared: shared, styles: styles, date1904: date1904)
                    if !text.isEmpty {
                        out.cells[SheetCellKey(row: cr, col: cc)] = text
                    }
                }
            }
        }
        for merge in worksheet.descendants(XmlNS.sml, "mergeCell") {
            guard let ref = merge.attrUnqualified("ref"),
                  let region = parseRegion(ref) else {
                AnyTypLog.debug("skipping unparseable merge reference")
                continue
            }
            if region.0 != region.2 || region.1 != region.3 {
                out.merges.append(region)
            }
        }
        return out
    }

    /// A cell's rendered text, per its `t` type and resolved number format.
    static func cellText(
        _ c: XmlElement, shared: [String], styles: Styles, date1904: Bool
    ) -> String {
        let fmt = styles.forCell(c.attrUnqualified("s"))
        let value = { c.find(XmlNS.sml, "v")?.text ?? "" }
        switch c.attrUnqualified("t") ?? "n" {
        case "s":
            let v = value().trimmingCharacters(in: .whitespaces)
            guard let i = Int(v), shared.indices.contains(i) else {
                if !v.isEmpty { AnyTypLog.debug("shared string index \(v.debugDescription) out of range") }
                return ""
            }
            return sheetFormatAsText(fmt, text: shared[i])
        case "str":
            return sheetFormatAsText(fmt, text: SharedText.clean(value()))
        case "inlineStr":
            let text = c.find(XmlNS.sml, "is").map {
                SharedText.clean(SheetXlsx.richText($0))
            } ?? ""
            return sheetFormatAsText(fmt, text: text)
        case "b":
            switch value().trimmingCharacters(in: .whitespaces) {
            case "1", "true": return "TRUE"
            case "0", "false": return "FALSE"
            default: return ""
            }
        case "e", "d":
            return SharedText.clean(value())
        default:
            let v = value().trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return "" }
            guard let n = Double(v) else {
                AnyTypLog.debug("unparseable numeric cell value \(v.debugDescription)")
                return ""
            }
            return sheetRenderNumber(fmt, n, date1904: date1904)
        }
    }

    /// A cell reference (`C3`) as zero-based (row, column).
    static func parseRef(_ r: String) -> (UInt32, UInt32)? {
        guard let digitAt = r.firstIndex(where: { $0.isNumber }) else { return nil }
        let letters = String(r[..<digitAt])
        let digits = String(r[digitAt...])
        if letters.isEmpty || digits.isEmpty { return nil }
        var col: UInt32 = 0
        for ch in letters {
            guard ch.isLetter, let ascii = ch.asciiValue else { return nil }
            let upper = ascii >= UInt8(ascii: "a") ? ascii - 32 : ascii
            guard upper >= UInt8(ascii: "A"), upper <= UInt8(ascii: "Z") else { return nil }
            let v = UInt32(upper - UInt8(ascii: "A") + 1)
            let (m, mo) = col.multipliedReportingOverflow(by: 26)
            let (a, ao) = m.addingReportingOverflow(v)
            guard !mo, !ao, a <= maxCols else { return nil }
            col = a
        }
        guard let row = UInt32(digits), (1...maxRows).contains(row) else { return nil }
        return (row - 1, col - 1)
    }

    /// A merge reference (`F1:O3`) as an inclusive normalized region.
    static func parseRegion(_ r: String) -> (UInt32, UInt32, UInt32, UInt32)? {
        let parts = r.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let a = parseRef(parts[0]) else { return nil }
        let b = parts.count > 1 ? parseRef(parts[1]) : a
        guard let b else { return nil }
        return (min(a.0, b.0), min(a.1, b.1), max(a.0, b.0), max(a.1, b.1))
    }
}

// MARK: - VML form checkboxes (port of `sheet/controls.rs`)

private let vmlDrawingRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing"

/// The checkboxes in a worksheet part's VML drawings.
func readVmlCheckboxes(_ pkg: Package, sheetPart: String) throws -> SheetCheckboxes {
    let rels = try readRels(pkg, relsPartFor(sheetPart))
    var out: SheetCheckboxes = [:]
    var targets: [String] = rels.all.compactMap { (_, r) in
        guard r.relType == vmlDrawingRel, r.mode == .internal,
              let t = try? resolvePackageTarget(sheetPart, r.target) else { return nil }
        return t.path
    }
    targets.sort()
    targets = Array(Set(targets)).sorted()
    for target in targets {
        if let root = try pkg.optionalXMLPart(target) {
            vmlCheckboxes(root, out: &out)
        }
    }
    return out
}

private func vmlCheckboxes(_ root: XmlElement, out: inout SheetCheckboxes) {
    for shape in root.descendants(XmlNS.vml, "shape") {
        guard let data = shape.find(XmlNS.xVml, "ClientData"),
              data.attrUnqualified("ObjectType") == "Checkbox" else { continue }
        if let style = shape.attrUnqualified("style"),
           style.replacingOccurrences(of: " ", with: "").contains("visibility:hidden") {
            continue
        }
        guard let anchor = data.find(XmlNS.xVml, "Anchor"),
              let at = anchorCell(anchor.text) else {
            AnyTypLog.debug("skipping a checkbox with no readable anchor")
            continue
        }
        // Absent means unchecked; 2 is the mixed state, which has no token.
        let checked: Bool
        if let c = data.find(XmlNS.xVml, "Checked") {
            switch c.text.trimmingCharacters(in: .whitespaces) {
            case "0": checked = false
            case "1": checked = true
            default: continue
            }
        } else {
            checked = false
        }
        let caption = shape.find(XmlNS.vml, "textbox")
            .map { SharedText.collapseWS(SharedText.clean($0.text)).trimmingCharacters(in: .whitespaces) }
            ?? ""
        out[SheetCellKey(row: at.0, col: at.1), default: []]
            .append(SheetCheckbox(checked: checked, caption: caption))
    }
}

/// The (row, col) an `x:Anchor` starts in: `LeftColumn, LeftOffset, TopRow, TopOffset, ...`.
private func anchorCell(_ anchor: String) -> (UInt32, UInt32)? {
    var parts = anchor.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 3,
          let col = UInt32(parts[0]), let row = UInt32(parts[2]) else { return nil }
    return (row, col)
}
