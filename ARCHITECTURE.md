# TypstKit Architecture

Native Swift rewrite of the Typst typesetting system (`typst/typst`,
Apache-2.0). Reference sources live in `.reference/typst` (gitignored).

## Target graph

```
TypstUtils      interning, bitsets, hash helpers, memoization cache
TypstSyntax     lossless CST: Source, Span/FileId, SyntaxKind, lexer,
                parser, AST accessors, incremental reparser
TypstLibrary    Value/Content model, StyleChain, World protocol,
                foundations (calc/str/array/dict/...), diagnostics
TypstEval       expression evaluator: scopes, closures, set/show rules,
                imports, module system
TypstRealize    show-rule expansion + style inheritance -> layout-ready
                element trees
TypstLayout     frames, text shaping (CoreText), line breaking,
                page/flow/grid/table/figure/math layout
TypstExport     PDF, SVG, raster (CGImage), HTML exporters
TypstIDE        highlighting, completion, tooltips, jump-to-source
TypstKit         umbrella product: TypstCompiler/TypstDocument/
                TypstWorld public API
```

Dependency direction is strictly downward (Kit -> Export -> Layout ->
Realize -> Eval -> Library -> Syntax -> Utils). No upward edges.

## Value & memory strategy

- `Value` and `Content` are reference types (`final class`, CoW where
  cheap) because upstream relies on cheap cloning + pointer-equality
  memoization keys (`comemo`). `Content` gets a unique `id` for
  memoization, mirroring upstream's `Content::id`.
- `Span` is a `UInt64` bit-packed value identical to upstream
  (`NonZeroU64`: 16-bit FileId | 48-bit number). `FileId` is a globally
  interned `UInt16` handle (lock-guarded interner, `NSLock`).
- Strings that appear as identifiers/field names/symbols use
  `InternedString` (TypstUtils) — a `UInt64` handle into a global pool.
- Syntax trees use `final class SyntaxNode` with in-place mutation
  (errors, kind conversion, child wrapping) instead of upstream's
  `Arc` copy-on-write. Rationale: the parser mutates nodes through
  markers (`p[m].convertToError`) in ways that map naturally to
  reference semantics; Swift arrays of class references give the same
  cheap-structural-sharing the parser's memo arena relies on. The
  reparser (`reparser.rs`) will add subtree reuse on top — immutable
  subtrees shared by reference already satisfy that need without a
  separate green/red split. `LinkedNode` (cursor with span context)
  is a lightweight struct over `SyntaxNode` + parent chain.

## Incremental compilation

Upstream uses `comemo` tracked-memoization. The Swift port uses a
`MemoCache` in TypstUtils: dependency-tracked function memoization keyed
by argument hash + generation counter; `Source.edit` bumps the file
generation so dependent entries invalidate. Constraint-tracked accesses
are modeled explicitly (`Tracked<T>` reads register dependencies).

## Text shaping & layout

CoreText (`CTLine`, `CTFont`, `CTRun`) for glyph shaping, advances,
and font fallback; `CTTypesetter`-style line breaking is replaced by a
Swift Knuth-Plass implementation over CoreText-measured glyph runs, with
hyphenation via `CTTypesetter` suggestion APIs where available. All
layout math uses `CGFloat`-free fixed-point-ish `Double` points matching
upstream's `Scalar` (f64) semantics.

## Diagnostics

`SourceResult<T> = Result<T, SourceDiagnostics>` and
`StrResult<T> = Result<T, StrError>` mirror upstream's
`Result<T, EcoVec<SourceDiagnostic>>` / `Result<T, EcoString>` — Swift's
`Result` requires `Failure: Error`, so the payloads are boxed in
`Error`-conforming wrappers (`SourceDiagnostics`, `StrError`,
`HintedError`).

## Swift/Rust idiom mapping notes

- `#[elem]`/`#[func]` proc macros -> hand-written Swift element/function
  registrations (no macro expansion needed; elements are `final class`
  conforming to `NativeElement`-style protocols).
- Trait objects (`dyn World`) -> `any TypstWorld` protocol existential.
- `EcoVec`/`EcoString` -> `Array`/`String` plus `InternedString` where
  identity matters.
- `LazyLock`/`RwLock` interners -> `NSLock`-guarded singletons.
