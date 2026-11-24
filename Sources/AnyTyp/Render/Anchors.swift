import Foundation

/// Anchor resolution for Typst labels (`<label>`) and `#link(<label>)[...]` references.
///
/// Only anchors actually targeted by an internal link in the document emit a
/// label: headings carry `<label>` at the end of the heading line, and inline
/// bookmarks emit `#metadata(none) <label>` (since plain text is not labelable
/// in Typst, whereas `metadata` is zero-width and `Locatable`).
final class AnchorMap {
    /// Source anchor id -> unique Typst label id.
    private var targetLabels: [String: String] = [:]
    /// Heading source anchor id -> Typst label id to emit on that heading.
    private var headingLabels: [Int: String] = [:]
    /// Inline source anchor id -> Typst label id to emit via `#metadata(none) <id>`.
    private var inlineLabels: [String: String] = [:]

    /// Label id for a `.anchor(id)` link target, if the target exists.
    func labelForTarget(_ id: String) -> String? {
        targetLabels[id]
    }

    /// Label id to attach to the heading at `headingIndex` (in DFS order).
    func headingLabel(_ headingIndex: Int) -> String? {
        headingLabels[headingIndex]
    }

    /// Label id to emit inline for `AnyTypInline.anchor(id)`, if targeted and
    /// not already bound to a heading.
    func inlineLabel(_ id: String) -> String? {
        inlineLabels[id]
    }

    fileprivate func setTargetLabel(_ id: String, _ label: String) {
        if targetLabels[id] == nil { targetLabels[id] = label }
    }

    fileprivate func setHeadingLabel(_ index: Int, _ label: String) {
        headingLabels[index] = label
    }

    fileprivate func setInlineLabel(_ id: String, _ label: String) {
        targetLabels[id] = label
        inlineLabels[id] = label
    }
}

func resolveAnchors(blocks: [AnyTypBlock], notes: [AnyTypNote]) -> AnchorMap {
    let map = AnchorMap()
    var ids = UniqueIds()

    var linked = Set<String>()
    walkBlocks(blocks) { collectLinkTargets($0, into: &linked) }
    for note in notes {
        walkBlocks(note.blocks) { collectLinkTargets($0, into: &linked) }
    }

    // Pass 1: headings that carry a targeted anchor id (either on
    // `heading.anchor` or as an `AnyTypInline.anchor` inside the heading
    // content) claim one clean label. Headings are numbered in DFS order.
    var headingIdx = 0
    walkBlocks(blocks) { block in
        guard case .heading(_, let anchor, let content) = block else { return }
        let thisIdx = headingIdx
        headingIdx += 1

        var candidateIds: [String] = []
        if let anchor { candidateIds.append(anchor) }
        forEachAnchor(content) { candidateIds.append($0) }

        let plainSlug = sanitizeLabel(inlinesToPlainText(content))
        let isTargeted = candidateIds.contains { linked.contains($0) } || linked.contains(plainSlug)
        guard isTargeted else { return }

        let preferred = candidateIds.first.map { sanitizeLabel($0) } ?? plainSlug
        guard let label = ids.claim(preferred) else { return }
        map.setHeadingLabel(thisIdx, label)
        for id in candidateIds {
            map.setTargetLabel(id, label)
        }
        if linked.contains(plainSlug) {
            map.setTargetLabel(plainSlug, label)
        }
    }

    // Pass 2: remaining targeted `AnyTypInline.anchor` positions get
    // `#metadata(none) <label>`.
    for block in blocks {
        assignAnchors(in: block, linked: linked, ids: &ids, map: map)
    }
    for note in notes {
        for block in note.blocks {
            assignAnchors(in: block, linked: linked, ids: &ids, map: map)
        }
    }

    return map
}

