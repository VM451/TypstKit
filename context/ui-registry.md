# UI Registry

## TypstUniverseBrowserView

- Where: `Sources/TypstUniverseUI/Views/BrowserViews.swift`
- Pattern: Grid + sidebar entry point; takes `UniverseBrowserModel`; honors `TypstUniverseConfiguration` environment.

## TemplatePickerSheet

- Where: `Sources/TypstUniverseUI/Views/BrowserViews.swift` (re-exported)
- Pattern: Sheet flow — browse → Use Template → scaffolds via client → returns `ScaffoldedTemplateProject` in completion.

## PackageDetailView

- Where: `Sources/TypstUniverseUI/Views/PackageDetailView.swift`
- Pattern: Detail screen with `importSnippet()` / `initCommand()` + `ImportCopyButton`; Official badge when `isOfficialTemplate`.

## TemplateCardView

- Where: `Sources/TypstUniverseUI/Components/TemplateCardView.swift`
- Pattern: Card with WebP thumbnail (`ThumbnailPipeline`), category, version; VoiceOver label, Dynamic Type-safe.

## CategoryPill / VersionBadge / ImportCopyButton

- Where: `Sources/TypstUniverseUI/Components/Components.swift`
- Pattern: Capsule pill filter (selected state), monospaced version capsule, clipboard copy with Copied state + `onPackageImportCopied` hook.

## UniverseBrowserModel

- Where: `Sources/TypstUniverseUI/Store/UniverseBrowserModel.swift`
- Pattern: `@Observable` `@MainActor` state machine driving all views; never bypass for fetches.
