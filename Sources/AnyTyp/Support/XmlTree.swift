import Foundation

/// Well-known namespace URIs.
enum XmlNS {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    static let wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let chart = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let dgm = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let sml = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let pkgRels = "http://schemas.openxmlformats.org/package/2006/relationships"

    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    static let draw = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    static let style = "urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    static let fo = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
    static let presentation = "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
    static let manifest = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
    static let xlink = "http://www.w3.org/1999/xlink"
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let svgCompat = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
    static let form = "urn:oasis:names:tc:opendocument:xmlns:form:1.0"

    static let vml = "urn:schemas-microsoft-com:vml"
    static let oVml = "urn:schemas-microsoft-com:office:office"
    static let xVml = "urn:schemas-microsoft-com:office:excel"
    static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    static let wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
    static let a14 = "http://schemas.microsoft.com/office/drawing/2010/main"

    static let m = "http://schemas.openxmlformats.org/officeDocument/2006/math"
    static let mathML = "http://www.w3.org/1998/Math/MathML"
}

/// One attribute on an `XmlElement`.
struct XmlAttr {
    /// Resolved namespace URI; `nil` for unqualified attributes.
    var ns: String?
    var local: String
    var value: String
}

enum XmlNode {
    case element(XmlElement)
    case text(String)
}

/// A DOM element with namespace-resolved names.
final class XmlElement {
    /// Resolved namespace URI; `nil` for unqualified names.
    let ns: String?
    let local: String
    var attrs: [XmlAttr]
    var children: [XmlNode] = []

    init(ns: String?, local: String, attrs: [XmlAttr]) {
        self.ns = ns
        self.local = local
        self.attrs = attrs
    }

    func `is`(_ ns: String, _ local: String) -> Bool {
        self.local == local && self.ns == ns
    }

    /// Same-vocabulary attribute lookup: the qualified attribute wins, and an
    /// explicitly unqualified one with the same local name is accepted as a
    /// deliberate leniency. Lookups in a *different* vocabulary than the
    /// element's must use `attrQualified`, where that fallback would
    /// misattribute.
    func attr(_ ns: String, _ local: String) -> String? {
        attrQualified(ns, local) ?? attrUnqualified(local)
    }

    /// Strictly namespace-qualified attribute lookup, no fallback.
    func attrQualified(_ ns: String, _ local: String) -> String? {
        attrs.first { $0.local == local && $0.ns == ns }?.value
    }

    /// Explicitly unqualified attribute lookup (no namespace), no fallback.
    func attrUnqualified(_ local: String) -> String? {
        attrs.first { $0.local == local && $0.ns == nil }?.value
    }

    /// Attribute by local name regardless of namespace. For elements whose
    /// vocabulary is unambiguous in context (relationships, container files).
    func attrAny(_ local: String) -> String? {
        attrs.first { $0.local == local }?.value
    }

    var childElems: [XmlElement] {
        children.compactMap { if case .element(let e) = $0 { return e }; return nil }
    }

    func find(_ ns: String, _ local: String) -> XmlElement? {
        childElems.first { $0.is(ns, local) }
    }

    func findAll(_ ns: String, _ local: String) -> [XmlElement] {
        childElems.filter { $0.is(ns, local) }
    }

    /// All descendant nodes (elements and text), depth-first in document
    /// order, iteratively (deep DOMs must not overflow the call stack).
    func descendantNodes() -> DescendantNodes {
        var stack = children
        stack.reverse()
        return DescendantNodes(stack: stack)
    }

    /// All descendant elements, depth-first in document order.
    func descendantElems() -> [XmlElement] {
        descendantNodes().compactMap { node in
            if case .element(let e) = node { return e }
            return nil
        }
    }

    /// First descendant with the given name, depth-first.
    func firstDescendant(_ ns: String, _ local: String) -> XmlElement? {
        descendantElems().first { $0.is(ns, local) }
    }

    /// All descendants with the given name, in document order.
    func descendants(_ ns: String, _ local: String) -> [XmlElement] {
        descendantElems().filter { $0.is(ns, local) }
    }

