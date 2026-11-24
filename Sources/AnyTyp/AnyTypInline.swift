import Foundation

/// Resolved character-level formatting on a text run.
public struct AnyTypStyle: Codable, Sendable, Equatable {
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool
    public var superscript: Bool
    public var subscriptText: Bool
    public var code: Bool

    public static let plain = AnyTypStyle()

    public init(
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strike: Bool = false,
        superscript: Bool = false,
        subscriptText: Bool = false,
        code: Bool = false
    ) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.superscript = superscript
        self.subscriptText = subscriptText
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case bold, italic, underline, strike, superscript
        case subscriptText = "subscript"
        case code
    }
}

/// Destination of an inline hyperlink.
public enum AnyTypLinkTarget: Codable, Sendable, Equatable {
    case external(String)
    case relative(String)
    case anchor(String)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let value = try c.decode(String.self, forKey: .value)
        switch kind {
        case "external": self = .external(value)
        case "relative": self = .relative(value)
        default: self = .anchor(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .external(let v):
            try c.encode("external", forKey: .kind)
            try c.encode(v, forKey: .value)
        case .relative(let v):
            try c.encode("relative", forKey: .kind)
            try c.encode(v, forKey: .value)
        case .anchor(let v):
            try c.encode("anchor", forKey: .kind)
            try c.encode(v, forKey: .value)
        }
    }
}

/// Backing source of an inline image.
public enum AnyTypImageSource: Codable, Sendable, Equatable {
    case external(String)
    case asset(Int)
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case kind, url, assetId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "external":
            self = .external(try c.decodeIfPresent(String.self, forKey: .url) ?? "")
        case "asset":
            self = .asset(try c.decodeIfPresent(Int.self, forKey: .assetId) ?? 0)
        default:
            self = .unavailable
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .external(let url):
            try c.encode("external", forKey: .kind)
            try c.encode(url, forKey: .url)
        case .asset(let id):
            try c.encode("asset", forKey: .kind)
            try c.encode(id, forKey: .assetId)
        case .unavailable:
            try c.encode("unavailable", forKey: .kind)
        }
    }
}

/// One inline element inside a paragraph or heading.
public enum AnyTypInline: Codable, Sendable, Equatable {
    case text(String, style: AnyTypStyle)
    case link(content: [AnyTypInline], target: AnyTypLinkTarget)
    case image(alt: String, source: AnyTypImageSource)
    case anchor(String)
    case noteRef(String)
    case lineBreak
    case math(String)
    case checkbox(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, text, style, content, target, alt, source, anchor, noteId, checked
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(
                try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                style: try c.decodeIfPresent(AnyTypStyle.self, forKey: .style) ?? .plain
            )
        case "link":
            self = .link(
                content: try c.decodeIfPresent([AnyTypInline].self, forKey: .content) ?? [],
                target: try c.decode(AnyTypLinkTarget.self, forKey: .target)
            )
        case "image":
            self = .image(
                alt: try c.decodeIfPresent(String.self, forKey: .alt) ?? "",
                source: try c.decodeIfPresent(AnyTypImageSource.self, forKey: .source) ?? .unavailable
            )
        case "anchor":
            self = .anchor(try c.decodeIfPresent(String.self, forKey: .anchor) ?? "")
        case "noteRef":
            self = .noteRef(try c.decodeIfPresent(String.self, forKey: .noteId) ?? "")
        case "lineBreak":
            self = .lineBreak
        case "math":
            self = .math(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "checkbox":
            self = .checkbox(try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false)
        default:
            self = .text("", style: .plain)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t, let style):
            try c.encode("text", forKey: .kind)
            try c.encode(t, forKey: .text)
            try c.encode(style, forKey: .style)
        case .link(let content, let target):
            try c.encode("link", forKey: .kind)
            try c.encode(content, forKey: .content)
            try c.encode(target, forKey: .target)
        case .image(let alt, let source):
            try c.encode("image", forKey: .kind)
            try c.encode(alt, forKey: .alt)
            try c.encode(source, forKey: .source)
        case .anchor(let id):
            try c.encode("anchor", forKey: .kind)
            try c.encode(id, forKey: .anchor)
        case .noteRef(let id):
            try c.encode("noteRef", forKey: .kind)
            try c.encode(id, forKey: .noteId)
        case .lineBreak:
            try c.encode("lineBreak", forKey: .kind)
        case .math(let tex):
            try c.encode("math", forKey: .kind)
            try c.encode(tex, forKey: .text)
        case .checkbox(let checked):
            try c.encode("checkbox", forKey: .kind)
            try c.encode(checked, forKey: .checked)
        }
    }
}
