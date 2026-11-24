# Library Docs

- Stack: Swift 6.4+ (`swift-tools-version: 6.4`, `-strict-concurrency=complete`), iOS/iPadOS 27+, macOS 27+, visionOS 27+; Xcode 27+ required for UI + full suite.
- Foundation: value models, URLSession sync, FileManager atomic installs; Core stays Foundation-only (also builds on Linux).
- URLSession: `OfficialUniverseRegistry` ETag / `If-None-Match` catalog fetch; `PackageCacheManager` HTTPS-only archive download with dedup.
- ImageIO: `ThumbnailPipeline` decodes WebP thumbnails off-main with NSCache + disk cache.
- In-house gzip/TAR/TOML: `SecureTarGzExtractor` (pure-Swift inflate + USTAR) + `TypstTomlParser` (typst.toml only) — avoids third-party deps.
- SwiftUI (@Observable, @MainActor): browser views, cards, pills, environment config (`typstUniverseConfiguration`, `onTemplateSelected/Scaffolded/ImportCopied`).
- swift-docc-plugin 1.0.0+: build tooling only for `swift package generate-documentation`; never linked.
- Swift Testing (`@Suite`/`@Test`): Core + Storage suites; XCTestCase only for UI tests so they compile under CLT toolchain.