    /// All descendants matching a local name regardless of namespace, in
    /// document order. For vocabularies where the namespace varies across
    /// producers (EPUB container/OPF metadata).
    func descendantsAny(_ local: String) -> [XmlElement] {
        descendantElems().filter { $0.local == local }
    }

    /// Concatenated text of all descendant text nodes.
    var text: String {
        var out = ""
        for node in descendantNodes() {
            if case .text(let t) = node {
                out += t
            }
        }
        return out
    }
}

/// Iterative depth-first traversal over a subtree's nodes.
struct DescendantNodes {
    var stack: [XmlNode]

    mutating func next() -> XmlNode? {
        guard let node = stack.popLast() else { return nil }
        if case .element(let e) = node {
            let start = stack.count
            stack.append(contentsOf: e.children)
            stack[start...].reverse()
        }
        return node
    }
}

extension DescendantNodes: IteratorProtocol {
    func makeIterator() -> DescendantNodes { self }
}

extension DescendantNodes: Sequence {}

extension XmlElement {
    /// Convenience: iterate descendant elements without materializing arrays.
    func forEachDescendantElement(_ body: (XmlElement) -> Void) {
        for node in descendantNodes() {
            if case .element(let e) = node {
                body(e)
            }
        }
    }
}

/// ISO/IEC 29500 *Strict* namespace and relationship-type URIs are the
/// Transitional ones re-rooted under `http://purl.oclc.org/ooxml/` with the
/// `2006` version segment dropped. Normalizing to the Transitional family at
/// parse time lets the rest of the crate match a single set of constants.
func normalizeOoxmlURI(_ uri: String) -> String? {
    guard uri.hasPrefix("http://purl.oclc.org/ooxml/") else { return nil }
    let rest = String(uri.dropFirst("http://purl.oclc.org/ooxml/".count))
    let parts = rest.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return "http://schemas.openxmlformats.org/\(parts[0])/2006/\(parts[1])"
}

/// Parse an XML part into a synthetic root element containing the top-level
/// nodes. Encoding comes from the BOM or XML declaration; the part is
/// transcoded to UTF-8 before parsing so namespace resolution sees one
/// consistent encoding.
func parseXML(_ bytes: [UInt8]) throws -> XmlElement {
    let utf8 = xmlToUTF8(bytes)
    var parser = XmlParser(bytes: utf8)
    return try parser.parse()
}

func parseXML(_ data: Data) throws -> XmlElement {
    try parseXML([UInt8](data))
}

/// Transcode an XML part to UTF-8 based on its BOM or encoding declaration.
private func xmlToUTF8(_ bytes: [UInt8]) -> [UInt8] {
    if bytes.count >= 2 {
        if bytes[0] == 0xFF, bytes[1] == 0xFE {
            // UTF-16LE with BOM: strip the BOM, decode the rest.
            return transcode(Array(bytes.dropFirst(2)), encoding: .utf16LittleEndian)
        }
        if bytes[0] == 0xFE, bytes[1] == 0xFF {
            return transcode(Array(bytes.dropFirst(2)), encoding: .utf16BigEndian)
        }
    }
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
        return Array(bytes[3...])
    }
    // Sniff a non-UTF-8 encoding declaration in the XML prolog.
    let head = Array(bytes.prefix(200))
    if let label = declaredXMLEncoding(head),
       let encoding = ianaEncoding(label),
       encoding != .utf8 {
        return transcode(bytes, encoding: encoding)
    }
    return bytes
}

private func transcode(_ bytes: [UInt8], encoding: String.Encoding) -> [UInt8] {
    if let s = String(data: Data(bytes), encoding: encoding) {
        return [UInt8](s.utf8)
    }
    // Lossy fallback: interpret as UTF-8 with replacement.
    return [UInt8](String(decoding: bytes, as: UTF8.self).utf8)
}

private func declaredXMLEncoding(_ head: [UInt8]) -> String? {
    guard let s = String(bytes: head, encoding: .utf8),
          let range = s.range(of: "encoding") else { return nil }
    var rest = s[range.upperBound...]
    rest = rest.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    guard rest.first == "=" else { return nil }
    rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
    guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
    rest = rest.dropFirst()
    guard let end = rest.firstIndex(of: quote) else { return nil }
    return String(rest[..<end])
}

