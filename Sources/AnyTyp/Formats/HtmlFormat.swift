import Foundation

/// Standalone HTML5 / XHTML frontend (port of `formats/html.rs`).
enum HtmlFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        let root: XmlElement
        do {
            root = try parseHtmlTree(text)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.malformed("html parse failed"))
        }
        let css = Stylesheet()
        for styleEl in root.descendantsAny("style") {
            css.add(styleEl.text)
        }

        let assets = AssetSink()
        let ctx = StandaloneHtmlCtx(assets: assets)

        let body = root.descendantsAny("body").first
            ?? root.descendantsAny("html").first
            ?? root

        var blocks: [AnyTypBlock]
        do {
            blocks = try htmlToBlocks(body, css: css, ctx: ctx)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.malformed("html parse failed"))
        }
        let hasH1 = blocks.contains { if case .heading(let level, _, _) = $0 { return level == 1 }; return false }
        if !hasH1, let titleEl = root.descendantsAny("title").first {
            let title = titleEl.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                blocks.insert(.heading(level: 1, anchor: nil, content: [.text(title, style: .plain)]), at: 0)
            }
        }

        return .success(AnyTypDocument(blocks: blocks, assets: assets.assets))
    }
}

private final class StandaloneHtmlCtx: HtmlCtx {
    let assets: AssetSink
    private var dataSeq = 0

    init(assets: AssetSink) {
        self.assets = assets
    }

    func linkTarget(_ href: String) -> AnyTypLinkTarget? {
        let href = href.trimmingCharacters(in: .whitespaces)
        if href.isEmpty { return nil }
        if href.first == "#" { return .anchor(String(href.dropFirst())) }
        if isAbsoluteURI(href) { return .external(href) }
        return .relative(href)
    }

    func imageSource(_ src: String) throws -> AnyTypImageSource? {
        let src = src.trimmingCharacters(in: .whitespaces)
        if src.isEmpty { return nil }
        if let (mime, data) = decodeDataURI(src) {
            dataSeq += 1
            let id = try assets.add(mediaType: mime, originPart: "data-uri-\(dataSeq)", bytes: data)
            return .asset(id)
        }
        if isAbsoluteURI(src) { return .external(src) }
        return .unavailable
    }

    func anchorId(_ raw: String) -> String { raw }
}

private func decodeDataURI(_ uri: String) -> (String, [UInt8])? {
    guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
    let meta = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
    guard meta.hasSuffix(";base64") else { return nil }
    let mimeRaw = meta.dropLast(";base64".count)
    let mime = mimeRaw.isEmpty ? "application/octet-stream" : String(mimeRaw)
    let payload = String(uri[uri.index(after: comma)...])
    guard let data = decodeBase64(payload) else { return nil }
    return (mime, data)
}

private func decodeBase64(_ s: String) -> [UInt8]? {
    func val(_ b: UInt8) -> UInt8? {
        switch b {
        case 65...90: return b - 65
        case 97...122: return b - 97 + 26
        case 48...57: return b - 48 + 52
        case 43: return 62
        case 47: return 63
        default: return nil
        }
    }
    // ASCII whitespace only: space, \t, \n, \r, VT, FF.
    let bytes = Array(s.utf8).filter { ![9, 10, 11, 12, 13, 32].contains($0) }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 3 / 4)
    var i = 0
    while i + 4 <= bytes.count {
        let chunk = Array(bytes[i..<i + 4])
        i += 4
        guard let a = val(chunk[0]), let b = val(chunk[1]) else { return nil }
        out.append((a << 2) | (b >> 4))
        if chunk[2] != 61, let c = val(chunk[2]) {
            out.append((b << 4) | (c >> 2))
            if chunk[3] != 61, let d = val(chunk[3]) {
                out.append((c << 6) | d)
            }
        }
    }
    // Rust chunks(4) tolerates a short final chunk of 2-3 chars.
    if i < bytes.count {
        let chunk = Array(bytes[i...])
        if chunk.count >= 2, let a = val(chunk[0]), let b = val(chunk[1]) {
            out.append((a << 2) | (b >> 4))
            if chunk.count > 2, chunk[2] != 61, let c = val(chunk[2]) {
                out.append((b << 4) | (c >> 2))
                if chunk.count > 3, chunk[3] != 61, let d = val(chunk[3]) {
                    out.append((c << 6) | d)
                }
            }
        }
    }
    return out
}

private let voidTags: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
]

