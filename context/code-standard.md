# Code Standard

- Style: Swift 6, zero warnings (`-strict-concurrency=complete`); public models are `Sendable` value types; shared mutable state in actors; UI is `@Observable` on `@MainActor`.
- Naming: Conventional Commits per scope (`feat(core-search): …`, `fix(storage-cache): …`, `test(ui): …`, `docs(readme): …`); imperative subject ≤ 72 chars; one logical unit per commit.
- Logging: No `print()` in library code — use `KitLog` (`Logger(subsystem: "dev.typstuniversekit", category: …)`).
- Dependencies: No third-party runtime deps (Foundation, URLSession, ImageIO, in-house gzip/TAR/TOML only); new exceptions need an issue first.
- Testing: Every behavior change ships tests — Core → `Tests/TypstUniverseCoreTests/CoreTests.swift`, Storage/security → `Tests/TypstUniverseStorageTests/StorageTests.swift`, UI → `Tests/TypstUniverseUITests/` (XCTestCase).
- Docs: Public API needs `///` DocC comments; user behavior goes in README + relevant `Documentation.docc` article.
- Git: fine-grained atomic commits to `main`; focused PRs with what/why + `swift build` / `swift test` output.
