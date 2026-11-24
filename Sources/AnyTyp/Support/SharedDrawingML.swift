import Foundation

/// Textual extraction of DrawingML rich objects shared by DOCX and PPTX:
/// charts (title, axis titles, cached series data) and SmartArt diagram
/// data (text points) (port of `shared/drawingml.rs`).
enum DrawingML {
    /// A chart part as blocks: bold title paragraph plus a categories x
    /// series table built from the cached display strings.
    static func chartBlocks(_ root: XmlElement) -> [AnyTypBlock] {
        var blocks: [AnyTypBlock] = []
        if let titleEl = root.firstDescendant(XmlNS.chart, "title") {
            let title = SharedText.clean(drawingText(titleEl))
            if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.paragraph([.text(title, style: AnyTypStyle(bold: true))]))
            }
        }
        struct Series {
            var name: String
            var values: [String]
        }
        var categories: [String] = []
        var series: [Series] = []
        for ser in root.descendants(XmlNS.chart, "ser") {
            // Cached display strings only; `c:f` formula references are not text.
            let name = ser.find(XmlNS.chart, "tx")?
                .firstDescendant(XmlNS.chart, "v")
                .map { SharedText.clean($0.text) } ?? ""
            let cats = ser.find(XmlNS.chart, "cat")?
                .descendants(XmlNS.chart, "v").map { SharedText.clean($0.text) } ?? []
            if categories.isEmpty { categories = cats }
            let values = ser.find(XmlNS.chart, "val")?
                .descendants(XmlNS.chart, "v").map { SharedText.clean($0.text) } ?? []
            series.append(Series(name: name, values: values))
        }
        if !series.isEmpty, !categories.isEmpty {
            let catTitle = root.firstDescendant(XmlNS.chart, "catAx")?
                .find(XmlNS.chart, "title")
                .map { SharedText.clean(drawingText($0)) } ?? ""
            var header: [AnyTypCell] = [.fromInlines([.text(catTitle, style: .plain)])]
            header.append(contentsOf: series.map {
                .fromInlines([.text($0.name, style: .plain)])
            })
            var rows = [header]
            for (i, cat) in categories.enumerated() {
                var row: [AnyTypCell] = [.fromInlines([.text(cat, style: .plain)])]
                for s in series {
                    row.append(.fromInlines([.text(s.values.indices.contains(i) ? s.values[i] : "",
                                                           style: .plain)]))
                }
                rows.append(row)
            }
            blocks.append(.table(AnyTypTable.fromRows(rows, headerRows: 1, kind: .data)))
        }
        return blocks
    }

    /// A SmartArt data part as a bullet list of its text points in order.
    static func diagramBlocks(_ root: XmlElement) -> [AnyTypBlock] {
        let items: [AnyTypListItem] = root.descendants(XmlNS.dgm, "pt").compactMap { pt in
            guard let t = pt.find(XmlNS.dgm, "t") else { return nil }
            let text = SharedText.clean(t.text)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            return .init(blocks: [.paragraph([.text(text, style: .plain)])])
        }
        if items.isEmpty { return [] }
        return [.list(AnyTypList(marker: .bullet, start: 1, items: items))]
    }

    /// Text runs inside DrawingML rich text (`a:p`/`a:r`/`a:t`), joined.
    static func drawingText(_ elem: XmlElement) -> String {
        let parts = elem.descendants(XmlNS.a, "p")
            .map { SharedText.clean($0.text) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.isEmpty ? SharedText.clean(elem.text) : parts.joined(separator: " ")
    }
}
