import Foundation

/// Shared text normalization (port of `shared/text.rs`).

enum SharedText {
    /// Drop control characters and layout-only invisibles, convert NBSP to a
    /// regular space, strip soft hyphens. Line breaks become single spaces; a
    /// CRLF pair is one break. U+200C (ZWNJ) and U+200D (ZWJ) are preserved.
    static func clean(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var iter = text.makeIterator()
        var pendingCR = false
        while let c = iter.next() {
            if pendingCR {
                pendingCR = false
                if c == "\n" { continue }
            }
            switch c {
            case "\u{a0}": out.append(" ")
            case "\u{ad}", "\u{200b}", "\u{feff}": break
            case "\t": out.append("\t")
            case "\r":
                pendingCR = true
                out.append(" ")
            case "\n": out.append(" ")
            default:
                if c.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) {
                    out.append(c)
                }
            }
        }
        return out
    }

    /// Collapse whitespace runs to single spaces.
    static func collapseWS(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var prevSpace = false
        for c in text {
            if c.isWhitespace {
                if !prevSpace { out.append(" ") }
                prevSpace = true
            } else {
                out.append(c)
                prevSpace = false
            }
        }
        return out
    }

    /// Decode bytes to text: UTF-16 BOMs, then UTF-8, then Windows-1252.
    static func decode(_ bytes: [UInt8]) -> String {
        switch bytes.prefix(2) {
        case [0xFF, 0xFE]:
            return String(data: Data(bytes), encoding: .utf16LittleEndian) ?? ""
        case [0xFE, 0xFF]:
            return String(data: Data(bytes), encoding: .utf16BigEndian) ?? ""
        default:
            var body = bytes[...]
            if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
            let data = Data(body)
            if let s = String(data: data, encoding: .utf8) { return s }
            return String(data: data, encoding: .windowsCP1252) ?? ""
        }
    }
}

/// True when `s` should be treated as an absolute URI with a scheme rather
/// than a relative/package reference (port of `shared/uri.rs`).
func isAbsoluteURI(_ s: String) -> Bool {
    guard let colon = s.firstIndex(of: ":") else { return false }
    let scheme = s[..<colon]
    guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
    guard scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) else {
        return false
    }
    // Windows drive-letter paths parse as a one-letter scheme but are local.
    if scheme.count == 1, s.count >= 3 {
        let b = Array(s.utf8)
        if b[1] == 0x3A, b[2] == 0x5C || b[2] == 0x2F { return false }
    }
    return true
}

/// Header-row detection for grids whose format designates no header row
/// (port of `shared/header.rs`).
enum HeaderDetect {
    /// Body rows the column types are read from.
    private static let sampleRows = 50
    /// Share of a column's non-empty body cells that must agree on one type
    /// before the column votes, as a numerator over 10.
    private static let dominanceNum = 9
    private static let dominanceDen = 10
    /// Longest a label can be when nothing else distinguishes the first row.
    private static let maxLabel = 64

    private enum Kind {
        case number, bool, date, text
    }

    /// A grid's `headerRows`: `declared`, or 1 if the first row labels the
    /// columns and 0 otherwise.
    static func resolve(_ table: AnyTypTable, declared: Int) -> Int {
        if declared > 0 { return min(declared, table.grid.count) }
        let grid = table.grid
        if grid.count < 2 { return 0 }
        // A span in the first row means grouped columns or a merged title.
        if grid[0].contains(where: {
            if case .origin(let c) = $0 { return !(c.colSpan == 1 && c.rowSpan == 1) }
            return true
        }) {
            return 0
        }
        let sample = Array(grid[1..<min(grid.count, sampleRows + 1)])
        // A first row that does not have the body's field count is a title
        // line or a stray fragment, not a header.
        if grid[0].count != modalWidth(sample) { return 0 }

        let head = grid[0].map(slotText)
        let body = sample.map { $0.map(slotText) }
        let contentWidth = { (row: [String]) -> Int in
            row.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { $0 + 1 } ?? 0
        }
        let width = ([head] + body).map(contentWidth).max() ?? 0
        if width == 0 || width > head.count { return 0 }

        var seen = Set<String>()
        for (c, value) in head.enumerated().prefix(width) {
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                if c == 0 { continue }
                return 0
            }
            if value.contains("\n") { return 0 }
            if !seen.insert(fold(value)).inserted { return 0 }
        }

