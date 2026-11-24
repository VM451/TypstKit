import Foundation
import TypstSyntax
import TypstUtils

// Realization subsystem.
//
// Port of `typst-realize/src/lib.rs`. Realization is the process of
// recursively applying styling and, in particular, show rules to produce
// well-known elements that can be processed further.

/// Realize content into a flat list of well-known, styled items.
///
/// Port of `realize` in `typst-realize/src/lib.rs`.
public func realize(
    kind: RealizationKind,
    engine: inout Engine,
    locator: SplitLocator,
    arenas: Arenas = Arenas(),
    content: Content,
    styles: StyleChain
) -> SourceResult<[RealizePair]> {
    let s = RealizeState(kind: kind, engine: engine, locator: locator,
                         arenas: arenas)
    do {
        try visit(s, content, styles)
        try finish(s)
    } catch {
        return .failure(error as? SourceDiagnostics ?? SourceDiagnostics(
            SourceDiagnostic.error(Span.detached, "\(error)")))
    }
    // Write back value-semantics fields of the engine (route depth is
    // balanced; class-shared state like the sink was mutated in place).
    engine = s.engine
    return .success(s.sink)
}

/// Mutable state for realization.
///
/// Port of `State` in `typst-realize/src/lib.rs`. A class because it is
/// threaded mutably through the whole visit pipeline.
final class RealizeState {
    /// Defines what kind of realization we are performing.
    let kind: RealizationKind
    /// The engine (a copy; written back by `realize` on completion).
    var engine: Engine
    /// Assigns unique locations to elements.
    let locator: SplitLocator
    /// Temporary storage for lifetime extension during realization.
    let arenas: Arenas
    /// The output elements of well-known types.
    var sink: [RealizePair] = []
    /// Grouping rules used for realization.
    let rules: [GroupingRule]
    /// Currently active groupings.
    var groupings: [Grouping] = []
    /// Whether we are currently not within any container or show rule output.
    var outside: Bool
    /// Whether now following attach spacing can survive.
    var mayAttach = false
    /// Whether we visited any paragraph breaks.
    var sawParbreak = false

    init(kind: RealizationKind, engine: Engine, locator: SplitLocator,
         arenas: Arenas) {
        self.kind = kind
        self.engine = engine
        self.locator = locator
        self.arenas = arenas
        self.outside = kind.isDocument
        self.rules = RealizeState.rules(for: kind)
    }

    static func rules(for kind: RealizationKind) -> [GroupingRule] {
        switch kind {
        case .bundle: return []
        case .document, .fragment: return Self.flowRules
        case .par: return Self.parRules
        case .math: return Self.mathRules
        }
    }

    /// Grouping rules used in normal realization.
    static let flowRules: [GroupingRule] = [textualRule, parRule, citesRule,
                                            listRule, enumRule, termsRule]
    /// Grouping rules used in paragraph realization.
    static let parRules: [GroupingRule] = [textualRule, citesRule, listRule,
                                           enumRule, termsRule]
    /// Grouping rules used in math realization.
    static let mathRules: [GroupingRule] = [citesRule, listRule, enumRule,
                                            termsRule]
}

/// Defines a rule for how certain elements shall be grouped during realization.
///
/// Port of `GroupingRule` in `typst-realize/src/lib.rs`. A class so that rule
/// identity (`===`) can replace upstream's `std::ptr::eq`.
final class GroupingRule: @unchecked Sendable {
    /// When an element is visited that matches a rule with higher priority
    /// than one that is currently grouped, we start a nested group.
    let priority: Int
    /// Whether the grouping handles tags itself.
    let tags: Bool
    /// Defines how the element relates to this kind of grouping.
    let effect: (Content) -> GroupingEffect
    /// Defines whether styles for this kind of element interrupt the grouping.
    let interrupt: (Element) -> Bool
    /// Should convert the accumulated elements in `sink[start...]` into the
    /// grouped element.
    let finish: (RealizeState, Int) throws -> Void

    init(priority: Int, tags: Bool,
         effect: @escaping (Content) -> GroupingEffect,
         interrupt: @escaping (Element) -> Bool,
         finish: @escaping (RealizeState, Int) throws -> Void) {
        self.priority = priority
        self.tags = tags
        self.effect = effect
        self.interrupt = interrupt
        self.finish = finish
    }
}

/// Defines the effect of an element on a grouping.
///
/// Port of `GroupingEffect` in `typst-realize/src/lib.rs`.
enum GroupingEffect {
    /// The element will trigger this kind of grouping.
    case trigger
    /// May appear in the interior of the grouping, but not at the edges.
    case inner
    /// May appear intertwined with group elements without triggering
    /// finishing of the grouping.
    case neutral
    /// The element will stop this kind of grouping.
    case interrupt
}

/// A started grouping of some elements.
///
/// Port of `Grouping` in `typst-realize/src/lib.rs`.
struct Grouping {
    /// The position in `sink` where the group starts.
    var start: Int
    /// Only applies to `PAR` grouping: whether this paragraph group is
    /// interrupted, but not yet finished because it may be ignored due to
    /// being fully inline.
    var interrupted: Bool
    /// Whether the group contains neutral elements.
    var containsNeutral: Bool
    /// The rule used for this grouping.
    let rule: GroupingRule
}

