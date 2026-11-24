import AnyTyp
import Foundation
import Testing

struct AnyTypDocumentModelTests {
    private static var fixturesRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tests/fixtures")
    }

    @Test("Parses DOCX and PDF into structured AnyTypDocument AST")
    func parsesDocumentBlocksAndStyles() throws {
        let docxURL = Self.fixturesRoot.appending(path: "docx/text.docx")
        let doc = try AnyTyp.parseDocument(docxURL)
        #expect(!doc.blocks.isEmpty)

        let first = try #require(doc.blocks.first)
        guard case .heading(let level, _, let inlines) = first else {
            Issue.record("Expected leading heading, got \(first)")
            return
        }
        #expect(level == 1)
        #expect(inlines == [.text("Fixture Document", style: .plain)])

        let pdfURL = Self.fixturesRoot.appending(path: "pdf/text.pdf")
        let pdfDoc = try AnyTyp.parseDocument(pdfURL)
        #expect(!pdfDoc.blocks.isEmpty)
    }

    @Test("Retains embedded binary assets in AnyTypDocument.assets")
    func retainsEmbeddedAssetsInModel() async throws {
        let rtfData = try Data(contentsOf: Self.fixturesRoot.appending(path: "rtf/text.rtf"))
        let doc = try await AnyTyp.parseDocumentAsync(rtfData, format: .rtf)
        let png = try #require(doc.assets.first { $0.mediaType == "image/png" })
        #expect(png.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        // Verify Codable round-trip on AnyTypDocument
        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(AnyTypDocument.self, from: encoded)
        #expect(decoded == doc)
    }

    @Test("Preserves merged table spans in AnyTypTable grid")
    func preservesSpannedTableGrid() throws {
        let html = Data("""
        <!DOCTYPE html>
        <html><body>
          <table>
            <thead><tr><th colspan="2">Summary</th></tr></thead>
            <tbody><tr><td>A</td><td>B</td></tr></tbody>
          </table>
        </body></html>
        """.utf8)
        let doc = try AnyTyp.parseDocument(html, format: .html)
        let tableBlock = try #require(doc.blocks.first)
        guard case .table(let table) = tableBlock else {
            Issue.record("Expected table block, got \(tableBlock)")
            return
        }
        #expect(table.headerRows == 1)
        #expect(table.grid.count == 2)
        guard case .origin(let headerCell) = table.grid[0][0] else {
            Issue.record("Expected origin cell at (0,0)")
            return
        }
        #expect(headerCell.colSpan == 2)
        #expect(table.grid[0][1] == .covered(originRow: 0, originCol: 0))
    }
}