/// Map an IANA charset label (XML encoding declaration) to a String.Encoding.
private func ianaEncoding(_ label: String) -> String.Encoding? {
    let trimmed = label.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let cfLabel = trimmed as CFString
    let cfEnc = CFStringConvertIANACharSetNameToEncoding(cfLabel)
    guard cfEnc != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
}

/// Byte-level pull parser producing the namespace-aware DOM.
private struct XmlParser {
    let bytes: [UInt8]
    var pos = 0
    var stack: [XmlElement] = []
    let root = XmlElement(ns: nil, local: "", attrs: [XmlAttr]())
    var nodeCount = 0
    var recovered = false
    /// Namespace scopes: each entry maps prefix -> URI for one open element.
    var nsScopes: [[String: String]] = [[:]]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parse() throws -> XmlElement {
        while pos < bytes.count {
            // Text run up to the next '<'.
            if bytes[pos] != UInt8(ascii: "<") {
                let start = pos
                while pos < bytes.count, bytes[pos] != UInt8(ascii: "<") {
                    pos += 1
                }
                let raw = String(decoding: bytes[start..<pos], as: UTF8.self)
                if !raw.isEmpty {
                    try bumpNodes()
                    pushText(decodeTextEntities(raw))
                }
                continue
            }

            // Markup.
            if pos + 1 >= bytes.count {
                pos += 1
                continue
            }
            let next = bytes[pos + 1]
            if next == UInt8(ascii: "?") {
                skipProcessingInstruction()
            } else if next == UInt8(ascii: "!") {
                try skipMarkupDeclaration()
            } else if next == UInt8(ascii: "/") {
                try parseEndTag()
            } else if next == UInt8(ascii: ">") {
                pos += 2 // stray '<>'
            } else {
                try parseStartTag()
            }
        }

        if !stack.isEmpty {
            recovered = true
            while let elem = stack.popLast() {
                popScope()
                attach(.element(elem))
            }
        }
        if recovered {
            AnyTypLog.warn("recovered malformed xml (unclosed or mismatched elements)")
        }
        return root
    }

    private mutating func bumpNodes() throws {
        nodeCount += 1
        if nodeCount > Limits.maxXMLNodes {
            throw ConvertError.resourceLimit(
                limit: "max_xml_nodes",
                detail: "part exceeds \(Limits.maxXMLNodes) xml nodes"
            )
        }
    }

    private mutating func skipProcessingInstruction() {
        // '<?' ... '?>'
        pos += 2
        while pos + 1 < bytes.count {
            if bytes[pos] == UInt8(ascii: "?"), bytes[pos + 1] == UInt8(ascii: ">") {
                pos += 2
                return
            }
            pos += 1
        }
        pos = bytes.count
    }

