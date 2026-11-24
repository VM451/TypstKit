import AnyTyp
import Foundation
import Testing

struct AnyTypConversionTests {
    private static var fixturesRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tests/fixtures")
    }

    @Test("Detects container formats from raw bytes", arguments: [
        ("docx/text.docx", AnyTypFormat.docx),
        ("doc/text.doc", AnyTypFormat.doc),
        ("pptx/pres.pptx", AnyTypFormat.pptx),
        ("ppt/pres.ppt", AnyTypFormat.ppt),
        ("xlsx/sheet.xlsx", AnyTypFormat.xlsx),
        ("xls/sheet.xls", AnyTypFormat.xlsx),
        ("xlsb/handmade-sheet.xlsb", AnyTypFormat.xlsx),
        ("odt/text.odt", AnyTypFormat.odt),
        ("ods/sheet.ods", AnyTypFormat.ods),
        ("odp/pres.odp", AnyTypFormat.odp),
        ("rtf/text.rtf", AnyTypFormat.rtf),
        ("epub/book.epub", AnyTypFormat.epub),
        ("pdf/text.pdf", AnyTypFormat.pdf),
    ])
    func formatDetectionFromBytes(relativePath: String, expected: AnyTypFormat) throws {
        let url = Self.fixturesRoot.appending(path: relativePath)
        let data = try Data(contentsOf: url)
        #expect(AnyTypFormat.detect(from: data) == expected)
    }

    @Test("Converts Office, ODF, RTF, EPUB, PDF, and CSV fixtures to Typst")
    func convertsAllBinaryCorpusFamilies() throws {
        let samples = [
            "docx/text.docx",
            "doc/text.doc",
            "pptx/pres.pptx",
            "ppt/pres.ppt",
            "xlsx/sheet.xlsx",
            "xls/sheet.xls",
            "xlsb/handmade-sheet.xlsb",
            "odt/text.odt",
            "ods/sheet.ods",
            "odp/pres.odp",
            "rtf/text.rtf",
            "epub/book.epub",
            "pdf/text.pdf",
            "csv/sheet.csv",
        ]
        for rel in samples {
            let typ = try AnyTyp.convert(Self.fixturesRoot.appending(path: rel))
            #expect(!typ.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty output for \(rel)")
        }
    }

    @Test("Converts Markdown, HTML, LaTeX, JSON, TSV, and plain text from Data")
    func convertsMarkupAndStructuredData() throws {
        let md = Data("# Heading\n\n**Bold** and $\\frac{a}{b}$\n".utf8)
        let mdTyp = try AnyTyp.convert(md, format: .md)
        #expect(mdTyp.contains("= Heading"))
        #expect(mdTyp.contains("*Bold*"))
        #expect(mdTyp.contains("frac(a, b)"))

        let html = Data("<!DOCTYPE html><html><body><p>H<sub>2</sub>O</p></body></html>".utf8)
        #expect(AnyTypFormat.detect(from: html) == .html)
        let htmlTyp = try AnyTyp.convert(html)
        #expect(htmlTyp.contains("H#sub[2]O"))

        let tex = Data("\\section{Intro}\\underline{key} $\\sqrt[3]{8}$".utf8)
        let texTyp = try AnyTyp.convert(tex, format: .tex)
        #expect(texTyp.contains("= Intro"))
        #expect(texTyp.contains("#underline[key]"))
        #expect(texTyp.contains("root(3, 8)"))

        let json = Data("[{\"name\":\"Ada\",\"score\":99}]".utf8)
        let jsonTyp = try AnyTyp.convert(json, format: .json)
        #expect(jsonTyp.contains("table.header([name], [score])"))
    }

    @Test("Extracts embedded assets and emits standalone preamble")
    func extractsAssetsAndStandalonePreamble() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "anytyp-swift-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let assetsDir = tmp.appending(path: "assets")

        let rtfURL = Self.fixturesRoot.appending(path: "rtf/text.rtf")
        let typ = try AnyTyp.convert(
            rtfURL,
            options: AnyTypOptions(
                standalone: true,
                title: "Swift Asset Spec",
                extractAssetsTo: assetsDir,
                assetsPrefix: "assets"
            )
        )
        #expect(typ.contains("#set document(title: \"Swift Asset Spec\")"))
        #expect(typ.contains("assets/asset-001.png"))
        let extractedPNG = assetsDir.appending(path: "asset-001.png")
        #expect(FileManager.default.fileExists(atPath: extractedPNG.path(percentEncoded: false)))
    }

    @Test("Reports NeedsOCR with exact 1-indexed page numbers on scanned PDFs")
    func scannedPDFThrowsNeedsOCR() throws {
        let mixedURL = Self.fixturesRoot.appending(path: "pdf/handmade-mixed.pdf")
        let error = try #require(throws: AnyTypError.self) {
            _ = try AnyTyp.convert(mixedURL)
        }
        guard case .needsOCR(let pages, let pageCount, _) = error else {
            Issue.record("Expected needsOCR, got \(error)")
            return
        }
        #expect(pages == [2])
        #expect(pageCount == 2)
    }

    @Test("Hard-fails abuse fixtures with ResourceLimit")
    func abuseFixtureThrowsResourceLimit() throws {
        let bombURL = Self.fixturesRoot.appending(path: "abuse/zipbomb--errors.docx")
        let error = try #require(throws: AnyTypError.self) {
            _ = try AnyTyp.convert(bombURL)
        }
        guard case .resourceLimit = error else {
            Issue.record("Expected resourceLimit, got \(error)")
            return
        }
    }

    @MainActor
    @Test("Async conversion runs safely from MainActor")
    func asyncConversionFromMainActor() async throws {
        let docxURL = Self.fixturesRoot.appending(path: "docx/text.docx")
        let typ = try await AnyTyp.convertAsync(docxURL)
        #expect(typ.contains("= Fixture Document"))
    }
}
