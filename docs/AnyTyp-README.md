# AnyTyp (`anytyp`)

Fast Rust library, native CLI, **Swift Package (`AnyTyp` for macOS 27+ & iOS 27+)**, multi-language bindings (Node.js, Python, WebAssembly), and Agent Skill that converts **any document** (Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, PDF, Markdown, HTML, LaTeX, CSV, TSV, JSON, and plain text) into clean, idiomatic, syntax-verified **Typst 0.15 (`.typ`)**.

Every format parses into one information-preserving intermediate `Document` AST and renders through a single Typst 0.15 serializer backed by `mitex` (LaTeX/OMML/MathML equation translation) and `typst-syntax` verification — delivering median CLI conversion in **~5 ms per document** (and sub-2 ms in-process) with zero syntax errors across every output.

## Why Typst Instead of Markdown?

Markdown drops rich document structure or falls back to raw HTML hacks. Typst is open-source, programmable, compiles to PDF/SVG/PNG/HTML in milliseconds, and represents real office/academic document semantics natively:

| Document Feature | Markdown (`anydoc`) | Typst (`anytyp`) |
| --- | --- | --- |
| Merged table cells (`colspan` / `rowspan`) | Lost (blank padding cells) | Native `table.cell(colspan: 2, rowspan: 3)[...]` |
| Multi-paragraph / list cells in tables | Flattened with `<br>` | Native multi-block `[...]` table cells |
| Multi-row semantic table headers | Single GFM pipe header row | Native `table.header(...)` |
| Layout scaffolding tables | Pipe table noise | Unwrapped (1×1) or borderless `#grid(...)` |
| Roman / alphabetic / offset ordered lists | Degraded to `- iv. ...` bullets | Native `#enum(numbering: "i.", start: 4, ...)` |
| Underline, superscript, subscript | Dropped in GFM | Native `#underline[...]`, `#super[...]`, `#sub[...]` |
| Footnotes & repeated note references | Manual bottom dump `[^1]: ...` | Native inline `#footnote[...]` & `#footnote(<fn-id>)` |
| Internal bookmarks & cross-references | Fragile `<a id="...">` HTML | Native `<label>` + `#link(<label>)[...]` |
| Equations (Word OMML, ODF/EPUB MathML, TeX) | Raw LaTeX `$...$` | Translated native Typst math (`$ frac(a, b) $`) verified by `typst-syntax` |
| Embedded images (`.docx`, `.pptx`, `.rtf`, `.epub`, `.html`) | Alt text only | Extracted via `--assets-dir` + `#image("assets/asset-001.png", alt: "...")` |

## Supported Formats (18 Families, 35+ Extensions)

| Family | Extensions | Detection |
| --- | --- | --- |
| Microsoft Word | `.doc`, `.docx`, `.docm`, `.dotx`, `.dotm` | Content bytes (OLE `WordDocument` / OPC WordprocessingML) |
| Microsoft PowerPoint | `.ppt`, `.pps`, `.pot`, `.pptx`, `.pptm`, `.ppsx`, `.ppsm`, `.potx` | Content bytes (OLE `PowerPoint Document` / OPC PresentationML) |
| Microsoft Excel | `.xls`, `.xlsx`, `.xlsm`, `.xlsb`, `.xltx` | Content bytes (OLE `Workbook` / OPC SpreadsheetML) |
| OpenDocument | `.odt`, `.ott`, `.ods`, `.ots`, `.odp`, `.otp` | Content bytes (ODF `mimetype` / `manifest.xml`) |
| Rich Text Format | `.rtf` | Content bytes (`{\rtf`) |
| EPUB (2 & 3) | `.epub` | Content bytes (`application/epub+zip` / OCF `container.xml`) |
| PDF | `.pdf` | Content bytes (`%PDF-`) — parses into both `Document` and `.typ` |
| HTML / XHTML | `.html`, `.htm`, `.xhtml` | Content bytes (`<!DOCTYPE html` / `<html`) + extension |
| Markdown (CommonMark + GFM) | `.md`, `.markdown`, `.mdx` | Extension or `--format md` |
| LaTeX | `.tex`, `.latex`, `.ltx` | Extension or `--format tex` |
| Delimited Tables | `.csv`, `.tsv`, `.tab` | Extension or `--format csv` / `--format tsv` |
| JSON | `.json` | Extension or `--format json` |
| Plain Text | `.txt`, `.text` | Extension or `--format txt` |