/// What to do with an element when encountering it during realization.
///
/// Port of `Verdict` in `typst-realize/src/lib.rs`.
struct Verdict {
    /// Whether the element is already prepared.
    var prepared: Bool
    /// A map of styles to apply to the element.
    var map: Styles
    /// An optional show rule transformation to apply to the element.
    var step: ShowStep?
}

/// A show rule transformation to apply to the element.
///
/// Port of `ShowStep` in `typst-realize/src/lib.rs`.
enum ShowStep {
    /// A user-defined transformational show rule.
    case recipe(Recipe, RecipeIndex)
    /// The built-in show rule.
    case builtin(NativeShowRule)
}

/// A match of a regex show rule.
///
/// Port of `RegexMatch` in `typst-realize/src/lib.rs`.
struct RealizeRegexMatch {
    /// The offset in the string that matched.
    var offset: Int
    /// The text that matched.
    var text: String
    /// The style chain of the matching grouping.
    var styles: StyleChain
    /// The index of the recipe that matched.
    var id: RecipeIndex
    /// The recipe that matched.
    var recipe: Recipe
}

// MARK: - Visit pipeline

/// Handles an arbitrary piece of content during realization.
///
/// Port of `visit` in `typst-realize/src/lib.rs`.
func visit(_ s: RealizeState, _ content: Content,
           _ styles: StyleChain) throws {
    // Tags can always simply be pushed.
    if content.is(TagElem.self) {
        s.sink.append((content, styles))
        return
    }

    // Transformations for content based on the realization kind.
    if try visitKindRules(s, content, styles) { return }

    // Apply show rules and preparation.
    if try visitShowRules(s, content, styles) { return }

    // Recurse into sequences.
    if let sequence = content.packed(SequenceElem.self) {
        for elem in sequence.children {
            try visit(s, elem, styles)
        }
        return
    }

    // Recurse into styled elements.
    if let styled = content.packed(StyledElem.self) {
        try visitStyled(s, styled.child, styled.styles, styles)
        return
    }

    // Apply grouping.
    if try visitGroupingRules(s, content, styles) { return }

    // Some elements are skipped based on specific circumstances.
    if try visitFilterRules(s, content, styles) { return }

    // No further transformations to apply, so we can finally just push it.
    s.sink.append((content, styles))
}

/// Handles transformations based on the realization kind.
///
/// Port of `visit_kind_rules` in `typst-realize/src/lib.rs`.
func visitKindRules(_ s: RealizeState, _ content: Content,
                    _ styles: StyleChain) throws -> Bool {
    if case .math = s.kind {
        // Transparently recurse into equations nested in math.
        if let elem = content.packed(EquationElem.self) {
            try visit(s, elem.body, styles)
            return true
        }

        // In math, apply regex show rules on a per-element basis.
        if let elem = content.packed(SymbolElem.self) {
            if let m = findRegexMatchInStr(elem.text, styles: styles) {
                try visitRegexMatch(s, [(content, styles)], m)
                return true
            }
        } else if let elem = content.packed(TextElem.self),
                  let m = findRegexMatchInStr(elem.text.value, styles: styles) {
            try visitRegexMatch(s, [(content, styles)], m)
            return true
        }
    } else {
        // Transparently wrap mathy content into equations.
        if content.isMathy
            && !content.is(EquationElem.self) {
            let eq = Content(EquationElem(body: content)).spanned(content.span)
            try visit(s, eq, styles)
            return true
        }

        // Symbols in non-math content transparently convert to `TextElem`.
        if let elem = content.packed(SymbolElem.self) {
            var text = TextElem.packed(elem.text).spanned(elem.span)
            if let label = content.label { text.setLabel(label) }
            try visit(s, text, styles)
            return true
        }
    }

    return false
}

/// Tries to apply show rules to or prepare content.
///
/// Port of `visit_show_rules` in `typst-realize/src/lib.rs`.
func visitShowRules(_ s: RealizeState, _ content: Content,
                    _ styles: StyleChain) throws -> Bool {
    // Determines whether and how to proceed with show rule application.
    guard let verdict = try verdict(s, content, styles) else {
        return false
    }
    let prepared = verdict.prepared
    var map = verdict.map

    // Create a fresh copy that we can mutate.
    var output = content

    // If the element isn't yet prepared, prepare it.
    var tags: (Tag, Tag)?
    if !prepared {
        tags = try prepare(s, &output, &map, styles)
    } else {
        tags = nil
    }

    // Apply a show rule step, if there is one.
    if let step = verdict.step {
        let chained = styles.chain(map)
        let result: SourceResult<Content>
        switch step {
        case let .recipe(recipe, guardIndex):
            let context = Context(location: output.location, styles: chained)
            result = capture {
                try recipe.apply(
                    engine: &s.engine, context: context,
                    content: output.guarded(guardIndex))
            }

        case let .builtin(rule):
            result = rule.apply(output, &s.engine, chained)
                .map { $0.spanned(output.span) }
        }

        // Errors in show rules don't terminate compilation immediately.
        output = s.engine.delay(result)
    }

    // Push start tag.
    if let (start, _) = tags {
        try visit(s, TagElem.packed(start), styles)
    }

    let prevOutside = s.outside
    s.outside = prevOutside && content.is(ContextElem.self)
    s.engine.route.increase()
    _ = try s.engine.route.checkShowDepth().at(content.span).get()
    try visitStyled(s, output, map, styles)
    s.outside = prevOutside
    s.engine.route.decrease()

    // Push end tag.
    if let (_, end) = tags {
        try visit(s, TagElem.packed(end), styles)
    }

    return true
}

