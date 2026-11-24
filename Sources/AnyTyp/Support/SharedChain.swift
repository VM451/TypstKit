import Foundation

/// Style-chain traversal: walk a parent (`basedOn`) chain child-to-root.
/// A cycle is a resource-safety bound and hard-fails (port of `shared/chain.rs`).
struct StyleChains {
    /// style id -> (definition element, parent style id).
    private var raw: [String: (XmlElement, String?)] = [:]

    mutating func insert(id: String, def: XmlElement, parent: String?) {
        raw[id] = (def, parent)
    }

    func definition(_ id: String) -> XmlElement? {
        raw[id]?.0
    }

    /// Walk a chain child-to-root, visiting each definition until `visit`
    /// returns non-nil. Unknown ids end the walk; a cycle hard-fails.
    func walk<T>(_ id: String, _ visit: (XmlElement) throws -> T?) throws -> T? {
        var visited = Set<String>()
        var cursor: String? = raw.keys.contains(id) ? id : nil
        while let current = cursor {
            if !visited.insert(current).inserted {
                throw ConvertError.malformed(part: nil, detail: "style inheritance cycle at \(current)")
            }
            guard let entry = raw[current] else { break }
            if let hit = try visit(entry.0) { return hit }
            cursor = entry.1.flatMap { raw.keys.contains($0) ? $0 : nil }
        }
        return nil
    }
}

/// One piece of a level's number text: literal characters or a level ref
/// (port of `shared/numbering.rs`).
enum NumberText: Equatable {
    case literal(String)
    case level(UInt8)
}

struct NumberPattern: Equatable {
    /// Empty = no pattern known; the marker kind's default label applies.
    var text: [NumberText] = []
    /// Legal numbering: referenced levels render as decimal.
    var legal = false
}

/// Parse WordprocessingML-style percent patterns (`%1`–`%9` level
/// references, everything else literal).
func parsePercentPattern(_ text: String) -> [NumberText] {
    var out: [NumberText] = []
    var chars = Array(text)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "%", i + 1 < chars.count,
           let d = chars[i + 1].wholeNumberValue, (1...9).contains(d) {
            out.append(.level(UInt8(d - 1)))
            i += 2
            continue
        }
        switch out.last {
        case .literal(var s)?:
            out[out.count - 1] = .literal(s + String(c))
        default:
            out.append(.literal(String(c)))
        }
        i += 1
    }
    return out
}

/// Render a pattern against the current sequence values; `nil` when the
/// result matches the default label from marker + value alone.
func compositeLabel(
    _ pattern: NumberPattern,
    ownMarker: AnyTypMarkerKind,
    ownValue: UInt64,
    levelMarker: (Int) -> AnyTypMarkerKind,
    levelValue: (Int) -> UInt64
) -> String? {
    if pattern.text.isEmpty { return nil }
    var out = ""
    for piece in pattern.text {
        switch piece {
        case .literal(let s): out += s
        case .level(let l):
            let li = Int(l)
            let kind = pattern.legal ? AnyTypMarkerKind.decimal : levelMarker(li)
            out += kind.ordinal(levelValue(li))
        }
    }
    return out == ownMarker.label(ownValue) ? nil : out
}

/// The block container a paragraph style names (port of `shared/blockstyle.rs`).
enum BlockStyle {
    case quote
    case code
}

/// The container a paragraph style name designates. ODF encodes spaces in
/// internal style names as `_20_`.
func blockStyleFromName(_ name: String) -> BlockStyle? {
    let name = name.replacingOccurrences(of: "_20_", with: " ")
    switch name.trimmingCharacters(in: .whitespaces).lowercased() {
    case "quote", "intense quote", "block text", "quotations": return .quote
    case "html preformatted", "source code", "preformatted text": return .code
    default: return nil
    }
}

/// Consecutive paragraphs sharing one styled container, folded into a
/// single block.
enum StyledRun {
    case empty
    case quote([AnyTypBlock])
    case code([String])

    static var `default`: StyledRun { .empty }

    /// The container currently open.
    var style: BlockStyle? {
        switch self {
        case .empty: return nil
        case .quote: return .quote
        case .code: return .code
        }
    }

    /// Add one styled paragraph, closing the open container first when the
    /// style changes.
    mutating func push(_ style: BlockStyle, _ inlines: [AnyTypInline], _ out: inout [AnyTypBlock]) {
        if self.style != style {
            flush(&out)
            self = style == .quote ? .quote([]) : .code([])
        }
        switch self {
        case .code(var lines):
            lines.append(inlinesToPlainText(inlines))
            self = .code(lines)
        case .quote(var blocks):
            if !inlinesAreEmpty(inlines) {
                blocks.append(.paragraph(inlines))
            }
            self = .quote(blocks)
        case .empty:
            break
        }
    }

    /// Close the open container, if any.
    mutating func flush(_ out: inout [AnyTypBlock]) {
        let old = self
        self = .empty
        switch old {
        case .quote(let inner):
            if !inner.isEmpty { out.append(.blockQuote(inner)) }
        case .code(let lines):
            // Blank lines count only between the code's own lines.
            let first = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let last = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let first, let last {
                out.append(.codeBlock(lang: nil, text: lines[first...last].joined(separator: "\n")))
            }
        case .empty:
            break
        }
    }
}

/// Pick the branch of an `mc:AlternateContent` to process: the first
/// `mc:Choice` whose `Requires` namespaces are all supported, else the
/// `mc:Fallback` (port of `shared/mc.rs`).
func mcAlternateBranch(_ alt: XmlElement, supported: [String]) -> XmlElement? {
    for choice in alt.findAll(XmlNS.mc, "Choice") {
        if choiceSupported(choice, supported: supported) { return choice }
    }
    return alt.find(XmlNS.mc, "Fallback")
}

private func choiceSupported(_ choice: XmlElement, supported: [String]) -> Bool {
    guard let requires = choice.attr(XmlNS.mc, "Requires") else { return true }
    // Requires prefixes were resolved to namespace URIs at parse time.
    return requires.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
        supported.contains(String($0))
    }
}
