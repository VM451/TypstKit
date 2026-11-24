# UI Rule

- Do: Compose primitives (`TemplateCardView`, `CategoryPill`, `VersionBadge`, `ImportCopyButton`, `PackageDetailView`); configure via `.typstUniverseConfiguration(_)` + `onTemplateSelected/Scaffolded/ImportCopied`; keep observation-only (no view forks).
- Don't: Bypass `UniverseBrowserModel` for network/cache; hardcode locked kind/category (use config); add custom live preview without `TypstLivePreviewProviding`.
- Layout: `TypstUniverseBrowserView` / `TemplatePickerSheet` grid + category sidebar/pills; Dynamic Type-safe including Accessibility sizes; RTL mirroring.
- States: Empty/loading/error via model state machine; download progress via `fetch(spec)` async stream (queued → downloading → extracting → installed); VoiceOver labels/hints on cards/chips/pickers/progress; Reduced Motion / Increased Contrast where animation or color carries meaning.
