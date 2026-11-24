import Foundation

/// Nested-list assembly with numbering identity (port of `shared/list.rs`).
struct ListKey: Hashable {
    /// Stable per-instance id (DOCX `numId`, RTF `\lsN`, ...).
    var instance: UInt64
    var marker: AnyTypMarkerKind
}

/// One flat, fully resolved list paragraph (plus any blocks attached to
/// the same item).
struct ListEntry {
    var level: Int
    var key: ListKey
    /// Effective item number at this entry (ignored for bullets).
    var number: UInt64
    /// Literal marker text when the source number text is not reproducible
    /// from marker kind + number alone.
    var label: String?
    var blocks: [AnyTypBlock]
}

/// Pop the accumulated run of list paragraphs into list blocks; one block
/// per identity segment.
func flushList(_ blocks: inout [AnyTypBlock], _ run: inout [ListEntry]) {
    let entries = run
    run = []
    if entries.isEmpty { return }
    blocks.append(contentsOf: buildLists(entries))
}

/// Fold a flat run into nested lists, splitting at identity/marker changes
/// and ordered-sequence discontinuities.
private func buildLists(_ entries: [ListEntry]) -> [AnyTypBlock] {
    guard let minLvl = entries.map(\.level).min() else { return [] }
    var out: [AnyTypBlock] = []
    var current: (list: AnyTypList, key: ListKey, lastNumber: UInt64)? = nil

    func flushCurrent() {
        if let c = current, !c.list.items.isEmpty {
            out.append(.list(c.list))
        }
        current = nil
    }

    var i = 0
    while i < entries.count {
        let entry = entries[i]
        if entry.level <= minLvl {
            i += 1
            var split = true
            if let c = current {
                if c.key == entry.key {
                    split = entry.key.marker.ordered
                        && (c.lastNumber == UInt64.max || c.lastNumber + 1 != entry.number)
                }
            }
            if split {
                flushCurrent()
                current = (AnyTypList(marker: entry.key.marker,
                                      start: entry.key.marker.ordered ? entry.number : 1,
                                      items: []),
                           entry.key, entry.number)
            }
            current!.list.items.append(.init(blocks: entry.blocks, markerLabel: entry.label))
            current!.lastNumber = entry.number
        } else {
            // Collect the deeper run.
            var sub: [ListEntry] = []
            while i < entries.count, entries[i].level > minLvl {
                sub.append(entries[i])
                i += 1
            }
            let sublists = buildLists(sub)
            if sublists.isEmpty { continue }
            if current == nil {
                // Sub-level content with no parent item yet: host it in an
                // anonymous item so nesting is preserved.
                current = (AnyTypList(marker: .bullet, start: 1, items: []),
                           ListKey(instance: UInt64.max, marker: .bullet), 0)
            }
            if current!.list.items.isEmpty {
                current!.list.items.append(.init(blocks: []))
            }
            current!.list.items[current!.list.items.count - 1].blocks.append(contentsOf: sublists)
        }
    }
    flushCurrent()
    return out
}
