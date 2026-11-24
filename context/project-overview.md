# Project Overview

- What: TypstUniverseKit — native Swift SDK to search, download, and scaffold the Typst Universe package registry inside Apple apps.
- State: v1.0.0 draft for architecture review + Unreleased changes (see CHANGELOG.md).
- Users: Apple app developers (headless SDK users, SwiftUI turnkey UI users); end users picking Typst templates (CVs, theses, papers, presentations, drawing libs).
- In scope: Catalog sync + search, secure tar.gz download/extract, template scaffolding (`typst init` parity), curated storefront, SwiftUI browser + picker, offline-first cache.
- Out of scope: Bundling the Typst compiler (bring via `TypstLivePreviewProviding`); Typst Pro account APIs; package-submission automation.
- Goals: Zero third-party runtime deps; offline-first; secure-by-default extraction; strict Swift 6 with zero warnings.
- Non-goals: Linux/server support (removed); CI automation (removed — verify locally); SQLite/FTS5 until catalog > ~25k entries (v2.0 candidate).
- Glossary: Universe = packages.typst.org registry; Spec = `PackageSpec(@preview/name:version)`; Scaffold = download + extract + `typst init` layout; ETag sync = stale-while-revalidate catalog fetch.
- Open questions: - TBD (e.g. v2.0 remote curated-feed shape).