/// Inspects an element and the current styles and determines how to proceed
/// with the styling.
///
/// Port of `verdict` in `typst-realize/src/lib.rs`.
func verdict(_ s: RealizeState, _ elem: Content,
             _ styles: StyleChain) throws -> Verdict? {
    let prepared = elem.isPrepared
    var map = Styles()
    var step: ShowStep?

    // Do pre-synthesis on a cloned element to be able to match on synthesized
    // fields before real synthesis runs.
    var elem = elem
    if !prepared && elem.isSynthesizing {
        var slot = elem
        try? slot.trySynthesizeElement(engine: &s.engine, styles: styles)
        elem = slot
    }

    // Lazily computes the total number of recipes in the style chain.
    var depthCache: Int?
    func depth() -> Int {
        if let depthCache { return depthCache }
        let d = styles.recipes().count
        depthCache = d
        return d
    }

    for (r, recipe) in styles.recipes().enumerated() {
        // We're not interested in recipes that don't match.
        guard let selector = recipe.selector,
              selector.matches(elem, styles: styles) else { continue }

        // Special handling for show-set rules.
        if case let .style(transform) = recipe.transform {
            if !prepared { map.apply(transform) }
            continue
        }

        // If we already have a show step, don't look for one.
        if step != nil { continue }

        // Check whether this show rule was already applied to the element.
        let index = RecipeIndex(depth() - r)
        if elem.isGuarded(index) { continue }

        // We'll apply this recipe.
        step = .recipe(recipe, index)

        // If we found a show rule and are already prepared, there is nothing
        // else to do.
        if prepared { break }
    }

    // If we found no user-defined rule, also consider the built-in show rule.
    if step == nil {
        let target = targetFromStyles(styles)
        if let rule = s.engine.library.rules.get(target: target, content: elem) {
            step = .builtin(rule)
        }
    }

    // If there's nothing to do, there is also no verdict.
    if step == nil && map.isEmpty
        && (prepared || (elem.label == nil && elem.location == nil
            && !elem.isShowSettable
            && !elem.elem.isLocatable && !elem.elem.isTagged
            && !elem.isSynthesizing)) {
        return nil
    }

    return Verdict(prepared: prepared, map: map, step: step)
}

/// This is only executed the first time an element is visited.
///
/// Port of `prepare` in `typst-realize/src/lib.rs`.
func prepare(_ s: RealizeState, _ elem: inout Content, _ map: inout Styles,
             _ styles: StyleChain) throws -> (Tag, Tag)? {
    // Generate a location for the element.
    let key = hash128(elem)
    let flags = TagFlags(
        introspectable: elem.elem.isLocatable || elem.label != nil
            || elem.location != nil,
        tagged: elem.elem.isTagged)
    if elem.location == nil && flags.any {
        let loc = s.locator.nextLocation(&s.engine, key: key,
                                         elemSpan: elem.span)
        elem.setLocation(loc)
    }

    // Apply built-in show-set rules.
    if let showSetStyles = elem.showSetStyles(styles: styles) {
        map.apply(showSetStyles)
    }

    // If necessary, generated "synthesized" fields.
    if elem.isSynthesizing {
        let chained = styles.chain(map)
        try elem.synthesizeElement(engine: &s.engine, styles: chained)
    }

    // Copy style chain fields into the element itself.
    elem.materialize(styles.chain(map))

    // If the element is locatable, create start and end tags.
    let tags = elem.location.map { loc in
        (Tag.start(elem, flags), Tag.end(loc, key, flags))
    }

    // Ensure that this preparation only runs once.
    elem.markPrepared()

    return tags
}

