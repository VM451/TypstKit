import Foundation

/// CSV and friends (port of `formats/csv.rs`): comma, semicolon, pipe, tab.
/// Field content is preserved as written; only control characters are
/// cleaned. The delimiter is chosen by trial-parsing candidates and scoring
/// record consistency.
enum CsvFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        let delimiter = sniffDelimiter(text)
        return parseWithDelimiter(text, delimiter: delimiter)
    }

    static func parseTSV(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        return parseWithDelimiter(text, delimiter: "\t")
    }

    private static func parseWithDelimiter(_ text: String, delimiter: Character) -> Result<AnyTypDocument, ConvertError> {
        var rows: [[AnyTypCell]] = []
        for record in CsvReader.records(text, delimiter: delimiter) {
            let cells = record.map { field -> AnyTypCell in
                .fromInlines([.text(SharedText.clean(field), style: .plain)])
            }
            rows.append(cells)
        }

        var table = AnyTypTable.fromRows(rows, headerRows: 0, kind: .data)
        table.headerRows = HeaderDetect.resolve(table, declared: 0)
        var doc = AnyTypDocument()
        if !table.grid.isEmpty {
            doc.blocks.append(.table(table))
        }
        return .success(doc)
    }

    /// Trial-parse each candidate over the leading records and score by field
    /// consistency; comma wins ties.
    private static func sniffDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: (Character, UInt32) = (",", 0)
        for d in candidates {
            let counts = CsvReader.records(text, delimiter: d, limit: 20)
                .map { $0.count }
            if counts.isEmpty { continue }
            var tally: [Int: UInt32] = [:]
            for c in counts { tally[c, default: 0] += 1 }
            // Frequency ties break toward the wider record shape.
            let (modal, freq) = tally.max { ($0.value, $0.key) < ($1.value, $1.key) }!
            if modal < 2 { continue } // a delimiter that never splits carries no signal
            let score = freq &* 1000 &+ UInt32(min(modal, 500))
            if score > best.1 { best = (d, score) }
        }
        return best.0
    }
}

/// Minimal RFC 4180 record reader matching the `csv` crate's lenient
/// flexible mode: `"` quoting with `""` escapes, embedded newlines, CRLF.
enum CsvReader {
    /// Parse records; `limit` caps the number of complete records read.
    static func records(_ text: String, delimiter: Character, limit: Int? = nil) -> [[String]] {
        let chars = Array(text)
        var records: [[String]] = []
        var field = String()
        var record: [String] = []
        var inQuotes = false
        var i = 0
        var fieldStart = true

        func endField() {
            record.append(field)
            field = ""
            fieldStart = true
        }
        func endRecord() {
            endField()
            if !(record.count == 1 && record[0].isEmpty) {
                records.append(record)
            }
            record = []
        }

        while i < chars.count {
            if let limit, records.count >= limit { break }
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && fieldStart {
                inQuotes = true
                fieldStart = false
            } else if c == delimiter {
                endField()
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRecord()
            } else {
                field.append(c)
                fieldStart = false
            }
            i += 1
        }
        // Trailing record without a final newline.
        if !field.isEmpty || !record.isEmpty {
            endRecord()
        }
        return records
    }
}
