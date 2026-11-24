import Foundation

/// List marker family in the source document.
public enum AnyTypMarkerKind: String, Codable, Sendable, Equatable {
    case bullet
    case decimal
    case lowerAlpha
    case upperAlpha
    case lowerRoman
    case upperRoman
}

/// One resolved list item.
public struct AnyTypListItem: Codable, Sendable, Equatable {
    public var blocks: [AnyTypBlock]
    public var markerLabel: String?

    public init(blocks: [AnyTypBlock], markerLabel: String? = nil) {
        self.blocks = blocks
        self.markerLabel = markerLabel
    }
}

/// Resolved bullet or ordered list.
public struct AnyTypList: Codable, Sendable, Equatable {
    public var marker: AnyTypMarkerKind
    public var start: UInt64
    public var items: [AnyTypListItem]

    public init(marker: AnyTypMarkerKind, start: UInt64 = 1, items: [AnyTypListItem]) {
        self.marker = marker
        self.start = start
        self.items = items
    }
}

/// Semantic vs layout table classification.
public enum AnyTypTableKind: String, Codable, Sendable, Equatable {
    case data
    case layout
}

/// Origin table cell with resolved column and row spans.
public struct AnyTypCell: Codable, Sendable, Equatable {
    public var blocks: [AnyTypBlock]
    public var colSpan: Int
    public var rowSpan: Int

    public init(blocks: [AnyTypBlock], colSpan: Int = 1, rowSpan: Int = 1) {
        self.blocks = blocks
        self.colSpan = colSpan
        self.rowSpan = rowSpan
    }
}

/// One position in `AnyTypTable.grid`.
public enum AnyTypCellSlot: Codable, Sendable, Equatable {
    case origin(AnyTypCell)
    case covered(originRow: Int, originCol: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, cell, originRow, originCol
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "covered" {
            self = .covered(
                originRow: try c.decodeIfPresent(Int.self, forKey: .originRow) ?? 0,
                originCol: try c.decodeIfPresent(Int.self, forKey: .originCol) ?? 0
            )
        } else {
            self = .origin(try c.decode(AnyTypCell.self, forKey: .cell))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .origin(let cell):
            try c.encode("origin", forKey: .kind)
            try c.encode(cell, forKey: .cell)
        case .covered(let row, let col):
            try c.encode("covered", forKey: .kind)
            try c.encode(row, forKey: .originRow)
            try c.encode(col, forKey: .originCol)
        }
    }
}

/// Canonical 2D table grid with header row count.
public struct AnyTypTable: Codable, Sendable, Equatable {
    public var grid: [[AnyTypCellSlot]]
    public var headerRows: Int
    public var kind: AnyTypTableKind

    public init(grid: [[AnyTypCellSlot]], headerRows: Int = 0, kind: AnyTypTableKind = .data) {
        self.grid = grid
        self.headerRows = headerRows
        self.kind = kind
    }
}

/// Block-level document element.
public enum AnyTypBlock: Codable, Sendable, Equatable {
    case heading(level: Int, anchor: String?, content: [AnyTypInline])
    case paragraph([AnyTypInline])
    case list(AnyTypList)
    case table(AnyTypTable)
    case blockQuote([AnyTypBlock])
    case codeBlock(lang: String?, text: String)
    case rule
    case math(String)

    private enum CodingKeys: String, CodingKey {
        case kind, level, anchor, content, list, table, blocks, lang, text
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "heading":
            self = .heading(
                level: try c.decodeIfPresent(Int.self, forKey: .level) ?? 1,
                anchor: try c.decodeIfPresent(String.self, forKey: .anchor),
                content: try c.decodeIfPresent([AnyTypInline].self, forKey: .content) ?? []
            )
        case "paragraph":
            self = .paragraph(try c.decodeIfPresent([AnyTypInline].self, forKey: .content) ?? [])
        case "list":
            self = .list(try c.decode(AnyTypList.self, forKey: .list))
        case "table":
            self = .table(try c.decode(AnyTypTable.self, forKey: .table))
        case "blockQuote":
            self = .blockQuote(try c.decodeIfPresent([AnyTypBlock].self, forKey: .blocks) ?? [])
        case "codeBlock":
            self = .codeBlock(
                lang: try c.decodeIfPresent(String.self, forKey: .lang),
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            )
        case "rule":
            self = .rule
        case "math":
            self = .math(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        default:
            self = .paragraph([])
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let level, let anchor, let content):
            try c.encode("heading", forKey: .kind)
            try c.encode(level, forKey: .level)
            try c.encodeIfPresent(anchor, forKey: .anchor)
            try c.encode(content, forKey: .content)
        case .paragraph(let content):
            try c.encode("paragraph", forKey: .kind)
            try c.encode(content, forKey: .content)
        case .list(let list):
            try c.encode("list", forKey: .kind)
            try c.encode(list, forKey: .list)
        case .table(let table):
            try c.encode("table", forKey: .kind)
            try c.encode(table, forKey: .table)
        case .blockQuote(let blocks):
            try c.encode("blockQuote", forKey: .kind)
            try c.encode(blocks, forKey: .blocks)
        case .codeBlock(let lang, let text):
            try c.encode("codeBlock", forKey: .kind)
            try c.encodeIfPresent(lang, forKey: .lang)
            try c.encode(text, forKey: .text)
        case .rule:
            try c.encode("rule", forKey: .kind)
        case .math(let tex):
            try c.encode("math", forKey: .kind)
            try c.encode(tex, forKey: .text)
        }
    }
}