    private mutating func skipMarkupDeclaration() throws {
        // '<!--' comment, '<![CDATA[' section, '<!DOCTYPE' (or other) declaration.
        if pos + 3 < bytes.count,
           bytes[pos + 2] == UInt8(ascii: "-"), bytes[pos + 3] == UInt8(ascii: "-") {
            // Comment: find '-->'.
            pos += 4
            while pos + 2 < bytes.count {
                if bytes[pos] == UInt8(ascii: "-"), bytes[pos + 1] == UInt8(ascii: "-"),
                   bytes[pos + 2] == UInt8(ascii: ">") {
                    pos += 3
                    return
                }
                pos += 1
            }
            pos = bytes.count
            return
        }
        if pos + 8 < bytes.count,
           bytes[pos + 2] == UInt8(ascii: "["), bytes[pos + 3] == UInt8(ascii: "C"),
           bytes[pos + 4] == UInt8(ascii: "D"), bytes[pos + 5] == UInt8(ascii: "A"),
           bytes[pos + 6] == UInt8(ascii: "T"), bytes[pos + 7] == UInt8(ascii: "A"),
           bytes[pos + 8] == UInt8(ascii: "[") {
            // CDATA: find ']]>'.
            pos += 9
            let start = pos
            while pos + 2 < bytes.count {
                if bytes[pos] == UInt8(ascii: "]"), bytes[pos + 1] == UInt8(ascii: "]"),
                   bytes[pos + 2] == UInt8(ascii: ">") {
                    break
                }
                pos += 1
            }
            let text = String(decoding: bytes[start..<min(pos, bytes.count)], as: UTF8.self)
            try bumpNodes()
            pushText(text)
            pos = min(pos + 3, bytes.count)
            return
        }
        // DOCTYPE or other declaration: skip to '>' honoring '[...]' subsets
        // and quoted strings.
        pos += 2
        var bracketDepth = 0
        var quote: UInt8 = 0
        while pos < bytes.count {
            let b = bytes[pos]
            if quote != 0 {
                if b == quote { quote = 0 }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == UInt8(ascii: "[") {
                bracketDepth += 1
            } else if b == UInt8(ascii: "]") {
                bracketDepth = max(0, bracketDepth - 1)
            } else if b == UInt8(ascii: ">"), bracketDepth == 0 {
                pos += 1
                return
            }
            pos += 1
        }
    }

    private mutating func parseEndTag() throws {
        // '</name>' — capture the local name for mismatch detection, then
        // consume through '>'.
        pos += 2
        let nameStart = pos
        while pos < bytes.count, bytes[pos] != UInt8(ascii: ">"),
              bytes[pos] != UInt8(ascii: "/"), bytes[pos] != UInt8(ascii: "?") {
            pos += 1
        }
        let rawEndName = String(decoding: bytes[nameStart..<pos], as: UTF8.self)
        if pos < bytes.count {
            pos += 1 // '>'
        }
        let endLocal = rawEndName.split(separator: ":").last.map(String.init) ?? rawEndName
        guard let elem = stack.popLast() else {
            recovered = true
            return
        }
        popScope()
        if elem.local != endLocal {
            recovered = true
        }
        attach(.element(elem))
    }

    private mutating func parseStartTag() throws {
        // '<name attr="v" ...>' or '<name .../>'
        pos += 1 // consume '<'
        let nameStart = pos
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: ">") || b == UInt8(ascii: "/") || b == UInt8(ascii: " ") ||
               b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r") {
                break
            }
            pos += 1
        }
        let rawName = String(decoding: bytes[nameStart..<pos], as: UTF8.self)
        guard !rawName.isEmpty else {
            // Lone '<' followed by junk: skip the '<'.
            return
        }

        if stack.count >= Limits.maxXMLDepth {
            throw ConvertError.resourceLimit(
                limit: "max_xml_depth",
                detail: "element nesting exceeds \(Limits.maxXMLDepth)"
            )
        }
        try bumpNodes()

        // Collect raw attributes + xmlns declarations for scope building.
        var rawAttrs: [(name: String, value: String)] = []
        var selfClosing = false
        while pos < bytes.count {
            skipWhitespace()
            if pos >= bytes.count { break }
            let b = bytes[pos]
            if b == UInt8(ascii: ">") {
                pos += 1
                break
            }
            if b == UInt8(ascii: "/") {
                pos += 1
                skipWhitespace()
                if pos < bytes.count, bytes[pos] == UInt8(ascii: ">") {
                    pos += 1
                    selfClosing = true
                    break
                }
                continue
            }
            // Attribute name.
            let attrNameStart = pos
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "=") || c == UInt8(ascii: ">") || c == UInt8(ascii: "/") ||
                   c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") ||
                   c == UInt8(ascii: "\r") {
                    break
                }
                pos += 1
            }
            let attrName = String(decoding: bytes[attrNameStart..<pos], as: UTF8.self)
            skipWhitespace()
            var attrValue = ""
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "=") {
                pos += 1
                skipWhitespace()
                if pos < bytes.count,
                   bytes[pos] == UInt8(ascii: "\"") || bytes[pos] == UInt8(ascii: "'") {
                    let quote = bytes[pos]
                    pos += 1
                    let valStart = pos
                    while pos < bytes.count, bytes[pos] != quote {
                        pos += 1
                    }
                    attrValue = String(decoding: bytes[valStart..<pos], as: UTF8.self)
                    if pos < bytes.count { pos += 1 } // closing quote
                }
            }
            if !attrName.isEmpty {
                rawAttrs.append((attrName, attrValue))
            }
        }

        // Build namespace scope: parent scope + this element's xmlns decls.
        var scope = nsScopes.last ?? [:]
        var storedAttrs: [(String, String)] = []
        storedAttrs.reserveCapacity(rawAttrs.count)
        for (name, value) in rawAttrs {
            if name == "xmlns" {
                scope[""] = value
                continue
            }
            if name.hasPrefix("xmlns:") {
                let prefix = String(name.dropFirst(6))
                scope[prefix] = value
                continue
            }
            storedAttrs.append((name, value))
        }
        // Resolve attribute namespaces now that scope is complete.
        var attrs: [XmlAttr] = []
        attrs.reserveCapacity(storedAttrs.count)
        for (name, value) in storedAttrs {
            let normalized = normalizeAttrValue(value)
            if let colon = name.firstIndex(of: ":") {
                let prefix = String(name[..<colon])
                let local = String(name[name.index(after: colon)...])
                let uri = resolvePrefix(prefix, scope: scope)
                attrs.append(XmlAttr(ns: uri, local: local, value: normalized))
            } else {
                attrs.append(XmlAttr(ns: nil, local: name, value: normalized))
            }
        }

        // Resolve element name.
        let (elemNs, elemLocal): (String?, String)
        if let colon = rawName.firstIndex(of: ":") {
            let prefix = String(rawName[..<colon])
            let local = String(rawName[rawName.index(after: colon)...])
            elemNs = resolvePrefix(prefix, scope: scope)
            elemLocal = local
        } else {
            // Unprefixed element names take the default namespace.
            elemNs = scope[""].flatMap { $0.isEmpty ? nil : $0 }
            elemLocal = rawName
        }

        let element = XmlElement(ns: elemNs, local: elemLocal, attrs: attrs)

        // mc:Choice/@Requires holds namespace *prefixes* evaluated in the
        // element's lexical scope. Resolve them to URIs here, where the scope
        // is known.
        if elemLocal == "Choice", elemNs == XmlNS.mc,
           let idx = element.attrs.firstIndex(where: { $0.local == "Requires" }) {
            let resolved = element.attrs[idx].value
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .map { prefix -> String in
                    let p = String(prefix)
                    if let uri = resolvePrefix(p, scope: scope) {
                        return normalizeOoxmlURI(uri) ?? uri
                    }
                    return p
                }
                .joined(separator: " ")
            element.attrs[idx].value = resolved
        }

        if selfClosing {
            // Empty element: attach without pushing scope.
            attach(.element(element))
        } else {
            stack.append(element)
            nsScopes.append(scope)
        }
    }

    private func resolvePrefix(_ prefix: String, scope: [String: String]) -> String? {
        if prefix == "xml" { return XmlNS.xml }
        if prefix == "xmlns" { return nil }
        return scope[prefix]
    }

    private mutating func popScope() {
        if nsScopes.count > 1 {
            nsScopes.removeLast()
        }
    }

    private mutating func attach(_ node: XmlNode) {
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root.children.append(node)
        }
    }

    private mutating func pushText(_ text: String) {
        if text.isEmpty { return }
        if let parent = stack.last {
            if case .text(let prev) = parent.children.last {
                // Merge with previous text node.
                var merged = prev
                merged += text
                parent.children[parent.children.count - 1] = .text(merged)
                return
            }
            parent.children.append(.text(text))
        } else {
            if case .text(let prev) = root.children.last {
                var merged = prev
                merged += text
                root.children[root.children.count - 1] = .text(merged)
                return
            }
            root.children.append(.text(text))
        }
    }

    private mutating func skipWhitespace() {
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n") ||
               b == UInt8(ascii: "\r") {
                pos += 1
            } else {
                return
            }
        }
    }
}

