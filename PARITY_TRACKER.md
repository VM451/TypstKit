# TypstKit Parity Tracker

Status: `Not Started` / `In Progress` / `Verified`.
Reference: `.reference/typst` @ latest main (cloned depth-1).

## Phase 0 — Audit & scaffold

- [x] Package.swift targets scaffolded (TypstUtils, TypstSyntax,
      TypstLibrary; Eval/Realize/Layout/Export/IDE dirs reserved)
- [x] ARCHITECTURE.md written
- [x] PARITY_TRACKER.md written
- [x] `swift build` green

## Phase 1 — TypstUtils & TypstSyntax

### TypstUtils

- [x] InternedString (string interner)
- [x] Unicode tables (XID start/continue, CJK script) via
      `Unicode.Scalar.Properties` + generated math-class table
      (unicode-math-class 0.1.0, unicode-ident 1.0.27)
- [ ] bitset.rs port
- [ ] hash.rs port (FxHash-equivalent hasher)
- [ ] collection.rs (smallvec/segmented vec equivalents)
- [ ] round.rs, scalar.rs, pico.rs, numeric helpers
- [ ] MemoCache (comemo analogue)

### TypstSyntax

- [x] SyntaxKind (full enum + predicates)
- [x] SyntaxMode
- [x] VirtualPath / RootedPath / VirtualRoot / FileId interner /
      PackageSpec / PackageVersion / PathError / RealizeError
- [x] Span / SpanNumber / SpanKind / DiagSpan / SubRange / Spanned
- [x] Source (source.rs: text, lines, encoding, edits, COW storage,
      find/range via LinkedNode)
- [x] Lines (lines.rs: line index, byte<->line/column mapping, edit/replace)
- [x] LinkedNode (linked.rs: cursor navigation, find/findRange,
      leafAt, prevLeaf/nextLeaf, modeAfter)
- [x] Lexer (lexer.rs: markup/code/math modes, all token kinds)
- [x] Parser (parser.rs: full CST construction, error recovery,
      packrat memoization for parenthesized exprs, depth cap)
- [x] Node (node.rs: SyntaxNode API — class + in-place mutation
      instead of Rust Arc CoW; see ARCHITECTURE.md)
- [x] set.rs (SyntaxSet bitmask + all grammar sets)
- [x] Operators (UnOp/BinOp/Assoc precedence tables from ast.rs)
- [x] AST (ast.rs: typed node accessors — 4 files, ~70 node types)
- [x] Reparser (reparser.rs: incremental reparse, tryReparseAndRenumber,
      markup/block expr reparsing, delimiter-balance + warning-safety
      checks, exponential renumbering)
- [x] package.rs remainder (PackageManifest/PackageInfo/TemplateInfo/ToolInfo/TomlValue model + validate; TOML decode deferred to TypstLibrary)
- [x] highlight.rs (HighlightTag, highlight(), highlightHTML; upstream test ported)
- [ ] Gate: upstream tests/suite/syntax ports pass

## Phase 2 — TypstLibrary & TypstEval

### TypstLibrary

- [x] SourceDiagnostic / Severity / Tracepoint / SourceResult /
      StrResult / HintedStrResult
- [ ] World protocol + WorldExt
- [ ] Value enum + all value types (int, float, bool, none, auto,
      content, array, dict, str, bytes, label, type, func, module,
      type, version, datetime, duration, ratio, relative, fraction,
      length, angle, color, gradient, stroke, sides, align, pad,
      margin, repeat, plugin?, symbolic)
- [ ] Content model (element tree, fields, styles)
- [ ] StyleChain / Styles
- [ ] Foundations: calc, str, array, dict, type, assert, eval, repr,
      panic, version, bytes, label, regex, json, yaml, toml, csv, xml,
      cbor, plugin, datetime, duration, float, int, bool, none, auto
- [ ] loading: data formats, packages, fonts
- [ ] model: document/page/par/text/table/grid/list/enum/terms/
      heading/figure/equation/outlines/notes/bibliography/cite/
      ref/footnote/state/counter/context/query/locate/metadata
- [ ] text: font, text, par, linebreak, hyphenate, lang, region,
      script, dir, costs, tracking, spacing, cjk
- [ ] visualize: image, shape, path, paint, tiling, curve
- [ ] math foundations
- [ ] symbols table
- [ ] engine (Engine/Route/Introspector)

### TypstEval

- [ ] Vm, scopes, bindings
- [ ] code.rs (expr eval), call.rs (args, closures, methods)
- [ ] markup.rs, math.rs eval
- [ ] flow.rs (loops, conditionals, return/break/continue)
- [ ] import.rs (module loading, import items)
- [ ] rules.rs (set/show/context registration)
- [ ] ops.rs, methods.rs, access.rs
- [ ] Gate: upstream tests/suite/scripting + foundations pass

## Phase 3 — TypstRealize & TypstLayout

- [ ] realize: show-rule expansion, style resolution, spaces
- [ ] layout core: Frame, Point/Size, regions, flow
- [ ] inline: collect, shaping (CoreText), linebreak (Knuth-Plass),
      line, align, bidi
- [ ] block/flow: par, block, box, stack, pad, align, place, columns,
      hide, measure
- [ ] pages: page, page run, margin/header/footer
- [ ] lists: list, enum, terms
- [ ] grid/table: grid, table, cell, header/footer, spans, strokes
- [ ] figure, outline, bibliography placement, footnote entry
- [ ] shapes & images layout
- [ ] math layout (basic; full engine in Phase 4)
- [ ] Gate: Fibonacci README doc + layout tests pass

## Phase 4 — Math, Introspection, Bibliography

- [ ] math layout: fragments, spacing, scripts, frac, sqrt, delimited,
      attach, align, mat, cases, accents, stretch
- [ ] OpenType MATH table reading
- [ ] introspection: context, locate, query, state, counter, metadata,
      label/ref, outline, footnote numbering
- [ ] bibliography: hayagriva-equivalent YAML/bibtex loading, CSL
      citation formatting
- [ ] Gate: upstream math/introspection/bibliography suites pass

## Phase 5 — Exporters & Incremental

- [ ] TypstExport: PDF (fonts subset, vectors, images, links, outlines,
      tags), SVG, raster CGImage/PNG, HTML
- [ ] MemoCache wiring for incremental recompile
- [ ] Gate: differential tests vs `.reference/typst/tests/ref`

## Phase 6 — Integration & TypstIDE

- [ ] TypstWorld package resolution via TypstUniverseKit
- [ ] AnyType end-to-end (doc -> .typ -> compile -> PDF/SVG/Image)
- [ ] TypstIDE: highlight spans, completion, tooltips, jump-to-source
- [ ] Public API docs + examples
- [ ] Final gate: all targets green, clean tree
