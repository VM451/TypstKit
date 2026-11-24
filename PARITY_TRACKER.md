# TypstKit Parity Tracker

Status: `Not Started` / `In Progress` / `Verified`.
Reference: `.reference/typst` @ latest main (cloned depth-1).

## Phase 0 — Audit & scaffold

- [x] Package.swift targets scaffolded (TypstUtils, TypstSyntax,
      TypstLibrary; Eval/Realize/Layout/Export/IDE dirs reserved)
- [x] ARCHITECTURE.md written
- [x] PARITY_TRACKER.md written
- [x] `swift build` green

## Phase 1 — TypstUtils & TypstSyntax

### TypstUtils

- [x] InternedString (string interner)
- [x] Unicode tables (XID start/continue, CJK script) via
      `Unicode.Scalar.Properties` + generated math-class table
      (unicode-math-class 0.1.0, unicode-ident 1.0.27)
- [ ] bitset.rs port
- [ ] hash.rs port (FxHash-equivalent hasher)
- [ ] collection.rs (smallvec/segmented vec equivalents)
- [ ] round.rs, scalar.rs, pico.rs, numeric helpers
- [ ] MemoCache (comemo analogue)

### TypstSyntax

- [x] SyntaxKind (full enum + predicates)
- [x] SyntaxMode
- [x] VirtualPath / RootedPath / VirtualRoot / FileId interner /
      PackageSpec / PackageVersion / PathError / RealizeError
- [x] Span / SpanNumber / SpanKind / DiagSpan / SubRange / Spanned
- [x] Source (source.rs: text, lines, encoding, edits, COW storage,
      find/range via LinkedNode)
- [x] Lines (lines.rs: line index, byte<->line/column mapping, edit/replace)
- [x] LinkedNode (linked.rs: cursor navigation, find/findRange,
      leafAt, prevLeaf/nextLeaf, modeAfter)
- [x] Lexer (lexer.rs: markup/code/math modes, all token kinds)
- [x] Parser (parser.rs: full CST construction, error recovery,
      packrat memoization for parenthesized exprs, depth cap)
- [x] Node (node.rs: SyntaxNode API — class + in-place mutation
      instead of Rust Arc CoW; see ARCHITECTURE.md)
- [x] set.rs (SyntaxSet bitmask + all grammar sets)
- [x] Operators (UnOp/BinOp/Assoc precedence tables from ast.rs)
- [x] AST (ast.rs: typed node accessors — 4 files, ~70 node types)
- [x] Reparser (reparser.rs: incremental reparse, tryReparseAndRenumber,
      markup/block expr reparsing, delimiter-balance + warning-safety
      checks, exponential renumbering)
- [x] package.rs remainder (PackageManifest/PackageInfo/TemplateInfo/ToolInfo/TomlValue model + validate; TOML decode deferred to TypstLibrary)
- [x] highlight.rs (HighlightTag, highlight(), highlightHTML; upstream test ported)
- [x] Gate: upstream tests/suite/syntax ports pass
      (SyntaxSuiteTests: 10 vendored corpus files, 38 sections; every
      emitted parse diagnostic matches annotations exactly — kind, byte
      range, message. Eval-stage annotations tracked in
      `expectedUnevaluated` until TypstEval lands.)

## Phase 2 — TypstLibrary & TypstEval

### TypstLibrary

- [x] SourceDiagnostic / Severity / Tracepoint / SourceResult /
      StrResult / HintedStrResult
- [ ] World protocol + WorldExt
- [x] Value enum + all value types (int, float, bool, none, auto,
      content, array, dict, str, bytes, label, type, func, module,
      type, version, datetime, duration, ratio, relative, fraction,
      length, angle, color, gradient, stroke, sides, align, pad,
      margin, repeat, plugin?, symbolic)
