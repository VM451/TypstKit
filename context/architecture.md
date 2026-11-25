# Architecture

- Components:
  - `TypstUniverseCore` (Foundation-only): Models (`SemanticVersion`, `UniversePackage`, `PackageSpec`, `TypstManifest`, 19 `UniverseCategory` + custom fallback), `IndexDecoder`/`VersionGrouper`, `OfficialUniverseRegistry` (ETag), `UniverseSearchEngine`, `TypstTomlParser`, `TypstUniverseError`, `KitLog`.
  - `TypstUniverseStorage` (depends on Core): `SecureTarGzExtractor`, `PackageCacheManager` (actor), `TemplateScaffolder` (disk projects + in-memory bundles with manifest entrypoints), `LocalNamespaceScanner`, `TypstUniverseClient` facade.
  - `TypstUniverseUI` (depends on Core+Storage, SwiftUI): `UniverseBrowserModel` (@Observable state machine), `ThumbnailPipeline`, `TypstUniverseBrowserView`/`TemplatePickerSheet`/`PackageDetailView`, cards/pills/badges, `TypstUniverseConfiguration`.
  - `Examples/UniverseExplorerApp`: runnable reference app (own Package.swift, path dep on `../..`).
- Data flow: `preview/index.json` (ETag-cached) → `{name}-{version}.tar.gz` (immutable, cached) → `thumbnails/*.webp` → `typst.toml` `[package]`/`[template]` tables.
- Boundaries: Core has no network/cache/UI deps; Storage owns all I/O + extraction; UI never touches network directly (via model/client); unknown JSON fields/categories degrade gracefully.
- Key decisions:
  - 2026-11-20: Offline-first stale-while-revalidate sync; atomic staging+rename installs.
  - 2026-11-20: Pure-Swift gzip/TAR/TOML to keep zero runtime deps.
  - 2026-11-20: Removed Linux support + GitHub Actions CI; Apple platforms + local Xcode 27 verification only.
