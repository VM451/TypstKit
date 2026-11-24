# AGENTS.md

Agent entry point. Durable context lives in `context/` — read this file first, then the context files you need. Keep code and context in sync: every code change ends with a context update in the same turn.

## Session protocol

1. Read `context/project-overview.md` and `context/progress-trackers.md` first (what this is, where it stands).
2. Read `context/architecture.md` + `context/code-standard.md` before touching code; add `context/library-docs.md` when using a dependency and `context/ui-*.md` when touching UI.
3. Build, then run lint + tests.
4. Update the affected `context/` files (see Context maintenance) before reporting done.

## Context map

- Product: `context/project-overview.md`
- System: `context/architecture.md`, `context/library-docs.md`
- Plan: `context/build-plan.md`, `context/progress-trackers.md`
- Standards: `context/code-standard.md`
- UI: `context/ui-rule.md`, `context/ui-registry.md`, `context/ui-token.md`

## Context maintenance (auto-update, no prompt needed)

After every code change — feature, fix, refactor, dependency, or UI work — update the affected `context/` files in the same turn, without being asked. The user should never have to say "update the context".

- Update one file or several, depending on what changed. Small change: one file. Feature: usually two to four.
- Routing: product/scope change → `project-overview.md`; structure/data-flow change → `architecture.md`; dependency added/removed/upgraded → `library-docs.md`; feature planned/started/finished → `build-plan.md`; convention introduced/changed → `code-standard.md`; component built/changed → `ui-registry.md`; visual value changed → `ui-token.md`; UI rule changed → `ui-rule.md`.
- Always append a dated entry to `context/progress-trackers.md` on feature work, fixes, and decisions.
- Never rewrite history in `progress-trackers.md` — append corrections as dated notes.
- Keep each file short and factual; match its existing format.

## Setup commands

- Install deps: TBD (SPM — no extra install; Xcode: File → Add Package Dependencies… with `https://github.com/VM451/TypstUniverseKit`)
- Start dev: TBD (see `Examples/UniverseExplorerApp` reference app)
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
- Build Core only: `swift build --target TypstUniverseCore`

## Testing

- Run tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- Filtered: `swift test --filter TypstUniverseCoreTests`
- Lint: TBD (Swift 6 zero-warnings build is the gate; no separate lint config)
- Always run lint + tests before finishing a task.

## Code style

- Stack: Swift 6.4 + SwiftUI, iOS/macOS/visionOS 27+, Xcode 27+, strict concurrency complete.
- Public models are `Sendable` values; shared state in actors; UI `@Observable` on `@MainActor`.
- No `print()` in library code — use `KitLog`; no third-party runtime deps.
- Prefer existing patterns over introducing new ones.

## Project structure

- `Sources/TypstUniverseCore/`: models, registry, search, TOML parsing (Foundation-only).
- `Sources/TypstUniverseStorage/`: extractor, cache, scaffolding, local scan, client.
- `Sources/TypstUniverseUI/`: store, views, components, media, config.
- `Tests/`: `TypstUniverseCoreTests/`, `TypstUniverseStorageTests/`, `TypstUniverseUITests/`.
- `Examples/UniverseExplorerApp/`: runnable reference app.

## Git workflow

- Branch: TBD; commits: fine-grained atomic Conventional Commits (`feat(core-search): …`), imperative ≤ 72 chars.
- PR title: TBD (`<type>(<scope>): …`); include what/why + `swift build` / `swift test` output.

## Boundaries (never do)

- Never commit secrets, credentials, or `.env` contents.
- Never touch: `.build/`, `DerivedData/`, `Package.resolved` (library-ignored), generated docs.
- Never weaken `SecureTarGzExtractor` guards without a regression test in `StorageTests.swift`.
- Never create subfolders inside `context/` — nine flat files only.

## Security

- Archive handling is security-critical: report bypasses privately per `SECURITY.md`, never as a public issue; HTTPS-only fetches; atomic installs.
