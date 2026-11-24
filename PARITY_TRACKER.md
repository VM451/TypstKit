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

### TypstEval — COMPLETE (all 13 upstream files ported)

- [x] vm.rs/flow.rs/access.rs/methods.rs — Vm, FlowEvent, LValue paths,
      call_method_mut, binding guards (`EvalCore.swift`)
- [x] code.rs — Expr.eval dispatch, literals, collections, field access
      (`EvalCode.swift`); `.contextual` deferred (needs ContextElem)
- [x] call.rs — FuncCall/Args eval, closures, eval_closure,
      CapturesVisitor (`EvalCall.swift`)
- [x] ops.rs — unary/binary/assignment (`EvalOps.swift`)
- [x] flow.rs — conditionals, loops, break/continue/return
      (`EvalFlow.swift`)
- [x] binding.rs — let bindings + destructuring (`EvalBinding.swift`)
- [x] rules.rs — set/show rule eval (`EvalRules.swift`)
- [x] markup.rs — markup stream + leaf nodes (`EvalMarkup.swift`);
      list/enum/terms containers deferred to realization
- [x] math.rs — all math nodes + eval_math_call/unparse_math_args/
      MathArgs.eval (`EvalMath.swift`, `Model/MathElems.swift`);
      `Scopes.getInMath` aliases `get` until math scope lands
- [x] import.rs — ModuleImport/ModuleInclude, file+package resolution,
      manifest parsing (`EvalImport.swift`)
- [x] lib.rs — evalModule/evalString, SpanMode, route file-id chain,
      flow.forbidden at entry (`EvalEntry.swift`)
- [ ] Gate: upstream tests/suite/scripting + foundations pass
      (needs realize+layout for full .typ suite; 16 EvalTests green
      covering literals/ops/bindings/flow/closures/methods/markup/
      math/imports/module-eval)

## Phase 3 — TypstRealize & TypstLayout

- [x] realize: show-rule expansion, style resolution, spaces
- [ ] layout core: Frame, Point/Size, regions, flow — payload layer done
      (Rect/Regions/Curve/Shape/Stroke/TextSize); `Frame`/`FrameItem`
      pending `TextItem` (font module) + `Image` (decode stack)
- [ ] inline: collect, shaping (CoreText), linebreak (Knuth-Plass),
      line, align, bidi
- [ ] block/flow: par, block, box, stack, pad, align, place, columns,
      hide, measure — element defs done (`Layout/Elements.swift`:
      PadElem custom `rest`/`x`/`y` parse, StackElem+StackChild,
      HideElem ghost `hidden`, PlaceElem+PlacementScope+`place.flush`
      scope, ColumnsElem+ColbreakElem, LayoutElem); layout rules pending;
      `measure` func blocked on `Frame`
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

## typst-eval — COMPLETE

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
- [x] `import.rs` — ModuleImport/ModuleInclude eval, file+package resolution, manifest parsing (`EvalImport.swift`)
- [x] `lib.rs` — `evalModule`/`evalString` entry points, `SpanMode`, route file-id chain for cycle detection, `flow.forbidden()` at entry (`EvalEntry.swift`); `.contextual` expr eval — ContextElem + context-node closure support landed

## typst-realize (in progress)

