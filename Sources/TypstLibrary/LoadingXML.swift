import Foundation
import TypstSyntax
import TypstUtils

// XML loading — port of upstream `loading/xml.rs` plus a minimal
// namespace-aware XML parser covering the roxmltree feature subset
// Typst uses (elements, text, CDATA, comments/PIs skipped, DOCTYPE
// skipped, entity decoding, `allow_dtd`).

/// An XML node. Port of the `convert_xml` output model.
indirect enum XmlNode {
    case text(String)
    case element(XmlElement)
}

struct XmlElement {
    /// Resolved namespace URI, or nil.
    var namespace: String?
    /// Local tag name (no prefix).
    var tag: String
    /// Attributes as (local-name, value) pairs.
    var attrs: [(String, String)]
    var children: [XmlNode]
}

struct XmlParseError: Error {
    /// 1-based line/column at the error position.
    var line: Int
    var col: Int
    var message: String
}

/// Minimal XML parser producing `XmlNode` trees.
struct XmlParser {
    let scalars: [Character]
    var pos = 0
    var line = 1
    var col = 1
    /// Namespace binding stack: each frame maps prefix → URI.
    /// Frame 0 is the implicit `xml` prefix.
    var nsStack: [[(String, String)]] = [[("xml", "http://www.w3.org/XML/1998/namespace")]]

    init(_ text: String) {
        scalars = Array(text)
    }

    mutating func parse() throws -> [XmlNode] {
        var roots: [XmlNode] = []
        while pos < scalars.count {
            if peek() == "<" {
                if match("<!--") {
                    try skipComment()
                } else if match("<?") {
                    try skipPI()
                } else if match("<![CDATA[") {
                    roots.append(.text(try readCDATA()))
                } else if match("<!") {
                    try skipDeclaration()
                } else if match("</") {
                    throw error("unexpected closing tag")
                } else {
                    roots.append(.element(try parseElement()))
                }
            } else {
                roots.append(.text(try readText(until: "<")))
            }
        }
        return roots
    }

    // MARK: - low-level

    func peek(_ ahead: Int = 0) -> Character? {
        pos + ahead < scalars.count ? scalars[pos + ahead] : nil
    }

    func peekStr(_ s: String) -> Bool {
        let chars = Array(s)
        guard pos + chars.count <= scalars.count else { return false }
        for (i, c) in chars.enumerated() where scalars[pos + i] != c {
            return false
        }
        return true
    }

    @discardableResult
    mutating func match(_ s: String) -> Bool {
        guard peekStr(s) else { return false }
        for _ in s { advance() }
        return true
    }

    @discardableResult
    mutating func advance() -> Character? {
        guard pos < scalars.count else { return nil }
        let c = scalars[pos]
        pos += 1
        if c == "\n" { line += 1; col = 1 } else { col += 1 }
        return c
    }

    mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
            advance()
        }
    }

    mutating func error(_ message: String) -> XmlParseError {
        XmlParseError(line: line, col: col, message: message)
    }

    // MARK: - constructs

    mutating func skipComment() throws {
        // Already consumed "<!--".
        while pos < scalars.count {
            if match("-->") { return }
            advance()
        }
        throw error("unterminated comment")
    }

    mutating func skipPI() throws {
        // Already consumed "<?".
        while pos < scalars.count {
            if match("?>") { return }
            advance()
        }
        throw error("unterminated processing instruction")
    }

    mutating func skipDeclaration() throws {
        // Already consumed "<!". Skip to '>' honoring '[...]' subsets
        // (DOCTYPE internal subset may contain '>' inside).
        var depth = 0
        while pos < scalars.count {
            if peek() == "[" { depth += 1 }
            if peek() == "]" { depth = max(depth - 1, 0) }
            if peek() == ">", depth == 0 {
                advance()
                return
            }
            advance()
        }
        throw error("unterminated declaration")
    }

    mutating func readCDATA() throws -> String {
        // Already consumed "<![CDATA[".
        var out = ""
        while pos < scalars.count {
            if match("]]>") { return out }
            out.append(advance()!)
        }
        throw error("unterminated CDATA section")
    }

    /// Read text up to `stop` (a single-char marker). Does not consume
    /// the marker. Entities are decoded.
    mutating func readText(until stop: Character) throws -> String {
        var out = ""
        while let c = peek(), c != stop {
            if c == "&" {
                advance()
                out += try readEntity()
            } else {
                out.append(advance()!)
            }
        }
        return out
    }

    mutating func readEntity() throws -> String {
        var name = ""
        while let c = peek(), c != ";" {
            name.append(advance()!)
            if name.count > 10 { throw error("unterminated entity reference") }
        }
        guard match(";") else { throw error("unterminated entity reference") }
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X"),
               let cp = UInt32(name.dropFirst(2), radix: 16),
               let scalar = Unicode.Scalar(cp) {
                return String(scalar)
            }
            if name.hasPrefix("#"),
               let cp = UInt32(name.dropFirst()),
               let scalar = Unicode.Scalar(cp) {
                return String(scalar)
            }
            throw error("unknown entity reference '&\(name);'")
        }
    }

    /// Parse a qualified name `prefix:local` or `local`.
    func splitQName(_ qname: String) -> (prefix: String?, local: String) {
        if let idx = qname.firstIndex(of: ":") {
            return (String(qname[..<idx]), String(qname[qname.index(after: idx)...]))
        }
        return (nil, qname)
    }

    /// Resolve a prefix to a namespace URI using the binding stack.
    func resolveNS(_ prefix: String?) -> String? {
        let want = prefix ?? ""
        for frame in nsStack.reversed() {
            for (p, uri) in frame where p == want { return uri }
        }
        return nil
    }

    mutating func parseElement() throws -> XmlElement {
        // At '<' of the start tag.
        advance() // consume '<'
        let qname = try readName()
        var local = splitQName(qname)

        // Parse attributes, collecting xmlns bindings for this element.
        var rawAttrs: [(String, String)] = []
        var bindings: [(String, String)] = []
        var selfClosing = false
        while true {
            skipWhitespace()
            guard let c = peek() else { throw error("unterminated start tag") }
            if c == ">" { advance(); break }
            if c == "/" {
                advance()
                guard match(">") else { throw error("expected '>' after '/'") }
                selfClosing = true
                break
            }
            let aname = try readName()
            skipWhitespace()
            guard match("=") else { throw error("expected '=' after attribute name") }
            skipWhitespace()
            guard let quote = peek(), quote == "\"" || quote == "'" else {
                throw error("expected quoted attribute value")
            }
            advance()
            var value = ""
            while let vc = peek(), vc != quote {
                if vc == "&" {
                    advance()
                    value += try readEntity()
                } else {
                    value.append(advance()!)
                }
            }
            guard match(String(quote)) else {
                throw error("unterminated attribute value")
            }
            if aname == "xmlns" {
                bindings.append(("", value))
            } else if aname.hasPrefix("xmlns:") {
                bindings.append((String(aname.dropFirst(6)), value))
            } else {
                rawAttrs.append((aname, value))
            }
        }

        // Push this element's namespace bindings.
        nsStack.append(bindings)
        defer { nsStack.removeLast() }

        // Resolve element namespace.
        let ns = resolveNS(local.prefix)

        // Parse children until matching close tag.
        var children: [XmlNode] = []
        var closed = selfClosing
        if !selfClosing {
            while pos < scalars.count {
                if match("</") {
                    let closing = try readName()
                    skipWhitespace()
                    guard match(">") else {
                        throw error("expected '>' after closing tag")
                    }
                    if closing != qname {
                        throw error(
                            "found closing tag '\(closing)' instead of '\(qname)'")
                    }
                    closed = true
                    break
                }
                if peekStr("<!--") {
                    match("<!--")
                    try skipComment()
                } else if peekStr("<?") {
                    match("<?")
                    try skipPI()
                } else if peekStr("<![CDATA[") {
                    match("<![CDATA[")
                    children.append(.text(try readCDATA()))
                } else if peek() == "<" {
                    children.append(.element(try parseElement()))
                } else {
                    children.append(.text(try readText(until: "<")))
                }
            }
            if !closed {
                throw error("unterminated element '\(qname)'")
            }
        }

        // Attributes keep local names (roxmltree `attr.name()`).
        let attrs = rawAttrs.map { (splitQName($0.0).local, $0.1) }
        return XmlElement(namespace: ns, tag: local.local,
                          attrs: attrs, children: children)
    }

    /// Read an XML name (NameStartChar..NameChar approximation:
    /// anything except whitespace and markup delimiters).
    mutating func readName() throws -> String {
        var name = ""
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" || c == "\r"
                || c == ">" || c == "/" || c == "=" || c == "?"
                || c == "<" || c == "&" {
                break
            }
            name.append(advance()!)
        }
        guard !name.isEmpty else { throw error("expected name") }
        return name
    }
}

/// Convert an `XmlNode` tree to a Typst `Value`.
/// Port of upstream `convert_xml`.
func convertXML(_ node: XmlNode) -> Value {
    switch node {
    case .text(let t):
        return .str(Str(t))
    case .element(let el):
        var children = ArrayValue()
        children.items = el.children.map(convertXML)
        var attrs = Dict()
        for (name, value) in el.attrs {
            attrs.insert(name, .str(Str(value)))
        }
        var dict = Dict()
        dict.insert("namespace",
                    el.namespace.map { Value.str(Str($0)) } ?? .none)
        dict.insert("tag", .str(Str(el.tag)))
        dict.insert("attrs", .dict(attrs))
        dict.insert("children", .array(children))
        return .dict(dict)
    }
}

/// `xml(source)` — port of upstream `xml`.
let xmlFunc = nativeFunc(
    "xml",
    title: "XML",
    since: .forever,
    docs: "Reads structured data from an XML file.",
    params: [
        NativeParamInfo(name: "source", input: DataSource.input, required: true),
    ],
    returns: Value.output
) { engine, _, args in
    let source: Spanned<DataSource, Span> = try args.expectT("source")
    try args.finishT()
    let loaded = try load(source, engine.world)
    let text = try loadedToStr(loaded)
    var parser = XmlParser(text.value)
    do {
        // roxmltree parses a single root; extra roots are an error.
        let nodes = try parser.parse()
        // Non-whitespace text outside the root is a parse error
        // (upstream roxmltree rejects junk after the document element).
        for node in nodes {
            if case .text(let t) = node, !t.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
                throw XmlParseError(line: 1, col: 1,
                                    message: "unexpected text outside root element")
            }
        }
        let elements = nodes.filter {
            if case .element = $0 { return true }
            return false
        }
        guard elements.count == 1 else {
            throw XmlParseError(line: 1, col: 1,
                                message: "XML document must have exactly one root element")
        }
        // `convert_xml(document.root())` → is_root → Array(children):
        // the top-level node list becomes the result array.
        var out = ArrayValue()
        out.items = nodes.map(convertXML)
        return out
    } catch let e as XmlParseError {
        throw SourceDiagnostics([LoadError.text(
            ReportTextPos.lineCol(.oneBased(e.line, e.col)),
            "failed to parse XML", e.message).within(loaded)])
    }
}
