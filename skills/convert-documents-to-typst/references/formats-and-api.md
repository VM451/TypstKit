# Formats, Typst Mapping, Asset Extraction, and Library APIs

Load triggers: passing `--assets-dir`, `--standalone`, `--title`, or `--format`; handling exit code `3` (`NeedsOcr`); calling `anytyp` from Swift, Rust, Node.js, Python, or WebAssembly; checking how specific source constructs map to Typst 0.15. Return to `SKILL.md` for core invocation rules.

Convert Documents to Typst: AnyTyp Contributors and contributors | MIT

## Typst 0.15 Output Mapping

Every input format parses into one resolved intermediate `Document` AST and renders through a single Typst 0.15 serializer verified by `typst-syntax`:

| Source construct | Emitted Typst 0.15 syntax |
| --- | --- |
| Headings (levels 1–6 / 7+) | `= H1` … `====== H6` / `#heading(level: N)[...]` |
| Cross-referenced heading or bookmark | `= Section <sec-id>` / `#metadata(none) <bm-id>` + `#link(<sec-id>)[...]` |
| Bold / italic / underline / strike | `*bold*` (or `#strong[...]`), `_italic_` (or `#emph[...]`), `#underline[...]`, `#strike[...]` |
| Superscript / subscript / inline code | `#super[...]`, `#sub[...]`, `` `code` `` (or `#raw("...")` when containing backticks) |
| Bullet / decimal ordered lists | `- item` / `+ item` |
| Roman, alpha, or offset ordered lists | `#enum(numbering: "i.", start: 4, [...], ...)` |
| Data tables with headers & merges | `#table(columns: N, table.header(...), table.cell(colspan: C, rowspan: R)[...], ...)` |
| Layout-only tables | Unwrapped if 1×1; `#grid(columns: N, gutter: 0.65em, ...)` when multi-cell |
| Footnotes & repeated footnote refs | `#footnote[...]` (or `#footnote[...] <fn-id>` + `#footnote(<fn-id>)`) |
| Equations (OMML, MathML, RTF, TeX) | Translated via `mitex` to native Typst math (`$frac(a, b)$`, `$ sum_(i=1)^n i $`) with `typst-syntax` verification and raw `tex` fallback |
| Embedded images (`--assets-dir`) | Extracted as `asset-001.png` (`.jpg`, `.gif`, `.svg`, `.webp`) and emitted as `#image("...", alt: "...")` |
| External image URLs | `#link("https://...")[alt]` (Typst `#image` accepts local files only, never remote URLs) |

## CLI Options Reference

- `-o, --output <path>`: write `.typ` output to `<path>`. When paired with `--assets-dir <dir>`, `anytyp` strips `<output>`'s parent prefix from `<dir>` when `<dir>` sits beside `<output>`, so `#image("assets/asset-001.png")` resolves directly under `typst compile <output>`.
- `--assets-dir <dir>`: write embedded PNG, JPEG, GIF, SVG, and WebP payloads from `Document.assets` into `<dir>`. Non-Typst binary payloads (such as raw OLE objects or EMF/WMF metafiles) stay off disk and degrade to alt text so `typst compile` never fails on unsupported image formats.
- `--standalone`: prepend `#set page(numbering: "1")` and `#set par(justify: true)`. Omit when including the output into a larger Typst project or template via `#include`.
- `--title <title>`: add `#set document(title: "...")` and imply `--standalone`.
- `-f, --format <fmt>`: canonical names are `doc`, `docx`, `odt`, `pdf`, `ppt`, `pptx`, `rtf`, `epub`, `xlsx`, `ods`, `odp`, `csv`, `tsv`, `md`, `html`, `tex`, `json`, `txt`. Common extensions (`xls`, `xlsb`, `docm`, `ppsx`, `markdown`, `latex`, `htm`) resolve to the same parsers.

## Handling Exit Code 3 (`NeedsOcr`)

`anytyp` extracts text-based PDFs locally without network calls or ML weights. When any page of a PDF is scanned or image-only, `anytyp` exits `3` and names the exact 1-indexed page numbers on stderr (for example `anytyp: pages 2, 5-7 of 12 need OCR`) instead of silently returning incomplete text. When exit code `3` occurs:

1. Report the exact page range that requires OCR to the user.
2. Run an OCR pre-pass (for example `ocrmypdf` locally if installed, or an OCR service the user approves) to produce a searchable PDF or text transcript, then convert to `.typ`.

## Library APIs

### Swift (`AnyTyp` — macOS 27+ / iOS 27+)

```swift
import AnyTyp

let typst = try await AnyTyp.convertAsync(
    fileURL,
    options: AnyTypOptions(standalone: true, title: "Quarterly Report", extractAssetsTo: assetsURL)
)
let fromCSV = try AnyTyp.convert(csvData, format: .csv)
let doc = try await AnyTyp.parseDocumentAsync(docxData)
```

### Rust (`anytyp`)

```rust
use anytyp::{Format, RenderOptions};

let typst = anytyp::to_typst("report.docx")?;
let from_csv = anytyp::to_typst_bytes(csv_bytes, Format::Csv)?;

let doc = anytyp::to_document(&docx_bytes, None)?;
anytyp::write_assets(&doc, "out/assets")?;
let standalone = anytyp::document_to_typst_with_options(
    &doc,
    &RenderOptions {
        standalone: true,
        title: Some("Quarterly Report".into()),
        assets_dir: Some("assets".into()),
    },
);
```

### Node.js (`anytyp`)

```js
import { toTypst, toTypstBytes, toDocument } from 'anytyp';

const typst = await toTypst('report.docx', { standalone: true, title: 'Report' });
const fromCsv = await toTypstBytes(bytes, 'csv');
const doc = await toDocument(bytes);
```

### Python (`anytyp`)

```python
import anytyp

typst = anytyp.to_typst("report.docx", standalone=True, title="Report")
from_csv = anytyp.to_typst_bytes(data, "csv")
doc = anytyp.to_document(data)
```

### WebAssembly (`anytyp-wasm`)

```js
import init, { toTypstBytes, toDocument } from 'anytyp-wasm';

await init();
const typst = toTypstBytes(bytes);
const doc = toDocument(bytes);
```