        var headerVotes = 0, dataVotes = 0, repeatVotes = 0
        for (c, label) in head.enumerated().prefix(width) {
            let values = body.compactMap { row -> String? in
                guard c < row.count else { return nil }
                let v = row[c].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            if values.isEmpty { continue }
            let label = label.trimmingCharacters(in: .whitespaces)
            switch dominantKind(values) {
            case .some(let kind) where kind != .text:
                if classify(label) == .text { headerVotes += 1 } else { dataVotes += 1 }
            default:
                if values.contains(where: { fold($0) == fold(label) }) { repeatVotes += 1 }
            }
        }

        if headerVotes > 0 || dataVotes > 0 { return headerVotes > dataVotes ? 1 : 0 }
        if repeatVotes > 0 { return 0 }
        let labelled = head.prefix(width).allSatisfy { $0.count <= maxLabel }
        return labelled ? 1 : 0
    }

    /// The field count most sampled body rows agree on.
    private static func modalWidth(_ rows: [[AnyTypCellSlot]]) -> Int {
        var tally: [Int: Int] = [:]
        for row in rows { tally[row.count, default: 0] += 1 }
        return tally.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
    }

    /// A slot's text. Covered positions and non-paragraph cells yield "".
    private static func slotText(_ slot: AnyTypCellSlot) -> String {
        guard case .origin(let cell) = slot else { return "" }
        var out = ""
        for block in cell.blocks {
            guard case .paragraph(let inlines) = block else { return "" }
            if !out.isEmpty { out.append("\n") }
            out += inlinesToPlainText(inlines)
        }
        return out
    }

    private static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func dominantKind(_ values: [String]) -> Kind? {
        for kind in [Kind.number, .bool, .date, .text] {
            let n = values.filter { classify($0) == kind }.count
            if n * dominanceDen >= values.count * dominanceNum { return kind }
        }
        return nil
    }

    private static func classify(_ value: String) -> Kind? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        if isNumber(value) { return .number }
        if ["true", "false", "yes", "no"].contains(fold(value)) { return .bool }
        if isTemporal(value) { return .date }
        return .text
    }

    /// A numeric literal as data files write them.
    private static func isNumber(_ value: String) -> Bool {
        var v = value
        if v.hasSuffix("%") { v = String(v.dropLast()) }
        let cleaned = String(v.filter { ![",", " ", "_", "\u{a0}"].contains($0) })
        guard cleaned.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        return Double(cleaned) != nil
    }

    /// A numeric date triple in any field order, optionally followed by a
    /// time, or a bare clock time.
    private static func isTemporal(_ value: String) -> Bool {
        let parts = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "T" || $0 == " " })
        let date = parts.first.map(String.init) ?? value
        var time = parts.count > 1 ? parts.dropFirst().map(String.init).joined(separator: " ") : ""
        time = time.hasSuffix("Z") ? String(time.dropLast()) : time
        if let dot = time.firstIndex(of: ".") { time = String(time[..<dot]) }
        let isClock: (String) -> Bool = { digitGroups($0, seps: [":"]) == 2 || digitGroups($0, seps: [":"]) == 3 }
        if digitGroups(date, seps: ["-", "/", "."]) == 3 {
            return time.isEmpty || isClock(time)
        }
        return time.isEmpty && isClock(date)
    }

    /// How many components `value` has when split on the first of `seps` it
    /// contains, or 0 unless every component is a short digit run.
    private static func digitGroups(_ value: String, seps: [Character]) -> Int {
        guard let sep = seps.first(where: { value.contains($0) }) else { return 0 }
        let parts = value.split(separator: sep, omittingEmptySubsequences: false)
        let ok = parts.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        return ok ? parts.count : 0
    }
}