- [x] `spaces.rs` — `SpaceState`/`SpaceAction`, `collapse_spaces` in-place algorithm, `collapse_transition_textual`, `discard_space_between` via generated Unicode no-space tables (`TypstUtils/SpaceDiscarding.swift`) (`Realize/Spaces.swift`)
- [x] `lib.rs` — `realize()` entry, visit pipeline (kind rules → show rules → sequence/styled recursion → grouping → filter), `verdict()`/`prepare()`, grouping machinery (`GroupingRule`/`GroupingEffect`/finishers: textual/par/cites/list-like), regex show rules with UTF-8 byte offsets, `repack`/`select_span` (`Realize/Realize.swift`, `RealizeTypes.swift`)
- [x] `introspection/tag.rs` — `Tag`/`TagFlags`/`TagElem` (`Introspection/Tag.swift`)
- [x] `introspection/locator.rs` — `Locator`/`LocatorLink`/`SplitLocator` with `next`/`next_inner`/`next_location`; measure-mode resolution deferred via `Engine.measureLocation` hook (`Introspection/Locator.swift`)
- [x] Style-chain infra — `entries`/`links`/`recipes`/`suffix`/`trunk`/`chain`/`outside`/`pop`, identity `==`, `Styles.apply`/`applyOne`/`lazyItems` init, `NativeShowRule`/`NativeRuleMap` (`Foundations/Styles.swift`)
- [x] Elements — `ParElem`, `ListElem`/`EnumElem`/`TermsElem` (+`ListLike`/`ListItemLike`), `CiteElem`/`CiteGroup`, `HElem`/`VElem`, `PageElem`, `PagebreakElem`, `AlignElem`, `BoxElem`, `InlineElem`/`InlineItem`, `DocumentElem`+`DocumentFormat`, capability protocols (`Synthesize`/`ShowSet`/`Mathy`/`Unlabellable` as `*Capable` Swift protocols) (`Model/RealizeElems.swift`)
- [x] Engine wiring — `Routines.realize` default impl, `Engine.delay`, `Route.increase/decrease/checkShowDepth`, `measureLocation` hook
- [x] `DocumentInfo::populate`/`populate_locale` + `DocumentFormatOptions::populate` bodies (`RealizeTypes.swift`; `TextElem` gained `lang`/`region` fields)
- [x] Element constructors — `#[elem]`-generated `Construct` impls + hand-written `TextElem`/`PageElem`/`LinkElem` constructs, field-parse order (`parse`→custom, `variadic`→`all`, `required`→`expect`, `positional`→`find`, else `named`), item casts (`ListItem`/`EnumItem`/`TermItem` content-unpack), `list.item`/`enum.item`/`terms.item` nested scopes, global registration of model+layout elements, alignment/direction prelude values (`ltr`/`rtl`/`ttb`/`btt`, `start`/`left`/`center`/`right`/`end`/`top`/`horizon`/`bottom`) (`Model/ElementConstructs.swift`, `Foundations/Styles.swift` `setStyles` split)
- [x] Layout primitives — `Rect`, `Region`/`Regions` (backlog/last/`next`/`mayBreak`/`mayProgress`/`isFull`/`map`/iterator), `Curve`/`CurveItem`/`CloseMode` (rect/ellipse ctors, translate, exact cubic-extrema bbox, winding-number `contains`, flattened-segment `strokeContains`), `FillRule`/`Shape`/`Geometry` (analytic stroked-line + rect bboxes, kurbo-free), `DashLength`/`DashPattern<T,DT>` + named presets, generic `Stroke<T>` (`or`/`map`/`resolve`→`Stroke<Abs>`/`unwrapOr`→`FixedStroke`), `FixedStroke`, `Em`/`Length`/`Smart`/`Optional` `Resolve` impls, `TextSize` (fold = linear-function multiply, resolve→`Abs`) + `TextElem.size` field + `StyleChain.textSize()` folded accessor (`Layout/{Rect,Regions}.swift`, `Visualize/{Shape,Curve}.swift`, `Visualize.swift`, `Text/TextSize.swift`, `Layout/Scalars.swift`)
- [x] Layout element defs — `PadElem` (custom `rest`→`x`/`y`→sides `#[parse]` chain), `StackElem`/`StackChild` (variadic spacing|block), `HideElem` (`hidden` ghost field), `PlaceElem`/`PlacementScope` (positional `alignment`, `place.flush` nested scope), `ColumnsElem`/`ColbreakElem` (`NonZeroUsize` count now public), `LayoutElem` (`func` field); all registered globally. Gotcha: construct must parse fields in declaration order — `expect`/`find` for `body` runs LAST or it eats earlier positionals (`Layout/Elements.swift`, `Tests/…/LayoutElementTests.swift`)
- [ ] `measure` func — needs `Routines.layout_frame` + `Frame` (blocked)
- [ ] kurbo-equivalent geometry: stroked-curve bbox is approximated (segment bboxes + half thickness); `strokeContains` uses min-distance ≤ half thickness (caps/joins/dashes not applied); port kurbo subset or platform equivalent when export lands
- [ ] `Frame`/`FrameItem`/`GroupItem`/`TextItem`/`Glyph`/`Linkage`/`Image` — blocked on font module (`Font`/`FontInstance`, needs TTF parsing strategy: CoreText vs ttf-parser port) and image decode stack (raster/svg/pdf)
- [ ] `DashPattern`/`DashLength`/`Stroke` value casts (dict/array/preset-string forms) — land with stroke element port
- [ ] `#[parse]`-custom settable fields beyond `AlignElem.alignment` (positional `find` via `ElementInfo.setImpl`; more needed as layout elements land)
- [ ] `#[fold]` fields — `Fold`/`getFolded`/`Alignment.fold`/`TextSize.fold` exist; only `textSize` resolves via a dedicated folded accessor (`StyleChain.textSizeValue`); general fold wiring still pending
- [ ] `HtmlElem` whitespace-collapsing branch in space transitions (needs HTML export)
- [ ] Native show rules registration for built-in elements (bibliography, outline, etc.)
- [ ] Measure-mode location resolution via `engine.introspect` (introspection milestone)
