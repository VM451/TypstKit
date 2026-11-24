# Build Plan

- [ ] Phase 1 — v1.0 (draft for architecture review, this release): Core + Storage + UI + example app.
  - [x] Core models, IndexDecoder, registry ETag sync, search engine, TOML parser.
  - [x] Extractor + cache manager + scaffolder + local scanner + client facade.
  - [x] Browser model, thumbnail pipeline, picker/detail/cards, config hooks, privacy manifest.
  - [x] 26 tests + README + DocC catalogs + UniverseExplorerApp.
- [ ] Phase 2 — Unreleased (per CHANGELOG): DocC plugin declaration; OS 27 floor; drop Linux + CI; `CuratedCollection.officialTemplates` + `isOfficialTemplate` + Official badge.
- [ ] Phase 3 — v2.0 (if needed): SQLite/FTS5 backing store past ~25k entries; optional remote curated-collection feed.
- Descoped: Typst compiler bundling; Typst Pro APIs; submission automation.