/// Handles a styled element.
///
/// Port of `visit_styled` in `typst-realize/src/lib.rs`.
func visitStyled(_ s: RealizeState, _ content: Content,
                 _ localStyles: Styles, _ outer: StyleChain) throws {
    // Nothing to do if the styles are actually empty.
    if localStyles.isEmpty {
        try visit(s, content, outer)
        return
    }

    // Check for document and page styles.
    var pagebreak = false
    var populatedDocumentInfo = false
    var populatedFormatOptions = false
    let full = outer.chain(localStyles)
    for style in localStyles.iter() {
        guard let elem = style.element else { continue }
        if elem == Element(DocumentElem.self) {
            if case .document(let info, _) = s.kind {
                if !populatedDocumentInfo {
                    info.value.populate(full)
                    populatedDocumentInfo = true
                }
            } else if !s.kind.isBundle {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    style.span,
                    "document set rules are not allowed inside of containers"))
            }
            if localStyles.has(Element(DocumentElem.self), 6)
                && !s.kind.isBundle {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    style.span,
                    "setting the document format is only supported in the bundle target"))
            }
        } else if elem == Element(TextElem.self) {
            // Infer the document locale from the first toplevel set rule.
            if case .document(let info, _) = s.kind {
                info.value.populateLocale(full)
            }
        } else if elem == Element(PageElem.self) {
            switch s.kind {
            case .bundle:
                break
            case .document:
                switch targetFromStyles(outer) {
                case .paged:
                    // When there are page styles, we "break free" from our show
                    // rule cage.
                    pagebreak = true
                    s.outside = true
                case .html:
                    s.engine.sink.warn(SourceDiagnostic.warning(
                        style.span,
                        "page set rule was ignored during HTML export"))
                case .bundle:
                    break
                }
            default:
                throw SourceDiagnostics(SourceDiagnostic.error(
                    style.span,
                    "page configuration is not allowed inside of containers"))
            }
        } else if s.engine.library.formats.contains(where: { $0.elem == elem }) {
            if case .document(_, let options) = s.kind {
                if !populatedFormatOptions {
                    options.value.populate(full, span: style.span)
                    populatedFormatOptions = true
                }
            } else if !s.kind.isBundle {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    style.span,
                    "format set rules are not allowed inside of containers"))
            }
        }
    }

    // If we are not within a container or show rule, mark the styles as
    // "outside".
    var local = localStyles
    if s.outside {
        local = local.outside()
    }

    // Generate a weak pagebreak if there is a page interruption.
    if pagebreak {
        let relevant = local.entries
        // Trim trailing non-page styles.
        var kept = relevant
        while let last = kept.last,
              last.value.element != Element(PageElem.self) {
            kept.removeLast()
        }
        let trimmed = Styles(lazyItems: kept)
        try visit(s, PagebreakElem.sharedWeak, outer.chain(trimmed))
    }

    try finishInterrupted(s, local)
    try visit(s, content, outer.chain(local))
    try finishInterrupted(s, local)

    // Generate a weak "boundary" pagebreak at the end.
    if pagebreak {
        try visit(s, PagebreakElem.sharedBoundary, outer)
    }
}

/// The resolved `Target` of a style chain.
private func targetFromStyles(_ styles: StyleChain) -> Target {
    guard let value = styles.get(Element(TargetElem.self), 0),
          let target = try? Target.fromValue(value).get() else {
        return .paged
    }
    return target
}

// MARK: - Grouping rules

/// Tries to group the content in an active group or start a new one.
///
/// Port of `visit_grouping_rules` in `typst-realize/src/lib.rs`.
func visitGroupingRules(_ s: RealizeState, _ content: Content,
                        _ styles: StyleChain) throws -> Bool {
    let matching = s.rules.first { $0.effect(content) == .trigger }

    // Try to continue or finish an existing grouping.
    var i = 0
    while let active = s.groupings.last {
        // Start a nested group if a rule with higher priority matches.
        if let matching, matching.priority > active.rule.priority { break }

        // If the element can be added to the active grouping, do it.
        let effect = active.rule.effect(content)
        if !active.interrupted && effect != .interrupt {
            if case .neutral = effect {
                s.groupings[s.groupings.count - 1].containsNeutral = true
            }
            s.sink.append((content, styles))
            return true
        }

        try finishInnermostGrouping(s)
        i += 1
        if i > 512 {
            throw SourceDiagnostics(SourceDiagnostic.error(
                content.span, "maximum grouping depth exceeded"))
        }
    }

    // Start a new grouping.
    if let rule = matching {
        let start = s.sink.count
        s.groupings.append(Grouping(start: start, interrupted: false,
                                    containsNeutral: false, rule: rule))
        s.sink.append((content, styles))
        return true
    }

    return false
}

/// Some elements don't make it to the sink depending on the realization kind
/// and current state.
///
/// Port of `visit_filter_rules` in `typst-realize/src/lib.rs`.
func visitFilterRules(_ s: RealizeState, _ content: Content,
                      _ styles: StyleChain) throws -> Bool {
    if case .par = s.kind { return false }
    if case .math = s.kind { return false }

    if content.is(SpaceElem.self) {
        // Outside of maths and paragraph realization, spaces that were not
        // collected by the paragraph grouper don't interest us.
        return true
    } else if content.is(ParbreakElem.self) {
        // Paragraph breaks are only a boundary for paragraph grouping.
        s.mayAttach = false
        s.sawParbreak = true
        return true
    } else if !s.mayAttach, let v = content.packed(VElem.self), v.attach {
        // Attach spacing collapses if not immediately following a paragraph.
        return true
    }

    // Remember whether following attach spacing can survive.
    s.mayAttach = content.is(ParElem.self)

    return false
}

// MARK: - Grouping finish

/// Finishes all grouping.
///
/// Port of `finish` in `typst-realize/src/lib.rs`.
func finish(_ s: RealizeState) throws {
    try finishGroupingWhile(s) { state in
        // If this is a fragment realization and all we've got is inline and
        // neutral content, don't turn it into a paragraph.
        if isFullyInlineOrNeutral(state) {
            if case .fragment(let kind) = state.kind {
                kind.value = .inline
            }
            state.groupings.removeLast()
            collapseSpaces(&state.sink, 0)
            return false
        } else {
            return !state.groupings.isEmpty
        }
    }

    // In paragraph and math realization, spaces are top-level.
    if case .par = s.kind { collapseSpaces(&s.sink, 0) }
    if case .math = s.kind { collapseSpaces(&s.sink, 0) }
}

/// Finishes groupings while any active group is interrupted by the styles.
///
/// Port of `finish_interrupted` in `typst-realize/src/lib.rs`.
func finishInterrupted(_ s: RealizeState, _ local: Styles) throws {
    var last: Element?
    for style in local.iter() {
        guard let elem = style.element else { continue }
        if last == elem { continue }
        try finishGroupingWhile(s) { state in
            guard state.groupings.contains(where: { $0.rule.interrupt(elem) })
            else { return false }
            if isFullyInlineOrNeutral(state) {
                state.groupings[0].interrupted = true
                return false
            }
            return true
        }
        last = elem
    }
}

