import Foundation

/// EPUB frontend (port of `formats/epub/mod.rs`): XHTML chapters in spine
/// order, concatenated into one document with chapter-scoped anchors so
/// intra-book navigation survives.
enum EpubFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let pkg: Package
        do {
            pkg = try Package(bytes: bytes)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }

        let container: XmlElement
        do {
            container = try pkg.requiredXMLPart("META-INF/container.xml")
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        guard let opfPath = container.descendantsAny("rootfile")
            .first?.attrAny("full-path") else {
            return .failure(.malformed(
                part: "META-INF/container.xml", detail: "no rootfile entry"))
        }

        let opf: XmlElement
        do {
            opf = try pkg.requiredXMLPart(opfPath)
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }

        var doc = AnyTypDocument()
        if let title = opf.descendantsAny("title").first?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            doc.blocks.append(.heading(level: 1, anchor: nil, content: [.text(title, style: .plain)]))
        }

        var manifest: [String: (href: String, media: String)] = [:]
        for item in opf.descendantsAny("item") {
            if let id = item.attrAny("id"), let href = item.attrAny("href") {
                manifest[id] = (href, item.attrAny("media-type") ?? "")
            }
        }

        // Every spine part in spine order: non-linear items are auxiliary
        // but still publication content, and unusable parts degrade at
        // parse time. Intra-book links target these; links to any other
        // resource stay Relative.
        // A part holds one position in a reading order, and each repeat
        // would cost another parse of it and another copy of its anchor.
        var spineEntries = 0
        var spinePaths: [String] = []
        var spineParts = Set<String>()
        for href in opf.descendantsAny("itemref").compactMap({ $0.attrAny("idref") })
            .compactMap({ manifest[$0]?.href }) {
            spineEntries += 1
            let target: PackageTarget
            do {
                target = try resolvePackageTarget(opfPath, href)
            } catch {
                AnyTypLog.warn("skipping chapter with unresolvable href \(href): \(error)")
                continue
            }
            if spineParts.insert(target.path).inserted {
                spinePaths.append(target.path)
            }
        }

        let assets = AssetSink()
        var cssCache: [String: String?] = [:]
        var converted = 0
        for chapterPath in spinePaths {
            let tree: XmlElement?
            do {
                tree = try pkg.optionalXMLPart(chapterPath)
            } catch {
                return .failure(error as? ConvertError ?? .io("\(error)"))
            }
            guard let tree else {
                AnyTypLog.warn("skipping unusable chapter \(chapterPath)")
                continue
            }
            guard let body = tree.childElems
                .first(where: { $0.local == "html" })?
                .childElems.first(where: { $0.local == "body" }) else {
                AnyTypLog.warn("skipping chapter \(chapterPath): no body element")
                continue
            }
            let css: Stylesheet
            do {
                css = try chapterStylesheet(
                    tree, chapterPath: chapterPath, pkg: pkg, cache: &cssCache)
            } catch {
                return .failure(error as? ConvertError ?? .io("\(error)"))
            }
            let ctx = ChapterCtx(
                pkg: pkg, assets: assets, chapterPath: chapterPath,
                spineParts: spineParts)
            // Chapter-start anchor: renders only when a link targets this
            // chapter.
            doc.blocks.append(.paragraph([.anchor(chapterPath)]))
            do {
                doc.blocks.append(contentsOf: try htmlToBlocks(body, css: css, ctx: ctx))
            } catch {
                return .failure(error as? ConvertError ?? .io("\(error)"))
            }
            converted += 1
        }
        if spineEntries > 0 && converted == 0 {
            return .failure(.malformed(part: nil, detail: "no chapter in the book could be read"))
        }

        doc.assets = assets.assets
        return .success(doc)
    }

    /// A chapter's CSS cascade: its linked stylesheets and inline `<style>`
    /// blocks, in document order. Stylesheet parts are cached across
    /// chapters.
    private static func chapterStylesheet(
        _ tree: XmlElement, chapterPath: String, pkg: Package,
        cache: inout [String: String?]
    ) throws -> Stylesheet {
        let css = Stylesheet()
        var stack = tree.childElems
        stack.reverse()
        while let elem = stack.popLast() {
            switch elem.local {
            case "link":
                let rel = elem.attrAny("rel") ?? ""
                let isSheet = rel.split(whereSeparator: { $0.isWhitespace })
                    .contains { $0.caseInsensitiveCompare("stylesheet") == .orderedSame }
                if isSheet, let href = elem.attrAny("href") {
                    guard let target = try? resolvePackageTarget(chapterPath, href) else {
                        continue
                    }
                    if cache[target.path] == nil {
                        let text = try pkg.optionalPart(target.path).map {
                            String(data: $0, encoding: .utf8)
                                ?? String(decoding: $0, as: UTF8.self)
                        }
                        cache[target.path] = .some(text)
                    }
                    if let text = cache[target.path] ?? nil {
                        css.add(text)
                    }
                }
            case "style":
                css.add(elem.text)
            default:
                let start = stack.count
                stack.append(contentsOf: elem.childElems)
                stack.replaceSubrange(
                    start..., with: stack[start...].reversed())
            }
        }
        return css
    }

    private struct ChapterCtx: HtmlCtx {
        var pkg: Package
        var assets: AssetSink
        var chapterPath: String
        var spineParts: Set<String>

        func linkTarget(_ href: String) -> AnyTypLinkTarget? {
            if href.isEmpty { return nil }
            if href.hasPrefix("#") {
                return .anchor(scoped(
                    chapterPath, fragment: decodeFragment(String(href.dropFirst()))))
            }
            if isAbsoluteURI(href) { return .external(href) }
            // Anchors only for converted spine documents; links to any other
            // package resource (images, downloads, non-linear content) keep
            // their relative form.
            if let target = try? resolvePackageTarget(chapterPath, href),
               spineParts.contains(target.path) {
                return .anchor(scoped(
                    target.path, fragment: target.fragment.map(decodeFragment)))
            }
            return .relative(href)
        }

        func imageSource(_ src: String) throws -> AnyTypImageSource? {
            if src.isEmpty { return nil }
            if isAbsoluteURI(src) { return .external(src) }
            guard let target = try? resolvePackageTarget(chapterPath, src) else {
                return nil
            }
            guard let data = try pkg.optionalPart(target.path) else { return nil }
            let id = try assets.add(
                mediaType: mediaTypeFor(target.path),
                originPart: target.path, bytes: [UInt8](data))
            return .asset(id)
        }

        func anchorId(_ raw: String) -> String {
            scoped(chapterPath, fragment: raw)
        }
    }

    /// Chapter-scoped anchor id: the chapter path itself targets the
    /// chapter start; `path#fragment` targets an element inside it.
    private static func scoped(_ chapterPath: String, fragment: String?) -> String {
        if let f = fragment, !f.isEmpty {
            return "\(chapterPath)#\(f)"
        }
        return chapterPath
    }
}