/// Depth-first walk over a block slice and everything it nests (list items,
/// table cells, block quotes), in document order.
private func walkBlocks(_ blocks: [AnyTypBlock], _ f: (AnyTypBlock) -> Void) {
    var stack = Array(blocks.reversed())
    while let block = stack.popLast() {
        f(block)
        switch block {
        case .list(let list):
            for item in list.items.reversed() {
                stack.append(contentsOf: item.blocks.reversed())
            }
        case .table(let table):
            for row in table.grid.reversed() {
                for slot in row.reversed() {
                    if case .origin(let cell) = slot {
                        stack.append(contentsOf: cell.blocks.reversed())
                    }
                }
            }
        case .blockQuote(let inner):
            stack.append(contentsOf: inner.reversed())
        default:
            break
        }
    }
}

/// Pass 2 over one block subtree: every `paragraph`'s anchors that are still
/// unbound and targeted get an inline metadata label.
private func assignAnchors(
    in block: AnyTypBlock,
    linked: Set<String>,
    ids: inout UniqueIds,
    map: AnchorMap
) {
    walkBlocks([block]) { b in
        guard case .paragraph(let inlines) = b else { return }
        forEachAnchor(inlines) { id in
            if linked.contains(id), map.labelForTarget(id) == nil,
               let label = ids.claim(sanitizeLabel(id)) {
                map.setInlineLabel(id, label)
            }
        }
    }
}

private func collectLinkTargets(_ block: AnyTypBlock, into out: inout Set<String>) {
    switch block {
    case .heading(_, _, let content), .paragraph(let content):
        forEachLinkTarget(content, into: &out)
    default:
        break
    }
}

private func forEachLinkTarget(_ inlines: [AnyTypInline], into out: inout Set<String>) {
    for inline in inlines {
        if case .link(let content, let target) = inline {
            if case .anchor(let id) = target {
                out.insert(id)
            }
            forEachLinkTarget(content, into: &out)
        }
    }
}

private func forEachAnchor(_ inlines: [AnyTypInline], _ f: (String) -> Void) {
    for inline in inlines {
        switch inline {
        case .anchor(let id):
            f(id)
        case .link(let content, _):
            forEachAnchor(content, f)
        default:
            break
        }
    }
}

private struct UniqueIds {
    var used = Set<String>()
    var nextSuffix: [String: Int] = [:]

    mutating func claim(_ base: String) -> String? {
        if used.insert(base).inserted {
            if nextSuffix[base] == nil { nextSuffix[base] = 1 }
            return base
        }
        var n = nextSuffix[base] ?? 1
        while true {
            let candidate = "\(base)-\(n)"
            n += 1
            if used.insert(candidate).inserted {
                nextSuffix[base] = n
                if nextSuffix[candidate] == nil { nextSuffix[candidate] = 1 }
                return candidate
            }
        }
    }
}

/// Sanitize an arbitrary string into a valid Typst `<label>` identifier.
func sanitizeLabel(_ raw: String) -> String {
    let trimmedInput = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var out = ""
    out.reserveCapacity(trimmedInput.count)
    var prevDash = false
    for scalar in trimmedInput.unicodeScalars {
        // ASCII-only mapping, matching Rust `to_ascii_lowercase` + the
        // `[a-z0-9_-]` acceptance set: everything else becomes `-`.
        let mapped: Unicode.Scalar
        switch scalar.value {
        case 0x61...0x7A, 0x30...0x39, 0x5F, 0x2D: // a-z 0-9 _ -
            mapped = scalar
        case 0x41...0x5A: // A-Z
            mapped = Unicode.Scalar(scalar.value + 0x20)!
        default:
            mapped = "-"
        }
        if mapped == "-" && prevDash { continue }
        prevDash = mapped == "-"
        out.unicodeScalars.append(mapped)
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    let candidate = out.isEmpty ? "section" : out
    return isValidLabelLiteralId(candidate) ? candidate : "sec-\(candidate)"
}

/// `typst_syntax::is_valid_label_literal_id`: non-empty and every char is an
/// identifier-continue char, `:`, or `.`.
private func isValidLabelLiteralId(_ id: String) -> Bool {
    !id.isEmpty && id.allSatisfy { c in
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == ":" || c == "."
    }
}
