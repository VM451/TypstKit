import Foundation

/// Structured JSON frontend (port of `formats/json.rs`): homogeneous object
/// arrays and 2D arrays become tables; nested objects/arrays become sections
/// and bullet lists.
enum JsonFormat {
    private indirect enum JValue {
        case null, bool(Bool), number(Double), string(String)
        case array([JValue]), object([(String, JValue)])
    }

    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.malformed("invalid JSON"))
        }
        let value = toJValue(raw)
        var doc = AnyTypDocument()
        valueToBlocks(value, depth: 1, out: &doc.blocks)
        return .success(doc)
    }

    private static func toJValue(_ raw: Any) -> JValue {
        switch raw {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(toJValue))
        case let o as [String: Any]:
            // serde_json's default Map is a BTreeMap: keys sort.
            return .object(o.sorted { $0.key < $1.key }.map { ($0.key, toJValue($0.value)) })
        default: return .null
        }
    }

    private static func valueToBlocks(_ val: JValue, depth: UInt8, out: inout [AnyTypBlock]) {
        switch val {
        case .null:
            break
        case .bool, .number, .string:
            let s = scalarString(val)
            if !s.isEmpty { out.append(.paragraph([.text(s, style: .plain)])) }
        case .array(let items):
            if items.isEmpty { break }
            if let table = objectArrayToTable(items) ?? rowArrayToTable(items) {
                out.append(.table(table))
                break
            }
            var listItems: [AnyTypListItem] = []
            for item in items {
                var blocks: [AnyTypBlock] = []
                valueToBlocks(item, depth: depth &+ 1, out: &blocks)
                if !blocks.isEmpty { listItems.append(.init(blocks: blocks)) }
            }
            if !listItems.isEmpty {
                out.append(.list(.init(marker: .bullet, start: 1, items: listItems)))
            }
        case .object(let map):
            if map.allSatisfy({ isScalar($0.1) }) {
                let items = map.map { (k, v) -> AnyTypListItem in
                    .init(blocks: [.paragraph([
                        .text(k, style: AnyTypStyle(bold: true)),
                        .text(": \(scalarString(v))", style: .plain),
                    ])])
                }
                if !items.isEmpty {
                    out.append(.list(.init(marker: .bullet, start: 1, items: items)))
                }
                break
            }
            for (k, v) in map {
                if isScalar(v) {
                    out.append(.paragraph([
                        .text(k, style: AnyTypStyle(bold: true)),
                        .text(": \(scalarString(v))", style: .plain),
                    ]))
                } else {
                    out.append(.heading(level: max(1, min(6, Int(depth))), anchor: nil, content: [.text(k, style: .plain)]))
                    valueToBlocks(v, depth: depth &+ 1, out: &out)
                }
            }
        }
    }

    private static func isScalar(_ v: JValue) -> Bool {
        switch v {
        case .null, .bool, .number, .string: return true
        default: return false
        }
    }

    private static func scalarString(_ v: JValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    private static func objectArrayToTable(_ items: [JValue]) -> AnyTypTable? {
        guard items.allSatisfy({ if case .object = $0 { return true }; return false }) else { return nil }
        var keys: [String] = []
        for item in items {
            guard case .object(let map) = item else { continue }
            for (k, _) in map where !keys.contains(k) { keys.append(k) }
        }
        if keys.isEmpty { return nil }
        var rows: [[AnyTypCell]] = [keys.map { .fromInlines([.text($0, style: .plain)]) }]
        for item in items {
            guard case .object(let map) = item else { continue }
            let dict = Dictionary(uniqueKeysWithValues: map)
            rows.append(keys.map { k in
                .fromInlines([.text(dict[k].map(scalarString) ?? "", style: .plain)])
            })
        }
        return .fromRows(rows, headerRows: 1, kind: .data)
    }

    private static func rowArrayToTable(_ items: [JValue]) -> AnyTypTable? {
        func isRow(_ v: JValue) -> Bool {
            guard case .array(let a) = v, !a.isEmpty else { return false }
            return a.allSatisfy(isScalar)
        }
        guard items.allSatisfy(isRow) else { return nil }
        let rows: [[AnyTypCell]] = items.compactMap { v -> [AnyTypCell]? in
            guard case .array(let a) = v else { return nil }
            return a.map { .fromInlines([.text(scalarString($0), style: .plain)]) }
        }
        var table = AnyTypTable.fromRows(rows, headerRows: 0, kind: .data)
        table.headerRows = HeaderDetect.resolve(table, declared: 0)
        return table
    }
}