/// Finishes groupings while `f` returns `true`.
///
/// Port of `finish_grouping_while` in `typst-realize/src/lib.rs`.
func finishGroupingWhile(_ s: RealizeState,
                         _ f: (RealizeState) -> Bool) throws {
    var i = 0
    while f(s) {
        try finishInnermostGrouping(s)
        i += 1
        if i > 512 {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "maximum grouping depth exceeded"))
        }
    }
}

/// Finishes the currently innermost grouping.
///
/// Port of `finish_innermost_grouping` in `typst-realize/src/lib.rs`.
func finishInnermostGrouping(_ s: RealizeState) throws {
    // The grouping we are interrupting.
    let grouping = s.groupings.removeLast()
    let start = grouping.start
    let rule = grouping.rule
    let containsNeutral = grouping.containsNeutral

    if containsNeutral {
        // If the grouping collected neutral elements, we segment them out and
        // then finish the individual subgroups separately.
        let elems = Array(s.sink[start...])
        s.sink.removeLast(s.sink.count - start)

        var i = 0
        while i < elems.count {
            let neutral = rule.effect(elems[i].content) == .neutral
            var j = i + 1
            while j < elems.count,
                  (rule.effect(elems[j].content) == .neutral) == neutral {
                j += 1
            }
            let segment = Array(elems[i..<j])
            if neutral {
                for pair in segment {
                    try visit(s, pair.content, pair.styles)
                }
            } else {
                // Trim and revisit leading non-trigger elements.
                var trimmedStart = 0
                while trimmedStart < segment.count,
                      rule.effect(segment[trimmedStart].content) != .trigger {
                    trimmedStart += 1
                }
                for k in 0..<trimmedStart {
                    try visit(s, segment[k].content, segment[k].styles)
                }
                let trimmed = Array(segment[trimmedStart...])
                // If we only had inner elements and tags, don't finish.
                if !trimmed.isEmpty {
                    let newStart = s.sink.count
                    s.sink.append(contentsOf: trimmed)
                    try finishGrouping(s, rule, newStart)
                }
            }
            i = j
        }
    } else {
        try finishGrouping(s, rule, start)
    }
}

/// Finishes a grouping with the given `rule` that starts at a given position
/// in the sink.
///
/// Port of `finish_grouping` in `typst-realize/src/lib.rs`.
func finishGrouping(_ s: RealizeState, _ rule: GroupingRule,
                    _ start0: Int) throws {
    var start = start0
    // Trim trailing non-trigger elements.
    var end = s.sink.count
    while end > start,
          rule.effect(s.sink[end - 1].content) != .trigger {
        end -= 1
    }

    // Tags that are opened within or at the start boundary of the grouping
    // should have their closing tag included if it is at the end boundary.
    if rule.tags {
        // The trailing part of the sink can contain inner elements and tags.
        if rule === parRule {
            // Destruct trailing spaces eagerly.
            while end < s.sink.count,
                  s.sink[end].content.is(SpaceElem.self) {
                s.sink.remove(at: end)
            }
        }

        // Find tags before, within, and after the grouping range.
        var before = Set<LocationKey>()
        var k = start - 1
        while k >= 0, let tag = toTag(s.sink[k]) {
            before.insert(LocationKey(location: tag.location))
            k -= 1
        }
        var within = Set<LocationKey>()
        for i in start..<end {
            if let tag = toTag(s.sink[i]) {
                within.insert(LocationKey(location: tag.location))
            }
        }
        var after = Set<LocationKey>()
        var j = end
        while j < s.sink.count, let tag = toTag(s.sink[j]) {
            after.insert(LocationKey(location: tag.location))
            j += 1
        }

        // Include all tags at the start that are closed within or after.
        var newStart = start
        k = start - 1
        while k >= 0, let tag = toTag(s.sink[k]) {
            let key = LocationKey(location: tag.location)
            if within.contains(key) || after.contains(key) {
                newStart = k
            }
            k -= 1
        }
        start = newStart

        // Include all tags at the end that are opened within or before.
        var newEnd = end
        j = end
        while j < s.sink.count, let tag = toTag(s.sink[j]) {
            let key = LocationKey(location: tag.location)
            if within.contains(key) || before.contains(key) {
                newEnd = j + 1
            }
            j += 1
        }
        end = newEnd
    }

    // Save the tail for later revisiting.
    let tail = Array(s.sink[end...])
    s.sink.removeLast(s.sink.count - end)

    // If the grouping is not interested in tags, remove and collect them.
    var tags: [RealizePair] = []
    if !rule.tags {
        var write = start
        for i in start..<end {
            if s.sink[i].content.is(TagElem.self) {
                tags.append(s.sink[i])
                continue
            }
            if write < i { s.sink[write] = s.sink[i] }
            write += 1
        }
        s.sink.removeLast(end - write)
        end = write
    }

    // Execute the grouping's finisher rule.
    try rule.finish(s, start)

    // Visit the tags and staged elements again.
    for pair in tags + tail {
        try visit(s, pair.content, pair.styles)
    }
}

