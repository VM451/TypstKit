# Project Overview

- What: TypstKit monorepo — a native Swift rewrite of the Typst typesetting system plus two supporting products: TypstUniverseKit (Typst Universe registry/scaffolding SDK) and AnyTyp (external document-to-`.typ` conversion).
- State: TypstUniverseKit is v1.0.0-draft quality; the pure-Swift Typst compiler port is in progress (syntax/eval/realize/introspection infrastructure exist; layout/export are the largest incomplete areas).
- Users: Apple app developers embedding Typst compilation, template browsing/scaffolding, or document conversion; end users working with Typst documents and templates.
- In scope: Native compiler/parser/evaluator/layout/exporters, catalog sync + search, secure tar.gz download/extract, template scaffolding, curated storefront, SwiftUI browser + picker, offline-first cache, document conversion.
- Out of scope: Rust/C/C++/WASM compiler embedding or runtime shell-outs to the `typst` CLI; Typst Pro account APIs; package-submission automation.
- Goals: Zero third-party runtime deps; offline-first; secure-by-default extraction; strict Swift 6 with zero warnings; upstream Typst parity tracked in `PARITY_TRACKER.md`.
- Non-goals: Linux/server support; CI automation (verify locally); SQLite/FTS5 until catalog > ~25k entries (v2.0 candidate).
- Glossary: Universe = packages.typst.org registry; Spec = `PackageSpec(@preview/name:version)`; Scaffold = download + extract + `typst init` layout; ETag sync = stale-while-revalidate catalog fetch.
- Open questions: Font parsing/shaping strategy for `Frame`/layout (CoreText vs pure-Swift OpenType subset); exact export target decomposition.