- [x] Content model (element tree, fields, styles)
- [x] StyleChain / Styles
- [ ] Foundations: ~~calc~~, ~~str~~ (scope: all 21 methods +
      constructor, 9 direct-call tests green), ~~array~~, ~~dict~~,
      type, ~~assert~~, eval, ~~repr~~, ~~panic~~, ~~version~~,
      ~~bytes~~, ~~label~~, ~~regex~~ (constructor scope), json, yaml,
      ~~toml~~, ~~csv~~, ~~xml~~, ~~cbor~~, ~~yaml~~, plugin, ~~datetime~~, ~~duration~~, ~~float~~,
      ~~int~~, ~~decimal~~, ~~type~~, ~~symbol~~ (constructor),
      bool, none, auto; content methods (func/has/at/
      fields/location); location value type (scope methods
      deferred to introspection) (eval/plugin/target/sys deferred to eval
      and loading milestones); ~~sys~~ module (version + inputs via
      Library.withInputs); ~~target~~ (Target cast enum + TargetElem +
      contextual target() — plugin deferred: needs wasm runtime)
      — datetime/duration/version scopes + time-crate format engine
      ported (construct/today/display/accessors, unit methods, variadic
      version + at/fields); World.today now takes `Duration?` and
      `WorldTime` (fixed/system clock) ported from typst-kit; Version
      `Ord` zero-padding fixed; fields.rs ported (length/rel/stroke/
      align field access); array scope fully ported (all 25 methods
      incl. callback methods dispatching via Func.call — closures work
      once eval installs evalClosure; mutating methods return copies
      pending call_method_mut); dict scope (constructor module→dict,
      len/at/insert/remove/keys/values/pairs); bytes scope
      (ToBytes cast + len/at/slice with end/count mutual exclusion);
      label constructor; global `range` wired into foundations module;
      ops_compare default arm fixed to type names (upstream
      mismatch! semantics); int scope (construct with base:/radix
      parsing matching Rust from_str_radix incl. pos/neg overflow
      kinds, max/min constants, signum, bit-and/or/xor/not/lshift/
      rshift with logical param + saturation, from-bytes/to-bytes
      with endian/size/signed); float scope (construct via ToFloat
      union incl. ratio/decimal/string, inf/nan constants, is-nan/
      is-infinite/signum with upstream NaN/-0.0 semantics, from-bytes/
      to-bytes f64/f32 endian/size); decimal scope (construct via
      ToDecimal union, strict from_str_exact literal validation,
      is-integer/abs/floor/ceil/trunc/fract/round; Decimal.MIN/MAX fixed
      to real rust_decimal bounds; float->decimal now uses exact binary
      expansion rounded to 28 sig digits — may differ 1 ulp in last
      digit vs rust_decimal); type() constructor returns value's type;
      symbol() constructor with full variant validation (grapheme
      check, ident modifiers, canonical dedup with ordering hint);
      isIdent made public in TypstSyntax; 126 direct-call tests green
- [ ] loading: data formats, packages, fonts
      — IN PROGRESS: loading infra ported (DataSource/Load/Loaded/
      LoadError/LoadedWithin/LineCol/ReportTextPos in Loading.swift);
      path.rs ported (RootedPath #[ty] "path" + path() constructor +
      PathOrStr resolve/resolve_if_some); read/json(+encode)/csv ported
      in LoadingFormats.swift (json uses custom serde_json-faithful
      encoder: sorted keys, .0 floats, repr fallback; csv is a minimal
      rust-csv-semantics parser); VirtualPath.normalize now errors on
      `..` escaping root (upstream PathError::Escapes — was silently
      clamping); xml/cbor/toml/yaml ported (LoadingXML.swift roxmltree-
      faithful parser; LoadingCBOR.swift RFC 8949 codec; LoadingTOML.swift
      TOML 1.0 subset parser w/ $__toml_private_datetime sentinel +
      reference-tree TomlTable; LoadingYAML.swift YAML 1.2 subset parser —
      block/flow collections, block scalars, tags-ignored, i64-overflow→
      float per upstream docs; all six formats have .encode scopes where
      upstream does); 46 Loading tests green, 188 library tests total
- [ ] model: document/page/par/text/table/grid/list/enum/terms/
      heading/figure/equation/outlines/notes/bibliography/cite/
      ref/footnote/state/counter/context/query/locate/metadata
- [ ] text: font, text, par, linebreak, hyphenate, lang, region,
      script, dir, costs, tracking, spacing, cjk
- [ ] visualize: image, shape, path, paint, tiling, curve
- [ ] math foundations
- [ ] symbols table
- [x] engine (Engine/Route/Introspector)

### TypstEval