## Quick Start

### CLI (Native Rust Binary)

```bash
cargo install --path .

anytyp report.docx                                        # Typst to stdout
anytyp slides.pptx -o slides.typ                          # write to .typ file
anytyp paper.docx -o paper.typ --assets-dir assets        # extract embedded images + emit #image(...)
anytyp paper.docx -o paper.typ --standalone --title "Spec" # include #set document / #set page / #set par
anytyp - --format csv < data.csv                          # read stdin
```

Exit codes: `0` success, `1` conversion/read error, `2` CLI usage error, `3` PDF contains scanned/image-only pages needing OCR.

### Swift (macOS 27+ & iOS 27+ — SwiftPM / Xcode)

Add `https://github.com/VM451/AnyTyp` to `Package.swift` (ships a prebuilt `CAnyTyp.xcframework` for `macos-arm64`, `ios-arm64`, and `ios-arm64-simulator` — no Rust toolchain required for app builds):

```swift
dependencies: [
    .package(url: "https://github.com/VM451/AnyTyp", branch: "main"),
]
```

```swift
import AnyTyp

// Synchronous or non-blocking @concurrent async from @MainActor ViewModels:
let typst = try await AnyTyp.convertAsync(
    fileURL,
    options: AnyTypOptions(
        standalone: true,
        title: "Quarterly Report",
        extractAssetsTo: assetsDirectoryURL
    )
)

// From in-memory Data or into the Sendable document AST:
let fromCSV = try AnyTyp.convert(csvData, format: .csv)
let doc = try await AnyTyp.parseDocumentAsync(docxData)
```

### Rust

```rust
use anytyp::{Format, RenderOptions};

let typst = anytyp::to_typst("report.docx")?;
let from_bytes = anytyp::to_typst_bytes(&bytes, None)?;
let from_csv = anytyp::to_typst_bytes(&csv_bytes, Format::Csv)?;

let doc = anytyp::to_document(&bytes, None)?;
anytyp::write_assets(&doc, "assets")?;
let standalone = anytyp::document_to_typst_with_options(
    &doc,
    &RenderOptions {
        standalone: true,
        title: Some("Annual Report".into()),
        assets_dir: Some("assets".into()),
    },
);
```

### Node.js

```js
import { toTypst, toTypstBytes, toDocument } from 'anytyp';

const typst = await toTypst('report.docx');
const fromCsv = await toTypstBytes(bytes, 'csv');
const doc = await toDocument(bytes);
```

### Python

```python
import anytyp

typst = anytyp.to_typst("report.docx")
from_csv = anytyp.to_typst_bytes(data, "csv")
doc = anytyp.to_document(data)
```

### WebAssembly

```js
import init, { toTypstBytes, toDocument } from 'anytyp-wasm';

await init();
const typst = toTypstBytes(bytes);
const doc = toDocument(bytes);
```

### Agent Skill

```bash
npx skills add VM451/AnyTyp
```

Ships an Agent Skill at `skills/convert-documents-to-typst/` teaching coding and document agents how to convert arbitrary office/PDF/legacy documents into `.typ` and extract embedded figures cleanly.

## How This Skill Improves

For maintainers evolving `skills/convert-documents-to-typst`:

- Capture repeated manual corrections and edge cases noticed during real conversion tasks rather than rewriting rules speculatively, then fold evidenced updates into `SKILL.md` or `references/formats-and-api.md` during scheduled reviews.
- `task-observer` automates session-level observation capture and staged review; benchmarked skill-evaluation harnesses score routing and behavioral compliance against control prompts.

## Verification

```bash
cargo test
RUSTFLAGS="-D warnings" cargo check --workspace
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Last verified 2026-11-22 · Re-test: `cargo test`

## License & Attribution

Licensed under the [MIT License](LICENSE).

Created and maintained by AnyTyp Contributors, improved by its community of users. Binary/archive office, ODF, RTF, EPUB, CSV, and PDF parser foundations and shared XML/OLE/math infrastructure derive from [`firecrawl/anydoc`](https://github.com/firecrawl/anydoc) (MIT License, Copyright (c) 2026 Sideguide Technologies Inc.); see [NOTICE](NOTICE).