/// Tries to convert a pair to a tag.
private func toTag(_ pair: RealizePair) -> Tag? {
    pair.content.packed(TagElem.self)?.tag
}

// MARK: - Grouping rule definitions

/// Groups adjacent textual elements for text show rule application.
let textualRule = GroupingRule(
    priority: 3, tags: true,
    effect: { content in
        let elem = content.elem
        // Note that `SymbolElem` converts into `TextElem` before textual show
        // rules run.
        if elem == Element(TextElem.self)
            || elem == Element(LinebreakElem.self)
            || elem == Element(SmartQuoteElem.self) {
            return .trigger
        } else if elem == Element(SpaceElem.self) {
            return .inner
        } else {
            return .interrupt
        }
    },
    // Any kind of style interrupts this kind of grouping.
    interrupt: { _ in true },
    finish: finishTextual
)

/// Collects inline-level elements into a `ParElem`.
let parRule = GroupingRule(
    priority: 1, tags: true,
    effect: { content in
        let elem = content.elem
        if elem == Element(TextElem.self)
            || elem == Element(HElem.self)
            || elem == Element(LinebreakElem.self)
            || elem == Element(SmartQuoteElem.self)
            || elem == Element(InlineElem.self)
            || elem == Element(BoxElem.self) {
            return .trigger
        } else if elem == Element(SpaceElem.self) {
            return .inner
        } else {
            // HtmlElem grouping deferred until HTML export lands.
            return .interrupt
        }
    },
    interrupt: { elem in
        elem == Element(ParElem.self) || elem == Element(AlignElem.self)
    },
    finish: finishPar
)

/// Collects `CiteElem`s into `CiteGroup`s.
let citesRule = GroupingRule(
    priority: 2, tags: false,
    effect: { content in
        let elem = content.elem
        if elem == Element(CiteElem.self) {
            return .trigger
        } else if elem == Element(SpaceElem.self) {
            return .inner
        } else {
            return .interrupt
        }
    },
    interrupt: { elem in
        elem == Element(CiteGroup.self) || elem == Element(ParElem.self)
            || elem == Element(AlignElem.self)
    },
    finish: finishCites
)

/// Builds a `ListElem` from grouped `ListItem`s.
let listRule = makeListLikeRule(ListElem.self)
/// Builds an `EnumElem` from grouped `EnumItem`s.
let enumRule = makeListLikeRule(EnumElem.self)
/// Builds a `TermsElem` from grouped `TermItem`s.
let termsRule = makeListLikeRule(TermsElem.self)

/// Collects `ListItemLike` elements into a `ListLike` element.
///
/// Port of upstream `list_like_grouping::<T>`.
func makeListLikeRule<T: ListLike>(_ type: T.Type) -> GroupingRule {
    GroupingRule(
        priority: 2, tags: false,
        effect: { content in
            let elem = content.elem
            if elem == T.itemElement {
                return .trigger
            } else if elem == Element(SpaceElem.self)
                || elem == Element(ParbreakElem.self) {
                return .inner
            } else {
                return .interrupt
            }
        },
        interrupt: { elem in
            elem == Element(T.self) || elem == Element(AlignElem.self)
        },
        finish: { s, start in
            try finishListLike(s, T.self, start)
        }
    )
}

// MARK: - Grouping finishers

/// Processes grouped textual elements.
///
/// Port of `finish_textual` in `typst-realize/src/lib.rs`.
func finishTextual(_ s: RealizeState, _ start: Int) throws {
    // Try to find a regex match in the grouped textual elements.
    if try visitTextual(s, start) { return }

    // There was no regex match, so we need to collect the text into a
    // paragraph grouping.
    var start = start
    if inNonParGrouping(s) {
        let elems = Array(s.sink[start...])
        s.sink.removeLast(s.sink.count - start)
        try finishGroupingWhile(s) { inNonParGrouping($0) }
        start = s.sink.count
        s.sink.append(contentsOf: elems)
    }

    // Now, there are only two options:
    // 1. We are already in a paragraph group.
    // 2. There is no group at all. In this case, we create one.
    if s.groupings.isEmpty && s.rules.contains(where: { $0 === parRule }) {
        s.groupings.append(Grouping(start: start, interrupted: false,
                                    containsNeutral: false, rule: parRule))
    }
}

/// Whether there is an active grouping, but it is not a `PAR` grouping.
private func inNonParGrouping(_ s: RealizeState) -> Bool {
    guard let grouping = s.groupings.last else { return false }
    return grouping.rule !== parRule || grouping.interrupted
}

/// Whether there is exactly one active grouping, it is a `PAR` grouping, and
/// it spans the whole sink (with the exception of leading tags and neutral
/// elements).
private func isFullyInlineOrNeutral(_ s: RealizeState) -> Bool {
    if case .fragment = s.kind, !s.sawParbreak,
       s.groupings.count == 1,
       s.groupings[0].rule === parRule,
       s.sink[..<s.groupings[0].start].allSatisfy({ pair in
           pair.content.is(TagElem.self)
               || parRule.effect(pair.content) == .neutral
       }) {
        return true
    }
    return false
}