- [ ] Vm, scopes, bindings
- [ ] code.rs (expr eval), call.rs (args, closures, methods)
- [ ] markup.rs, math.rs eval
- [ ] flow.rs (loops, conditionals, return/break/continue)
- [ ] import.rs (module loading, import items)
- [ ] rules.rs (set/show/context registration)
- [ ] ops.rs, methods.rs, access.rs
- [ ] Gate: upstream tests/suite/scripting + foundations pass

## Phase 3 — TypstRealize & TypstLayout

- [ ] realize: show-rule expansion, style resolution, spaces
- [ ] layout core: Frame, Point/Size, regions, flow
- [ ] inline: collect, shaping (CoreText), linebreak (Knuth-Plass),
      line, align, bidi
- [ ] block/flow: par, block, box, stack, pad, align, place, columns,
      hide, measure
- [ ] pages: page, page run, margin/header/footer
- [ ] lists: list, enum, terms
- [ ] grid/table: grid, table, cell, header/footer, spans, strokes
- [ ] figure, outline, bibliography placement, footnote entry
- [ ] shapes & images layout
- [ ] math layout (basic; full engine in Phase 4)
- [ ] Gate: Fibonacci README doc + layout tests pass

## Phase 4 — Math, Introspection, Bibliography

- [ ] math layout: fragments, spacing, scripts, frac, sqrt, delimited,
      attach, align, mat, cases, accents, stretch
- [ ] OpenType MATH table reading
- [ ] introspection: context, locate, query, state, counter, metadata,
      label/ref, outline, footnote numbering
- [ ] bibliography: hayagriva-equivalent YAML/bibtex loading, CSL
      citation formatting
- [ ] Gate: upstream math/introspection/bibliography suites pass

## Phase 5 — Exporters & Incremental

- [ ] TypstExport: PDF (fonts subset, vectors, images, links, outlines,
      tags), SVG, raster CGImage/PNG, HTML
- [ ] MemoCache wiring for incremental recompile
- [ ] Gate: differential tests vs `.reference/typst/tests/ref`

## Phase 6 — Integration & TypstIDE

- [ ] TypstWorld package resolution via TypstUniverseKit
- [ ] AnyType end-to-end (doc -> .typ -> compile -> PDF/SVG/Image)
- [ ] TypstIDE: highlight spans, completion, tooltips, jump-to-source
- [ ] Public API docs + examples
- [ ] Final gate: all targets green, clean tree

## typst-eval (in progress)

- [x] `vm.rs` — `Vm` struct (engine/flow/scopes/inspected/context), `define`/`bind`/`traceAt`/`trace`, `hint_if_shadowed_std`, `is` keyword warning
- [x] `flow.rs` — `FlowEvent` (break/continue/return+conditional) with `forbidden()` errors
- [x] `access.rs` + `methods.rs` — `LValue` path enum (`.variable`/`.dictField`/`.methodSlot`) with read/write/mutate via `Scopes.getMut` + `Binding.write`; `access_dict` error taxonomy; `call_method_mut` (push/pop/insert/remove) + `call_method_access` slot resolution (first/last/at)
- [x] Binding guards — `NormalBindingGuard`, `Engine.bindingGuard()`, `World.silentBindingGuard()`; `Library.features` unified to upstream `Features` (replaces `FeatureGuard`)
- [x] `code.rs` — Expr.eval dispatch, literals, arrays/dicts, blocks, field access (`EvalCode.swift`)
- [x] `call.rs` — FuncCall/Args eval, closures, eval_closure, CapturesVisitor (`EvalCall.swift`; math-call path deferred to EvalMath)
- [x] `ops.rs` — unary/binary/assignment dispatch (`EvalOps.swift`)
- [x] `flow.rs` — conditionals, loops, break/continue/return (`EvalFlow.swift`)
- [x] `binding.rs` — let bindings + destructuring (`EvalBinding.swift`)
- [x] `rules.rs` — set/show rule eval (`EvalRules.swift`)
- [x] `markup.rs` — markup stream eval + leaf nodes (`EvalMarkup.swift`); list/enum/terms containers deferred to realization (upstream grouping rules)
- [x] `math.rs` eval — all math nodes + `eval_math_call`/`unparse_math_args`/`MathArgs.eval` (`EvalMath.swift`); `Scopes.getInMath` aliases `get` until the math scope lands
- [ ] `import.rs` — module import/include
- [ ] `lib.rs` — public entry points (`eval`, `eval_closure` wiring, `CapturesVisitor` IDE API)