// MARK: - Entity decoding

/// Decode XML entities and character references in text content.
private func decodeTextEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = ""
    out.reserveCapacity(text.count)
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c != "&" {
            out.append(c)
            i = text.index(after: i)
            continue
        }
        // Find ';'
        var j = text.index(after: i)
        var found = false
        while j < text.endIndex {
            if text[j] == ";" { found = true; break }
            if text[j] == "&" || text[j] == "<" { break }
            j = text.index(after: j)
        }
        guard found else {
            out.append("&")
            i = text.index(after: i)
            continue
        }
        let name = String(text[text.index(after: i)..<j])
        if let resolved = resolveXMLEntity(name) {
            out.append(resolved)
        } else {
            out.append("&\(name);")
        }
        i = text.index(after: j)
    }
    return out
}

/// Attribute-value normalization: entity/charref decoding plus the
/// CDATA-level whitespace normalization (literal tab/LF/CR become spaces).
private func normalizeAttrValue(_ value: String) -> String {
    guard value.contains("&") || value.contains("\t") || value.contains("\n") ||
          value.contains("\r") else {
        return value
    }
    var out = ""
    out.reserveCapacity(value.count)
    var i = value.startIndex
    while i < value.endIndex {
        let c = value[i]
        if c == "\t" || c == "\n" || c == "\r" {
            out.append(" ")
            i = value.index(after: i)
            continue
        }
        if c != "&" {
            out.append(c)
            i = value.index(after: i)
            continue
        }
        var j = value.index(after: i)
        var found = false
        while j < value.endIndex {
            if value[j] == ";" { found = true; break }
            if value[j] == "&" || value[j] == "<" { break }
            j = value.index(after: j)
        }
        guard found else {
            out.append("&")
            i = value.index(after: i)
            continue
        }
        let name = String(value[value.index(after: i)..<j])
        if let resolved = resolveXMLEntity(name) {
            out.append(resolved)
        } else {
            out.append("&\(name);")
        }
        i = value.index(after: j)
    }
    return out
}