/// Builds the `ParElem` from inline-level elements.
///
/// Port of `finish_par` in `typst-realize/src/lib.rs`.
func finishPar(_ s: RealizeState, _ start: Int) throws {
    // Collapse unsupported spaces in-place.
    collapseSpaces(&s.sink, start)

    // Collect the children.
    let elems = Array(s.sink[start...])
    let span = selectSpan(elems)
    let (body, trunk) = repack(elems)

    // Create and visit the paragraph.
    s.sink.removeLast(s.sink.count - start)
    let elem = Content(ParElem(body: body)).spanned(span)
    try visit(s, elem, trunk)
}

/// Builds the `CiteGroup` from `CiteElem`s.
///
/// Port of `finish_cites` in `typst-realize/src/lib.rs`.
func finishCites(_ s: RealizeState, _ start: Int) throws {
    // Collect the children.
    let elems = Array(s.sink[start...])
    let span = selectSpan(elems)
    let trunk = elems.first?.styles ?? StyleChain()
    let children = elems.map { $0.content }

    // Create and visit the citation group.
    s.sink.removeLast(s.sink.count - start)
    let elem = Content(CiteGroup(children: children)).spanned(span)
    try visit(s, elem, trunk)
}

/// Builds the `ListLike` element from `ListItemLike` elements.
///
/// Port of `finish_list_like` in `typst-realize/src/lib.rs`.
func finishListLike<T: ListLike>(_ s: RealizeState, _ type: T.Type,
                                 _ start: Int) throws {
    // Collect the children.
    let elems = Array(s.sink[start...])
    let span = selectSpan(elems)
    let tight = !elems.contains { $0.content.is(ParbreakElem.self) }

    let itemChains = elems.compactMap { pair -> StyleChain? in
        pair.content.is(T.Item.self) ? pair.styles : nil
    }
    let trunk = StyleChain.trunk(itemChains) ?? StyleChain()
    let trunkDepth = trunk.links().count

    var children: [T.Item] = []
    for pair in elems {
        guard var item = pair.content.packed(T.Item.self) else { continue }
        let local = pair.styles.suffix(trunkDepth)
        item.applyStyles(local)
        children.append(item)
    }

    // Create and visit the list.
    s.sink.removeLast(s.sink.count - start)
    let elem = Content(T.createList(children: children, tight: tight))
        .spanned(span)
    try visit(s, elem, trunk)
}

/// Visit textual elements in `sink[start...]` and apply regex show rules.
///
/// Port of `visit_textual` in `typst-realize/src/lib.rs`.
func visitTextual(_ s: RealizeState, _ start: Int) throws -> Bool {
    let elems = Array(s.sink[start...])
    if let m = findRegexMatchInElems(s, elems) {
        collapseSpaces(&s.sink, start)
        let stored = Array(s.sink[start...])
        s.sink.removeLast(s.sink.count - start)
        try visitRegexMatch(s, stored, m)
        return true
    }
    return false
}

/// Finds the leftmost regex match for this style chain in the given textual
/// elements.
///
/// Port of `find_regex_match_in_elems` in `typst-realize/src/lib.rs`.
func findRegexMatchInElems(_ s: RealizeState,
                           _ elems: [RealizePair]) -> RealizeRegexMatch? {
    var buf = ""
    var base = 0
    var leftmost: RealizeRegexMatch?
    var current = StyleChain()
    var state = SpaceState.destructive

    for pair in elems {
        let (action, newState, text) = collapseTransitionTextual(
            state, pair.content, pair.styles)
        state = newState
        switch action {
        case .invisible, .skip: continue
        case .discard:
            if !buf.isEmpty { buf.removeLast() }
        case .keep: break
        }

        // If styles differ, we search _before_ adding the new element's text.
        if pair.styles != current && !buf.isEmpty {
            leftmost = findRegexMatchInStr(buf, styles: current)
            if leftmost != nil { break }
            base += buf.utf8.count
            buf = ""
        }

        current = pair.styles
        buf += text
    }

    if leftmost == nil {
        leftmost = findRegexMatchInStr(buf, styles: current)
    }

    if var m = leftmost {
        m.offset += base
        return m
    }
    return nil
}

/// Finds the leftmost regex match for this style chain in the given text.
///
/// Port of `find_regex_match_in_str` in `typst-realize/src/lib.rs`.
func findRegexMatchInStr(_ text: String,
                         styles: StyleChain) -> RealizeRegexMatch? {
    var r = 0
    var revoked = Set<Int>()
    var leftmost: (match: RegexMatch, id: RecipeIndex, recipe: Recipe)?

    let depth = styles.recipes().count

    for entry in styles.entries() {
        let recipe: Recipe
        switch entry.value {
        case let .recipe(rec): recipe = rec
        case .property: continue
        case let .revocation(index):
            revoked.insert(index.index)
            continue
        }
        r += 1

        guard let selector = recipe.selector,
              case let .regex(regex) = selector,
              let match = regex.firstMatch(in: text),
              !match.range.isEmpty else { continue }

        // If we already have a match that is equally or more to the left.
        if let found = leftmost,
           found.match.range.lowerBound <= match.range.lowerBound {
            continue
        }

        // Check whether the rule is already revoked.
        let index = RecipeIndex(depth - (r - 1))
        if revoked.contains(index.index) { continue }

        leftmost = (match, index, recipe)
    }

    guard let (match, id, recipe) = leftmost else { return nil }
    return RealizeRegexMatch(
        offset: match.range.lowerBound,
        text: match.text,
        styles: styles, id: id, recipe: recipe)
}

