import Foundation

/// OpenDocument Text (.odt), Spreadsheet (.ods), and Presentation (.odp)
/// frontend (port of `formats/odf/mod.rs`).
enum OdfFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let pkg: Package
        do {
            pkg = try Package(bytes: bytes)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }

        do {
            if try isEncrypted(pkg) { return .failure(.encrypted) }

            // styles.xml is optional; corrupt -> skipped (default styling).
            let stylesTree = try pkg.optionalXMLPart("styles.xml")
            let contentTree = try pkg.requiredXMLPart("content.xml")

            let styles = OdfStyles()
            if let stylesTree { styles.collect(stylesTree) }
            styles.collect(contentTree)

            guard let docContent = contentTree.find(XmlNS.office, "document-content"),
                  let body = docContent.find(XmlNS.office, "body") else {
                return .failure(.malformed(
                    part: "content.xml", detail: "no office:body"))
            }

            let assets = AssetSink()
            let ctx = OdfCtx(styles: styles, pkg: pkg, assets: assets)

            let blocks: [AnyTypBlock]
            if let text = body.find(XmlNS.office, "text") {
                blocks = try OdfText.parseContainer(text, ctx)
            } else if let sheet = body.find(XmlNS.office, "spreadsheet") {
                blocks = try OdfTable.parseSpreadsheet(sheet, ctx)
            } else if let pres = body.find(XmlNS.office, "presentation") {
                blocks = try parsePresentation(pres, ctx: ctx)
            } else {
                return .failure(.malformed(
                    part: "content.xml",
                    detail: "no recognized office body (text, spreadsheet, or presentation)"))
            }

            return .success(AnyTypDocument(
                blocks: blocks, notes: ctx.notes, assets: assets.assets))
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }
    }

    /// Encrypted ODF packages carry `manifest:encryption-data` elements on
    /// file entries. The manifest is parsed properly — substring matching
    /// would classify a document as encrypted over a mere comment. An
    /// absent or unreadable manifest proves nothing (content parsing
    /// decides), but fatal resource-limit errors propagate.
    private static func isEncrypted(_ pkg: Package) throws -> Bool {
        guard let tree = try pkg.optionalXMLPart("META-INF/manifest.xml") else {
            return false
        }
        return tree.firstDescendant(XmlNS.manifest, "encryption-data") != nil
    }

    private static func parsePresentation(
        _ pres: XmlElement, ctx: OdfCtx
    ) throws -> [AnyTypBlock] {
        var blocks: [AnyTypBlock] = []
        for page in pres.findAll(XmlNS.draw, "page") {
            var title: [AnyTypBlock] = []
            var body: [AnyTypBlock] = []
            var notes: [AnyTypBlock] = []
            try walkShapes(page, ctx: ctx, title: &title, body: &body, notes: &notes)
            blocks.append(contentsOf: title)
            blocks.append(contentsOf: body)
            // Speaker notes are included (fixed policy), set off as a
            // quote.
            if !notes.isEmpty {
                blocks.append(.blockQuote(notes))
            }
        }
        return blocks
    }

    /// Walk a page's shapes in document order, recursing into `draw:g`
    /// groups.
    private static func walkShapes(
        _ parent: XmlElement, ctx: OdfCtx,
        title: inout [AnyTypBlock], body: inout [AnyTypBlock],
        notes: inout [AnyTypBlock]
    ) throws {
        for child in parent.childElems {
            if child.is(XmlNS.presentation, "notes") {
                for frame in child.descendants(XmlNS.draw, "frame") {
                    if let textBox = frame.find(XmlNS.draw, "text-box") {
                        notes.append(contentsOf: try OdfText.parseContainer(textBox, ctx))
                    }
                }
                continue
            }
            if child.ns != XmlNS.draw { continue }
            switch child.local {
            case "frame":
                let `class` = child.attr(XmlNS.presentation, "class") ?? ""
                if ["page-number", "date-time", "footer", "header"].contains(`class`) {
                    continue
                }
                var inner: [AnyTypBlock] = []
                for content in child.childElems {
                    if content.is(XmlNS.draw, "text-box") {
                        inner.append(contentsOf: try OdfText.parseContainer(content, ctx))
                    } else if content.is(XmlNS.table, "table") {
                        inner.append(contentsOf: try OdfTable.parseTable(content, ctx))
                    } else if content.is(XmlNS.draw, "object"),
                              let tex = try OdfText.formulaTex(ctx, object: content) {
                        inner.append(.math(tex))
                        break
                    } else if content.is(XmlNS.draw, "image") {
                        var out: [AnyTypInline] = []
                        var boxes: [AnyTypBlock] = []
                        try OdfText.walkFrame(child, ctx: ctx, out: &out, boxes: &boxes)
                        if !inlinesAreEmpty(out) {
                            inner.append(.paragraph(out))
                        }
                        inner.append(contentsOf: boxes)
                        break
                    }
                }
                if `class` == "title" {
                    pushTitleHeading(inner, into: &title)
                } else {
                    body.append(contentsOf: inner)
                }
            case "g":
                try walkShapes(
                    child, ctx: ctx, title: &title, body: &body, notes: &notes)
            case "custom-shape", "rect", "ellipse", "polygon", "path", "line",
                 "connector", "caption":
                for content in child.childElems {
                    if content.is(XmlNS.text, "p") || content.is(XmlNS.text, "list") {
                        body.append(contentsOf: try OdfText.parseContainer(child, ctx))
                        break
                    }
                }
            default:
                break
            }
        }
    }

    /// Collapse a title frame's paragraphs into one slide heading.
    private static func pushTitleHeading(
        _ inner: [AnyTypBlock], into blocks: inout [AnyTypBlock]
    ) {
        var inlines: [AnyTypInline] = []
        for block in inner {
            guard case .paragraph(let para) = block else { continue }
            if inlinesAreEmpty(para) { continue }
            if !inlines.isEmpty { inlines.append(.lineBreak) }
            inlines.append(contentsOf: para)
        }
        if !inlinesAreEmpty(inlines) {
            blocks.append(.heading(
                level: 2, anchor: inlinesToPlainText(inlines), content: inlines))
        }
    }
}
