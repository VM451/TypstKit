import Foundation

/// Placement of a referenced document note.
public enum AnyTypNoteKind: String, Codable, Sendable, Equatable {
    case footnote
    case endnote
}

/// Footnote or endnote definition referenced by `AnyTypInline.noteRef`.
public struct AnyTypNote: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AnyTypNoteKind
    public var blocks: [AnyTypBlock]

    public init(id: String, kind: AnyTypNoteKind = .footnote, blocks: [AnyTypBlock]) {
        self.id = id
        self.kind = kind
        self.blocks = blocks
    }
}

/// Embedded binary asset (such as PNG/JPEG/SVG picture or OLE payload) extracted from a package.
public struct AnyTypAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var mediaType: String
    public var originPart: String
    public var data: Data

    public init(id: Int, mediaType: String, originPart: String, data: Data) {
        self.id = id
        self.mediaType = mediaType
        self.originPart = originPart
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaType, originPart, dataBase64
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.mediaType = try c.decode(String.self, forKey: .mediaType)
        self.originPart = try c.decode(String.self, forKey: .originPart)
        let b64 = try c.decode(String.self, forKey: .dataBase64)
        self.data = Data(base64Encoded: b64) ?? Data()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encode(originPart, forKey: .originPart)
        try c.encode(data.base64EncodedString(), forKey: .dataBase64)
    }
}

/// Self-contained parsed document model with blocks, notes, and embedded binary assets.
public struct AnyTypDocument: Codable, Sendable, Equatable {
    public var blocks: [AnyTypBlock]
    public var notes: [AnyTypNote]
    public var assets: [AnyTypAsset]

    public init(blocks: [AnyTypBlock] = [], notes: [AnyTypNote] = [], assets: [AnyTypAsset] = []) {
        self.blocks = blocks
        self.notes = notes
        self.assets = assets
    }
}
