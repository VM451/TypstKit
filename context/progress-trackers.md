# Progress Trackers

## 2026-11-20 - Context kit scaffolded

- Done: Created flat `context/` kit (9 files) + root `AGENTS.md` from README, Package.swift, CONTRIBUTING.md, SECURITY.md, CHANGELOG.md evidence.
- Decisions: Default root `context/` (no `.context/` existed); no nested `AGENTS.md` created — recommend only for `Examples/UniverseExplorerApp` if its commands diverge.
- Risks: UI tokens/commands marked TBD where repo has no single source; verify with Xcode 27 toolchain.
- Next: Fill TBD items (accent/contrast audit, exact doc-build flags); keep kit in sync per AGENTS.md maintenance rule.

## 2026-11-25 - In-memory scaffold entrypoint API

- Done: Added `scaffoldTemplateInMemory` returning scaffolded files plus the manifest-declared template entrypoint; kept files-only `scaffoldInMemory` as a compatibility wrapper.
- Why: Host apps could otherwise guess the wrong first `.typ` file when templates expose multiple starters (for example resume plus cover letter).
- Verification: targeted `scaffoldTemplateInMemoryReportsManifestEntrypoint` regression passes; full `swift test` passes (including 539 core tests in 43 suites plus storage/UI/conversion lanes).

## 2026-11-25 - Headless universe products exported

- Done: Exported `TypstUniverseCore` and `TypstUniverseStorage` as standalone SwiftPM products while keeping umbrella `TypstUniverseKit`.
- Why: Headless hosts documented as Core+Storage consumers could not resolve those products after the repository consolidation into TypstKit.
- Verification: `swift package describe` exports both products; `swift build --target TypstUniverseStorage` passes in 45.64s. Prior full `swift test` passes on the scaffolder/API change.

## 2026-11-25 - Swift 6 zero-warning gate + GNU tar long-name fix

- Done: Restored the compiler-port zero-warning baseline after auditing `PARITY_TRACKER.md` and refreshing the upstream `typst` reference clone.
- Fixed: `SecureTarGzExtractor` now consumes padded GNU long-name payload blocks and applies the long name to the following entry; added `appliesGnuLongNameAcrossMultipleBlocks` regression coverage.
- Done: Converted `.none`-ambiguity warnings to explicit `Value.none`/`nil`, removed invalid effect markers, reworked closure-based array sorting error capture, and addressed Sendable-metatype diagnostics in `nativeFunc`/`Never`.
- Context: Refreshed stale product/system context in `project-overview.md` and `architecture.md` for the multi-product native Typst compiler rewrite.
- Review fixes: GNU long-name TAR entries now tolerate header copies that split UTF-8 scalars (22/22 storage tests pass); unset optional `fill` fields now remain unset so style-chain inheritance applies across boxes, blocks, shapes, curves, highlights, and outline entries (540/540 library tests pass).
- Review follow-up: `OutlineEntry.fill` now tracks explicit set state separately from its dotted-repeat default, so `fill: none` is readable as `none` while unset entries still inherit/resolve the default (541/541 library tests pass).