/// Visit a regular expression match and any surrounding textual elements.
///
/// Port of `visit_regex_match` in `typst-realize/src/lib.rs`.
func visitRegexMatch(_ s: RealizeState, _ elems: [RealizePair],
                     _ match: RealizeRegexMatch) throws {
    let matchStart = match.offset
    let matchEnd = match.offset + match.text.utf8.count
    let matchRange = matchStart..<matchEnd

    var cursor = 0
    var pending: RealizeRegexMatch? = match

    for pair in elems {
        let content = pair.content
        let styles = pair.styles

        // Just forward tags.
        if content.is(TagElem.self) {
            try visit(s, content, styles)
            continue
        }

        // Determine the range of the element.
        let len: Int
        if let elem = content.packed(TextElem.self) {
            len = elem.text.value.utf8.count
        } else if let elem = content.packed(SymbolElem.self) {
            len = elem.text.utf8.count
        } else {
            len = 1 // The rest are ASCII, so just one byte.
        }
        let elemStart = cursor
        let elemEnd = cursor + len
        cursor = elemEnd

        if elemEnd <= matchRange.lowerBound || matchRange.upperBound <= elemStart {
            // This element is entirely outside the matched range.
            try visit(s, content, styles)
            continue
        }

        if elemStart < matchRange.lowerBound {
            // This element's text begins before the start of the match.
            let end = matchRange.lowerBound - elemStart
            try visit(s, sliceTextual(content, 0..<end), styles)
        }

        // We visit the matched text itself when at the first element.
        if let m = pending {
            pending = nil
            assert(elemStart <= matchRange.lowerBound)

            let matchedText: Content
            if matchRange.upperBound <= elemEnd
                && (content.is(TextElem.self) || content.is(SymbolElem.self)) {
                // If the match is fully contained within one sliceable
                // element, we slice it.
                matchedText = sliceTextual(content, (matchRange.lowerBound - elemStart)..<(matchRange.upperBound - elemStart))
            } else {
                // Otherwise we create a fresh text element.
                matchedText = TextElem.packed(m.text).spanned(content.span)
            }

            // Apply the show rule and visit the show rule's output element.
            let context = Context(location: nil, styles: m.styles)
            let output = try m.recipe.apply(
                engine: &s.engine, context: context, content: matchedText)
            var revocation = Styles()
            revocation.append(.revocation(m.id))
            let chained = m.styles.chain(revocation)
            try visit(s, output, chained)
        }

        if elemEnd > matchRange.upperBound {
            // This element's text finishes after the end of the match.
            let start = matchRange.upperBound - elemStart
            try visit(s, sliceTextual(content, start..<len), styles)
        }
    }

    assert(pending == nil)
}

/// Takes a text or symbol element and returns an appropriate sliced output
/// element.
///
/// Port of `slice_textual` in `typst-realize/src/lib.rs`. The range is in
/// UTF-8 code units, matching upstream's byte-offset `SliceIndex<str>`.
func sliceTextual(_ elem: Content, _ range: Range<Int>) -> Content {
    func slice(_ string: String) -> String {
        let utf8 = string.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let end = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }

    if let packed = elem.packed(TextElem.self) {
        var copy = packed
        copy.text = Str(slice(packed.text.value))
        return Content(copy).spanned(elem.span)
    } else if let packed = elem.packed(SymbolElem.self) {
        var copy = packed
        copy.text = slice(packed.text)
        return Content(copy).spanned(elem.span)
    } else {
        fatalError("can only slice text and symbols")
    }
}

/// Finds the first non-detached span in the list.
///
/// Port of `select_span` in `typst-realize/src/lib.rs`.
func selectSpan(_ children: [RealizePair]) -> Span {
    for (content, _) in children where !content.span.isDetached {
        return content.span
    }
    return .detached
}

/// Turn realized content with styles back into owned content and a trunk
/// style chain.
///
/// Port of `repack` in `typst-realize/src/lib.rs`.
func repack(_ buf: [RealizePair]) -> (Content, StyleChain) {
    let trunk = StyleChain.trunkFromPairs(
        buf.map { ($0.content, $0.styles) }) ?? StyleChain()
    let depth = trunk.links().count

    var seq: [Content] = []
    seq.reserveCapacity(buf.count)

    // Group adjacent pairs by style chain.
    var i = 0
    while i < buf.count {
        var j = i + 1
        while j < buf.count && buf[j].styles == buf[i].styles {
            j += 1
        }
        let chain = buf[i].styles
        let group = Array(buf[i..<j])
        let suffix = chain.suffix(depth)
        if suffix.isEmpty {
            seq.append(contentsOf: group.map { $0.content })
        } else if group.count == 1 {
            seq.append(group[0].content.styledWithMap(suffix))
        } else {
            let inner = Content.sequence(group.map { $0.content })
            seq.append(inner.styledWithMap(suffix))
        }
        i = j
    }

    return (Content.sequence(seq), trunk)
}

/// Runs a throwing closure and converts the result to a `SourceResult`.
private func capture<T>(_ body: () throws -> T) -> SourceResult<T> {
    do {
        return .success(try body())
    } catch let error as SourceDiagnostics {
        return .failure(error)
    } catch {
        return .failure(SourceDiagnostics(SourceDiagnostic.error(
            Span.detached, "\(error)")))
    }
}
