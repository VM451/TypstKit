import Foundation

/// Input format. Selects the parser; container variants that share a parser
/// (`.docm`, `.xlsm`, `.ppsx`, ...) map onto these via `Format.detect` or
/// `Format.fromExtension`.
enum Format: Sendable {
    /// Binary Word 97-2003 (`.doc`).
    case doc
    /// WordprocessingML (`.docx`, `.docm`, `.dotx`, `.dotm`), Transitional and Strict.
    case docx
    /// OpenDocument Text (`.odt`, `.ott`).
    case odt
    /// Portable Document Format (`.pdf`).
    case pdf
    /// Binary PowerPoint 97-2003 (`.ppt`, `.pps`, `.pot`).
    case ppt
    /// PresentationML (`.pptx`, `.pptm`, `.ppsx`, `.ppsm`, `.potx`).
    case pptx
    /// Rich Text Format (`.rtf`).
    case rtf
    /// EPUB 2 and 3 (`.epub`).
    case epub
    /// Excel workbooks: `.xlsx`, `.xlsm`, binary `.xlsb`, and legacy `.xls`.
    case excel
    /// OpenDocument Spreadsheet (`.ods`, `.ots`).
    case ods
    /// OpenDocument Presentation (`.odp`, `.otp`).
    case odp
    /// Comma/semicolon/pipe/tab delimiter-separated values (`.csv`).
    case csv
    /// Tab-separated values (`.tsv`, `.tab`).
    case tsv
    /// CommonMark and GitHub-Flavored Markdown (`.md`, `.markdown`, `.mdx`).
    case markdown
    /// HTML5 and XHTML documents (`.html`, `.htm`, `.xhtml`).
    case html
    /// LaTeX source documents (`.tex`, `.latex`, `.ltx`).
    case latex
    /// Structured JSON data (`.json`).
    case json
    /// Plain text (`.txt`, `.text`).
    case text

    /// Detect the format from content bytes. Signature-less text formats
    /// return `nil`.
    static func detect(from bytes: [UInt8]) -> Format? {
        Detect.fromBytes(bytes)
    }

    /// The format a bare extension names (with or without a leading dot),
    /// matched case-insensitively.
    static func fromExtension(_ ext: String) -> Format? {
        switch ext.drop(while: { $0 == "." }).lowercased() {
        case "doc": return .doc
        case "docx", "docm", "dotx", "dotm": return .docx
        case "odt", "ott": return .odt
        case "pdf": return .pdf
        case "pptx", "pptm", "ppsx", "ppsm", "potx": return .pptx
        case "ppt", "pps", "pot": return .ppt
        case "rtf": return .rtf
        case "epub": return .epub
        case "xlsx", "xlsm", "xlsb", "xls", "xltx": return .excel
        case "ods", "ots": return .ods
        case "odp", "otp": return .odp
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        case "md", "markdown", "mdx": return .markdown
        case "html", "htm", "xhtml": return .html
        case "tex", "latex", "ltx": return .latex
        case "json": return .json
        case "txt", "text": return .text
        default: return nil
        }
    }

    static func fromPath(_ path: String) -> Format? {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : fromExtension(ext)
    }

    /// Canonical short format name.
    var asString: String {
        switch self {
        case .doc: return "doc"
        case .docx: return "docx"
        case .odt: return "odt"
        case .pdf: return "pdf"
        case .ppt: return "ppt"
        case .pptx: return "pptx"
        case .rtf: return "rtf"
        case .epub: return "epub"
        case .excel: return "xlsx"
        case .ods: return "ods"
        case .odp: return "odp"
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .markdown: return "md"
        case .html: return "html"
        case .latex: return "tex"
        case .json: return "json"
        case .text: return "txt"
        }
    }
}

