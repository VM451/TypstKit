import Foundation

/// OOXML WordprocessingML (.docx / .docm) frontend
/// (port of `formats/docx/mod.rs`).
enum DocxFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let pkg: Package
        do {
            pkg = try Package(bytes: bytes)
        } catch let e as ConvertError {
            // A zip-open failure on OOXML input may actually be an OLE
            // compound file: an encrypted package, or a legacy binary
            // document with the wrong extension.
            if let ole = probeOle(bytes: bytes) { return .failure(ole) }
            return .failure(e)
        } catch {
            if let ole = probeOle(bytes: bytes) { return .failure(ole) }
            return .failure(.malformed(part: nil, detail: "\(error)"))
        }

        do {
            return .success(try parsePackage(pkg))
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.malformed(part: nil, detail: "\(error)"))
        }
    }

    private static func parsePackage(_ pkg: Package) throws -> AnyTypDocument {
        // OPC part discovery: the main part comes from the package-level
        // officeDocument relationship; its own parts (styles, numbering,
        // notes) from the main part's typed relationships. Conventional
        // paths are the fallback for packages with missing or unusable rels.
        let rootRels = try readRels(pkg, "_rels/.rels")
        let mainPart = rootRels.firstOfType(RelType.officeDocument)
            .flatMap { try? resolvePackageTarget("", $0.target).path }
            ?? "word/document.xml"
        let docRels = try readRels(pkg, relsPartFor(mainPart))

        let stylesPart = typedPartPath(docRels, mainPart, RelType.styles, "styles.xml")
        let stylesTree = try pkg.optionalXMLPart(stylesPart)
        let styles = DocxStyles.parseOpt(stylesTree?.find(XmlNS.w, "styles"))

        let numberingPart = typedPartPath(docRels, mainPart, RelType.numbering, "numbering.xml")
        let numberingTree = try pkg.optionalXMLPart(numberingPart)
        let numbering: DocxNumbering
        if let root = numberingTree?.find(XmlNS.w, "numbering") {
            numbering = try DocxNumbering.parse(root) { styleId in
                styles.directNumId(styleId)
            }
        } else {
            numbering = try DocxNumbering.parse(
                XmlElement(ns: nil, local: "", attrs: []), styleNumId: { _ in nil })
        }

        let docTree = try pkg.requiredXMLPart(mainPart)
        guard let document = docTree.find(XmlNS.w, "document"),
              let body = document.find(XmlNS.w, "body") else {
            throw ConvertError.malformed(part: mainPart, detail: "no document body")
        }

        let counters = DocxCounters()
        let assets = AssetSink()

        let footnotesPart = typedPartPath(docRels, mainPart, RelType.footnotes, "footnotes.xml")
        let endnotesPart = typedPartPath(docRels, mainPart, RelType.endnotes, "endnotes.xml")

        let ctx = DocxCtx(pkg: pkg, rels: docRels, basePart: mainPart, styles: styles,
                          numbering: numbering, counters: counters, assets: assets)
        let blocks = try docxParseBlocks(body, ctx)

        var notes: [AnyTypNote] = []
        for (part, rootName, elemName, prefix, kind) in [
            (footnotesPart, "footnotes", "footnote", "fn", AnyTypNoteKind.footnote),
            (endnotesPart, "endnotes", "endnote", "en", .endnote),
        ] as [(String, String, String, String, AnyTypNoteKind)] {
            guard let tree = try pkg.optionalXMLPart(part),
                  let root = tree.find(XmlNS.w, rootName) else { continue }
            let noteRels = try readRels(pkg, relsPartFor(part))
            let noteCtx = ctx.forPart(noteRels, part)
            for note in root.findAll(XmlNS.w, elemName) {
                if ["separator", "continuationSeparator", "continuationNotice"]
                    .contains(note.attr(XmlNS.w, "type") ?? "") { continue }
                guard let id = note.attr(XmlNS.w, "id") else { continue }
                notes.append(.init(id: "\(prefix)\(id)", kind: kind,
                                   blocks: try docxParseBlocks(note, noteCtx)))
            }
        }

        return AnyTypDocument(blocks: blocks, notes: notes, assets: assets.assets)
    }

    /// Path of a typed related part, resolved against the main part; falls
    /// back to the conventional sibling name when the relationship is absent.
    private static func typedPartPath(
        _ rels: Relationships, _ base: String, _ relType: String, _ fallback: String
    ) -> String {
        let reference = rels.firstOfType(relType)?.target ?? fallback
        if let target = try? resolvePackageTarget(base, reference) {
            return target.path
        }
        AnyTypLog.warn("skipping unresolvable related-part target \(reference)")
        return (try? resolvePackageTarget(base, fallback).path) ?? fallback
    }
}
