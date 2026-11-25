# Architecture

- Components:
  - `TypstUtils` (Foundation-only): interning, Unicode/math tables, scalar/rounding helpers, lazy hashing, space-discarding tables.
  - `TypstSyntax` (depends on Utils): lossless CST, source/spans/file IDs, lexer/parser/AST, incremental reparser, highlighting.
  - `TypstLibrary` (depends on Syntax+Utils): values/content/styles, foundations, evaluator, realization, introspection, loading formats, model/layout element definitions. Eval/realize are internal namespaces in this target because closures, elements, and style rules are mutually recursive.
  - `TypstUniverseCore` (Foundation-only): Models (`SemanticVersion`, `UniversePackage`, `PackageSpec`, `TypstManifest`, 19 `UniverseCategory` + custom fallback), `IndexDecoder`/`VersionGrouper`, `OfficialUniverseRegistry` (ETag), `UniverseSearchEngine`, `TypstTomlParser`, `TypstUniverseError`, `KitLog`.
  - `TypstUniverseStorage` (depends on Core): `SecureTarGzExtractor`, `PackageCacheManager` (actor), `TemplateScaffolder` (disk projects + in-memory bundles with manifest entrypoints), `LocalNamespaceScanner`, `TypstUniverseClient` facade.
  - `TypstUniverseUI` (depends on Core+Storage, SwiftUI): `UniverseBrowserModel` (@Observable state machine), `ThumbnailPipeline`, `TypstUniverseBrowserView`/`TemplatePickerSheet`/`PackageDetailView`, cards/pills/badges, `TypstUniverseConfiguration`.
  - `AnyTyp` + `AnyTypCLI`: pure-Swift document parsers/renderers for external formats; uses internal `CZlib` only for compression interop.
  - `Examples/UniverseExplorerApp`: runnable reference app (own Package.swift, path dep on `../..`).
- Data flow: `.typ` source → syntax CST → evaluated content/styles → realized element tree → layout frames (incomplete) → exporters (not started); `preview/index.json` (ETag-cached) → `{name}-{version}.tar.gz` (immutable, cached) → `thumbnails/*.webp` → `typst.toml` `[package]`/`[template]` tables.
- Boundaries: Core has no network/cache/UI deps; Storage owns all registry I/O + extraction; UI never touches network directly (via model/client); Typst compiler library targets never invoke Rust, WASM, or the `typst` executable at runtime; unknown JSON fields/categories degrade gracefully.
- Key decisions:
  - 2026-11-20: Offline-first stale-while-revalidate sync; atomic staging+rename installs.
  - 2026-11-20: Pure-Swift gzip/TAR/TOML to keep zero runtime deps.
  - 2026-11-20: Removed Linux support + GitHub Actions CI; Apple platforms + local Xcode 27 verification only.
  - 2026-11-25: Keep eval/realize inside `TypstLibrary` rather than splitting premature SwiftPM targets while element/evaluator recursion stabilizes; revisit target decomposition when layout/export land.