private func autoClosesTop(_ top: String, _ incoming: String) -> Bool {
    switch top {
    case "p":
        return ["address", "article", "aside", "blockquote", "div", "dl",
                "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5",
                "h6", "header", "hr", "main", "nav", "ol", "p", "pre",
                "section", "table", "ul"].contains(incoming)
    case "li": return incoming == "li"
    case "dt", "dd": return ["dt", "dd"].contains(incoming)
    case "td", "th": return ["td", "th", "tr"].contains(incoming)
    case "tr": return ["tr", "thead", "tbody", "tfoot"].contains(incoming)
    case "thead", "tbody", "tfoot": return ["thead", "tbody", "tfoot"].contains(incoming)
    default: return false
    }
}

// MARK: - Lenient HTML tokenizer

private struct HtmlToken {
    enum Kind {
        case start(tag: String, attrs: [XmlAttr], selfClosing: Bool)
        case end(tag: String)
        case text(String)
    }
}

private func parseHtmlTree(_ html: String) throws -> XmlElement {
    let cleaned = stripRawBlocks(html, "script")
    let root = XmlElement(ns: nil, local: "", attrs: [])
    var stack: [XmlElement] = []
    var nodes = 0

    func bumpNodes() throws {
        nodes += 1
        if nodes > Limits.maxXMLNodes {
            throw ConvertError.resourceLimit(
                limit: "max_xml_nodes",
                detail: "HTML node count exceeds \(Limits.maxXMLNodes)"
            )
        }
    }

    func attach(_ node: XmlNode) {
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root.children.append(node)
        }
    }

    func pushText(_ text: String) throws {
        guard !text.isEmpty else { return }
        try bumpNodes()
        // Merge adjacent text nodes.
        if let parent = stack.last {
            if case .text(let prev)? = parent.children.last {
                parent.children[parent.children.count - 1] = .text(prev + text)
            } else {
                parent.children.append(.text(text))
            }
        } else {
            if case .text(let prev)? = root.children.last {
                root.children[root.children.count - 1] = .text(prev + text)
            } else {
                root.children.append(.text(text))
            }
        }
    }

    let chars = Array(cleaned)
    var i = 0
    while i < chars.count {
        if chars[i] == "<" {
            // Comment / CDATA / end tag / start tag.
            if i + 1 < chars.count, chars[i + 1] == "!" {
                // Skip comments and doctype.
                if let end = findSequence(chars, "-->", from: i + 2) {
                    i = end + 3
                } else if let end = findSequence(chars, ">", from: i + 2) {
                    i = end + 1
                } else {
                    break
                }
                continue
            }
            if i + 1 < chars.count, chars[i + 1] == "?" {
                if let end = findSequence(chars, "?>", from: i + 2) {
                    i = end + 2
                } else if let end = findSequence(chars, ">", from: i + 2) {
                    i = end + 1
                } else {
                    break
                }
                continue
            }
            if i + 1 < chars.count, chars[i + 1] == "/" {
                // End tag.
                var j = i + 2
                var name = ""
                while j < chars.count, chars[j] != ">" {
                    name.append(chars[j])
                    j += 1
                }
                let tag = name.lowercased()
                if !voidTags.contains(tag), let pos = stack.lastIndex(where: { $0.local == tag }) {
                    while stack.count > pos {
                        let closed = stack.removeLast()
                        attach(.element(closed))
                    }
                }
                i = min(j + 1, chars.count)
                continue
            }
            // Start tag.
            var j = i + 1
            var name = ""
            while j < chars.count, chars[j] != ">", chars[j] != "/", !chars[j].isWhitespace {
                name.append(chars[j])
                j += 1
            }
            let tag = name.lowercased()
            // Parse attributes.
            var attrs: [XmlAttr] = []
            var selfClosing = false
            while j < chars.count {
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j >= chars.count { break }
                if chars[j] == ">" { j += 1; break }
                if chars[j] == "/" {
                    if j + 1 < chars.count, chars[j + 1] == ">" {
                        selfClosing = true
                        j += 2
                        break
                    }
                    j += 1
                    continue
                }
                var aname = ""
                while j < chars.count, chars[j] != "=", chars[j] != ">", chars[j] != "/", !chars[j].isWhitespace {
                    aname.append(chars[j])
                    j += 1
                }
                var aval = ""
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "=" {
                    j += 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
                        let quote = chars[j]
                        j += 1
                        while j < chars.count, chars[j] != quote {
                            aval.append(chars[j])
                            j += 1
                        }
                        if j < chars.count { j += 1 }
                    } else {
                        while j < chars.count, chars[j] != ">", !chars[j].isWhitespace {
                            aval.append(chars[j])
                            j += 1
                        }
                    }
                }
                if !aname.isEmpty {
                    attrs.append(XmlAttr(ns: nil, local: aname.lowercased(),
                                         value: decodeHtmlEntities(aval)))
                }
            }

            // Auto-close rules.
            while let top = stack.last, autoClosesTop(top.local, tag) {
                let closed = stack.removeLast()
                attach(.element(closed))
            }
            try bumpNodes()
            let elem = makeHtmlElem(tag: tag, attrs: attrs)
            if voidTags.contains(tag) || selfClosing {
                attach(.element(elem))
            } else {
                if stack.count >= Limits.maxXMLDepth {
                    throw ConvertError.resourceLimit(
                        limit: "max_xml_depth",
                        detail: "HTML nesting exceeds \(Limits.maxXMLDepth)"
                    )
                }
                stack.append(elem)
            }
            i = j
            continue
        }

        // Text run until next '<'.
        var j = i
        var text = ""
        while j < chars.count, chars[j] != "<" {
            text.append(chars[j])
            j += 1
        }
        let decoded = decodeHtmlEntities(text)
        if !decoded.isEmpty {
            try bumpNodes()
            try pushText(decoded)
        }
        i = j
    }

    while let elem = stack.popLast() {
        attach(.element(elem))
    }
    return root
}