/// Resolve entity references: numeric character references plus the named
/// entities XML and HTML producers actually emit.
private func resolveXMLEntity(_ name: String) -> String? {
    if name.hasPrefix("#") {
        let num = name.dropFirst()
        let code: UInt32?
        if num.hasPrefix("x") || num.hasPrefix("X") {
            code = UInt32(num.dropFirst(), radix: 16)
        } else {
            code = UInt32(num)
        }
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        return String(scalar)
    }
    let ch: Character? = switch name {
    case "amp": "&"
    case "lt": "<"
    case "gt": ">"
    case "apos": "'"
    case "quot": "\""
    case "nbsp": "\u{a0}"
    case "shy": "\u{ad}"
    case "mdash": "\u{2014}"
    case "ndash": "\u{2013}"
    case "lsquo": "\u{2018}"
    case "rsquo": "\u{2019}"
    case "ldquo": "\u{201c}"
    case "rdquo": "\u{201d}"
    case "hellip": "\u{2026}"
    case "copy": "\u{a9}"
    case "reg": "\u{ae}"
    case "trade": "\u{2122}"
    case "deg": "\u{b0}"
    case "middot": "\u{b7}"
    case "bull": "\u{2022}"
    case "sect": "\u{a7}"
    case "para": "\u{b6}"
    case "laquo": "\u{ab}"
    case "raquo": "\u{bb}"
    case "times": "\u{d7}"
    case "divide": "\u{f7}"
    case "plusmn": "\u{b1}"
    case "frac12": "\u{bd}"
    case "frac14": "\u{bc}"
    case "eacute": "\u{e9}"
    case "egrave": "\u{e8}"
    case "agrave": "\u{e0}"
    case "ccedil": "\u{e7}"
    case "uuml": "\u{fc}"
    case "ouml": "\u{f6}"
    case "auml": "\u{e4}"
    case "szlig": "\u{df}"
    case "aring": "\u{e5}"
    case "oslash": "\u{f8}"
    case "aelig": "\u{e6}"
    case "euro": "\u{20ac}"
    case "pound": "\u{a3}"
    case "yen": "\u{a5}"
    case "cent": "\u{a2}"
    default: nil
    }
    return ch.map(String.init)
}
