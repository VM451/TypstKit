# UI Token

- Colors: Configurable accent via `TypstUniverseConfiguration.accentColor` (`ColorRepresentable`, default r:0.1 g:0.45 b:1.0); secondary fills at 12% opacity; selected pill accent at 20% opacity — TBD: full palette audit.
- Spacing: Pill `H:10 V:6` + `HStack(spacing: 4)`; badge `H:6 V:3` (from `Components.swift`) — TBD: global spacing scale.
- Radius: Capsule pills/badges (`.clipShape(Capsule())`) — TBD: corner-radius scale for cards/sheets.
- Type: `.caption` pills + `.caption.monospacedDigit()` versions; Dynamic Type-safe incl. Accessibility sizes — TBD: full type ramp.
- Motion/contrast: Respect Reduce Motion + Increased Contrast where animation/color carries meaning; mirror for RTL.