/// Content-based format detection (port of `formats/detect.rs`).
enum Detect {
    private static let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let ctNS = "http://schemas.openxmlformats.org/package/2006/content-types"
    private static let manifestNS = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
    private static let spreadsheetNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    static func fromBytes(_ bytes: [UInt8]) -> Format? {
        if bytes.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]) { // `{\rtf`
            return .rtf
        }
        if bytes.starts(with: oleMagic) {
            return detectOle(bytes)
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return detectZip(bytes)
        }
        let head = bytes.prefix(1024)
        if head.count >= 5 {
            for i in 0...(head.count - 5) {
                let a = head[head.index(head.startIndex, offsetBy: i)]
                let b = head[head.index(head.startIndex, offsetBy: i + 1)]
                let c = head[head.index(head.startIndex, offsetBy: i + 2)]
                let d = head[head.index(head.startIndex, offsetBy: i + 3)]
                let e = head[head.index(head.startIndex, offsetBy: i + 4)]
                if a == 0x25, b == 0x50, c == 0x44, d == 0x46, e == 0x2D {
                    return .pdf // `%PDF-`
                }
            }
        }
        if looksLikeHTML(bytes) {
            return .html
        }
        return nil
    }

    private static func looksLikeHTML(_ bytes: [UInt8]) -> Bool {
        var head = Array(bytes.prefix(512))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { head.removeFirst(3) }
        guard let s = String(bytes: head, encoding: .utf8) else { return false }
        let trimmed = s.drop(while: { $0.isWhitespace })
        let lower = trimmed.lowercased()
        return lower.hasPrefix("<!doctype html")
            || lower.hasPrefix("<html ")
            || lower.hasPrefix("<html>")
            || lower.hasPrefix("<html\t")
            || lower.hasPrefix("<html\r")
            || lower.hasPrefix("<html\n")
    }

    /// Classify an OLE compound file by its mandated content stream.
    private static func detectOle(_ bytes: [UInt8]) -> Format? {
        guard let ole = try? OleFile(bytes: bytes) else { return nil }
        for name in ole.topLevelNames() {
            if name.caseInsensitiveCompare("WordDocument") == .orderedSame {
                return .doc
            }
            if name.caseInsensitiveCompare("PowerPoint Document") == .orderedSame {
                return .ppt
            }
            if name.caseInsensitiveCompare("Workbook") == .orderedSame
                || name.caseInsensitiveCompare("Book") == .orderedSame {
                return .excel
            }
        }
        return nil
    }

    private static func detectZip(_ bytes: [UInt8]) -> Format? {
        guard let pkg = try? Package(bytes: bytes) else { return nil }

        // ODF and EPUB designate the `mimetype` part as the package identity.
        if let mimeData = try? pkg.part("mimetype"),
           let mime = String(bytes: mimeData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return mimetypeFormat(mime)
        }

        // OPC: the package-level officeDocument relationship designates the
        // main part; its content type names the document kind.
        if let rels = try? readRels(pkg, "_rels/.rels"),
           let rel = rels.firstOfType(RelType.officeDocument),
           let target = try? resolvePackageTarget("", rel.target) {
            if let types = try? pkg.optionalXMLPart("[Content_Types].xml"),
               let ct = contentTypeOf(types, part: target.path),
               let format = opcFormat(ct) {
                return format
            }
            // Content types can be stale or generic; the main part's mandated
            // root element is the next authority.
            if let tree = try? pkg.optionalXMLPart(target.path),
               let root = tree.childElems.first,
               let format = rootElementFormat(root) {
                return format
            }
            return opcFormatByPath(target.path)
        }

        // Packages with no usable rels: conventional main-part locations.
        for (part, format) in [
            ("word/document.xml", Format.docx),
            ("ppt/presentation.xml", Format.pptx),
            ("xl/workbook.xml", Format.excel),
            ("xl/workbook.bin", Format.excel),
        ] where pkg.hasPart(part) {
            return format
        }

        // ODF without its mandatory `mimetype`: the manifest's root file entry.
        if let manifest = try? pkg.optionalXMLPart("META-INF/manifest.xml"),
           let root = manifest.descendants(manifestNS, "file-entry")
               .first(where: { $0.attr(manifestNS, "full-path") == "/" }),
           let mime = root.attr(manifestNS, "media-type") {
            return mimetypeFormat(mime.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // EPUB without its mandatory `mimetype`: the OCF container descriptor.
        if pkg.hasPart("META-INF/container.xml") {
            return .epub
        }

        return nil
    }

    private static func mimetypeFormat(_ mime: String) -> Format? {
        var mime = mime
        if mime.hasSuffix("-template") { mime = String(mime.dropLast("-template".count)) }
        switch mime {
        case "application/epub+zip": return .epub
        case "application/vnd.oasis.opendocument.text": return .odt
        case "application/vnd.oasis.opendocument.spreadsheet": return .ods
        case "application/vnd.oasis.opendocument.presentation": return .odp
        default: return nil
        }
    }

    /// Resolve a part's content type per OPC: an `Override` for the exact
    /// part name wins, else the `Default` for its extension.
    private static func contentTypeOf(_ types: XmlElement, part: String) -> String? {
        let partName = "/" + part
        if let ct = types.descendants(ctNS, "Override")
            .first(where: { $0.attrAny("PartName")?.caseInsensitiveCompare(partName) == .orderedSame })
            .flatMap({ $0.attrAny("ContentType") }) {
            return ct
        }
        guard let ext = part.split(separator: ".").last else { return nil }
        return types.descendants(ctNS, "Default")
            .first(where: { $0.attrAny("Extension")?.caseInsensitiveCompare(String(ext)) == .orderedSame })
            .flatMap { $0.attrAny("ContentType") }
    }

    /// Map a main-part content type onto its parser.
    private static func opcFormat(_ contentType: String) -> Format? {
        let ct = contentType.lowercased()
        if ct.contains("wordprocessingml") { return .docx }
        if ct.contains("presentationml") { return .pptx }
        if ct.contains("spreadsheetml") || ct.contains("ms-excel") { return .excel }
        return nil
    }

    /// Each OOXML main part has a mandated root element; its namespace names
    /// the format.
    private static func rootElementFormat(_ root: XmlElement) -> Format? {
        switch root.ns {
        case XmlNS.w: return .docx
        case XmlNS.p: return .pptx
        case spreadsheetNS: return .excel
        default: return nil
        }
    }

    private static func opcFormatByPath(_ part: String) -> Format? {
        if part.hasPrefix("word/") { return .docx }
        if part.hasPrefix("ppt/") { return .pptx }
        if part.hasPrefix("xl/") { return .excel }
        return nil
    }
}