private func findSequence(_ chars: [Character], _ needle: String, from: Int) -> Int? {
    let n = Array(needle)
    guard n.count > 0, from + n.count <= chars.count else { return nil }
    var i = from
    while i + n.count <= chars.count {
        var ok = true
        for k in 0..<n.count where chars[i + k] != n[k] {
            ok = false
            break
        }
        if ok { return i }
        i += 1
    }
    return nil
}

private func makeHtmlElem(tag: String, attrs: [XmlAttr]) -> XmlElement {
    XmlElement(ns: tag == "math" ? XmlNS.mathML : nil, local: tag, attrs: attrs)
}

private func stripRawBlocks(_ html: String, _ tag: String) -> String {
    let open = "<\(tag)"
    let close = "</\(tag)>"
    // ASCII-only lowercasing keeps character offsets aligned with `html`.
    let lower = String(html.map { $0.isASCII && $0.isLetter && $0.isUppercase ? Character($0.lowercased()) : $0 })

    // Work in character offsets so `lower` search results slice `html`.
    func hIndex(_ lowerIdx: String.Index) -> String.Index {
        html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: lowerIdx))
    }

    var out = ""
    var pos = lower.startIndex
    while let range = lower[pos...].range(of: open) {
        let start = range.lowerBound
        let afterOpen = lower.index(start, offsetBy: open.count)
        let nextChar = afterOpen < lower.endIndex ? lower[afterOpen] : " "
        if !(nextChar.isWhitespace || nextChar == ">" || nextChar == "/") {
            out += html[hIndex(pos)..<hIndex(afterOpen)]
            pos = afterOpen
            continue
        }
        out += html[hIndex(pos)..<hIndex(start)]
        if let endRange = lower[start...].range(of: close) {
            pos = endRange.upperBound
        } else {
            return out
        }
    }
    out += html[hIndex(pos)...]
    return out
}

// MARK: - Entities

private func decodeHtmlEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = ""
    var rest = s[...]
    while let amp = rest.range(of: "&") {
        out += rest[..<amp.lowerBound]
        let after = rest[amp.upperBound...]
        if let semi = after.range(of: ";"), after.distance(from: after.startIndex, to: semi.lowerBound) <= 32 {
            let name = String(after[..<semi.lowerBound])
            if let decoded = resolveHtmlEntity(name) {
                out += decoded
                rest = after[semi.upperBound...]
                continue
            }
        }
        out.append("&")
        rest = after
    }
    out += rest
    return out
}

func resolveHtmlEntity(_ name: String) -> String? {
    if name.hasPrefix("#x") || name.hasPrefix("#X") {
        let hex = String(name.dropFirst(2))
        guard let v = UInt32(hex, radix: 16), let scalar = UnicodeScalar(v) else { return nil }
        return String(scalar)
    }
    if name.hasPrefix("#") {
        guard let v = UInt32(name.dropFirst()), let scalar = UnicodeScalar(v) else { return nil }
        return String(scalar)
    }
    switch name {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos", "#39": return "'"
    case "nbsp": return "\u{a0}"
    case "ndash": return "–"
    case "mdash": return "—"
    case "lsquo": return "‘"
    case "rsquo": return "’"
    case "ldquo": return "“"
    case "rdquo": return "”"
    case "hellip": return "…"
    case "copy": return "©"
    case "reg": return "®"
    case "trade": return "™"
    case "bull": return "•"
    case "middot": return "·"
    case "times": return "×"
    case "divide": return "÷"
    case "plusmn": return "±"
    case "le": return "≤"
    case "ge": return "≥"
    case "ne": return "≠"
    case "rarr": return "→"
    case "larr": return "←"
    case "harr": return "↔"
    case "euro": return "€"
    case "pound": return "£"
    case "yen": return "¥"
    case "sect": return "§"
    case "para": return "¶"
    default: return nil
    }
}
