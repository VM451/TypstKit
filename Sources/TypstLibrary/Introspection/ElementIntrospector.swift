import Foundation
import TypstSyntax
import TypstUtils

/// Serves inquiries for pieces of information from the compilation output.
///
/// Port of the `Introspector` trait in `introspection/introspector.rs`.
/// Target-specific implementations (paged/HTML) land with the layout and
/// HTML export milestones; `EmptyIntrospector` covers the no-introspection
/// case.
public protocol Introspector: Sendable {
    /// Queries for all matching elements.
    func query(_ selector: Selector) -> [Content]
    /// Queries for the first element that matches the selector.
    func queryFirst(_ selector: Selector) -> Content?
    /// Queries for a unique element matching the selector.
    func queryUnique(_ selector: Selector) -> StrResult<Content>
    /// Queries for a unique element with the label.
    func queryLabel(_ label: Label) -> StrResult<Content>
    /// Queries for all elements with a label.
    func queryLabelled() -> [Content]
    /// How many elements match `selector` before `end` (inclusive).
    func queryCountBefore(_ selector: Selector, end: Location) -> Int
    /// How many times a label exists.
    func labelCount(_ label: Label) -> Int
    /// Finds a location for an element with `key` closest after `base`.
    func locator(_ key: Hash128, base: Location) -> Location?
    /// The total number of pages containing `location`.
    func pages(_ location: Location) -> Int?
    /// The page number for `location`.
    func page(_ location: Location) -> Int?
    /// The position for `location`.
    func position(_ location: Location) -> DocumentPosition?
    /// The page numbering for `location`, if any.
    func pageNumbering(_ location: Location) -> Numbering?
    /// The page supplement for `location`, if any.
    func pageSupplement(_ location: Location) -> Content?
    /// The HTML anchor for `location`.
    func anchor(_ location: Location) -> String?
    /// The location of the document containing `location`.
    func document(_ location: Location) -> Location?
    /// The file path of the document/asset containing `location`.
    func path(_ location: Location) -> VirtualPath?
}

/// An introspector that returns empty results for all inquiries.
///
/// Port of `EmptyIntrospector`.
public struct EmptyIntrospector: Introspector {
    public init() {}

    public func query(_ selector: Selector) -> [Content] { [] }
    public func queryFirst(_ selector: Selector) -> Content? { nil }
    public func queryUnique(_ selector: Selector) -> StrResult<Content> {
        .failure(StrError("selector does not match any element"))
    }
    public func queryLabel(_ label: Label) -> StrResult<Content> {
        .failure(StrError("label \(label.repr()) does not exist in the document"))
    }
    public func queryLabelled() -> [Content] { [] }
    public func queryCountBefore(_ selector: Selector, end: Location) -> Int { 0 }
    public func labelCount(_ label: Label) -> Int { 0 }
    public func locator(_ key: Hash128, base: Location) -> Location? { nil }
    public func pages(_ location: Location) -> Int? { nil }
    public func page(_ location: Location) -> Int? { nil }
    public func position(_ location: Location) -> DocumentPosition? { nil }
    public func pageNumbering(_ location: Location) -> Numbering? { nil }
    public func pageSupplement(_ location: Location) -> Content? { nil }
    public func anchor(_ location: Location) -> String? { nil }
    public func document(_ location: Location) -> Location? { nil }
    public func path(_ location: Location) -> VirtualPath? { nil }
}

/// An underlying target-agnostic introspector used for most queries.
///
/// Port of `ElementIntrospector<P>`.
public struct ElementIntrospector<P: Sendable>: Sendable {
    /// All introspectable elements paired with their positions.
    var elems: [(Content, P)] = []
    /// Element locations keyed by their `End` tag hash (measurement).
    var keys = MultiMap<Hash128, Location>()
    /// Location → index range covering element + descendants.
    var locations: [Location: Range<Int>] = [:]
    /// Label → element indices.
    var labels = MultiMap<Label, Int>()
    /// Query result cache keyed by selector hash.
    var queries = QueryCache()

    public init() {}

    /// Queries for all matching elements (cached by selector hash).
    public func query(_ selector: Selector) -> [Content] {
        let hash = hash128(selector)
        if let cached = queries.get(hash) { return cached }

        let output: [Content]
        switch selector {
        case .elem:
            output = all().filter { selector.matches($0) }
        case let .location(location):
            output = getByLoc(location).map { [$0] } ?? []
        case let .label(label):
            output = labels.get(label).map { getByIdx($0) }
        case let .or(selectors):
            var set = Set<Int>()
            for sel in selectors {
                for elem in query(sel) { set.insert(elemIndex(elem)) }
            }
            output = set.sorted().map { getByIdx($0) }
        case let .and(selectors):
            var results = selectors.map { query($0) }
            guard let smallest = results.indices.min(by: {
                results[$0].count < results[$1].count
            }) else { output = []; break }
            let candidate = results.remove(at: smallest)
            output = candidate.filter { elem in
                results.allSatisfy {
                    binarySearch($0, elem).isFound
                }
            }
        case let .before(selector, end, inclusive):
            var list = query(selector)
            if let end = queryFirst(end) {
                let split: Int
                switch binarySearch(list, end) {
                case let .found(i): split = i + (inclusive ? 1 : 0)
                case let .missing(i): split = i
                }
                list = Array(list[..<split])
            }
            output = list
        case let .after(selector, start, inclusive):
            var list = query(selector)
            if let start = queryFirst(start) {
                let split: Int
                switch binarySearch(list, start) {
                case let .found(i): split = i + (inclusive ? 0 : 1)
                case let .missing(i): split = i
                }
                list = Array(list[split...])
            }
            output = list
        case let .within(selector, ancestor):
            let list = query(selector)
            let ancestors = query(ancestor)
            var out: [Content] = []
            var visited = 0

            // Walk the ancestors in order, collecting all elements in
            // `list` that are descendants of them. Elements in the list
            // that are descendants of multiple ancestors are yielded only
            // once by virtue of `visited`.
            for ancestor in ancestors {
                guard let loc = ancestor.location else { continue }
                let range = locRange(loc)

                // First list element at/after the ancestor's start index.
                // If an element starts exactly at `range.lowerBound`, it is
                // the ancestor itself — `within` is not inclusive.
                let startInList: Int
                switch binarySearchBy(list, range.lowerBound, {
                    elemIndex($0)
                }) {
                case .found(let i): startInList = i + 1
                case .missing(let i): startInList = i
                }

                // First list element whose range ends after the ancestor's
                // end index.
                let endInList: Int
                switch binarySearchBy(list, range.upperBound, {
                    elemRangeEnd($0)
                }) {
                case .found(let i): endInList = i + 1
                case .missing(let i): endInList = i
                }

                // An ancestor fully contained in a single list element
                // excludes it from both ends.
                if endInList < startInList { continue }

                let lo = max(startInList, visited)
                let hi = max(endInList, visited)
                out.append(contentsOf: list[lo..<hi])
                visited = hi
            }
            output = out
        case .can, .regex:
            output = []
        }

        queries.insert(hash, output)
        return output
    }

    /// End index (exclusive) of the location range for `elem`.
    private func elemRangeEnd(_ elem: Content) -> Int {
        guard let loc = elem.location else { return Int.max }
        return locRange(loc).upperBound
    }

    /// Binary search over `list` by an arbitrary Int key projection.
    private func binarySearchBy(
        _ list: [Content], _ key: Int, _ projection: (Content) -> Int
    ) -> SearchIndex {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let midKey = projection(list[mid])
            if midKey == key { return .found(mid) }
            if midKey < key { lo = mid + 1 } else { hi = mid }
        }
        return .missing(lo)
    }

    /// Queries for the first element that matches the selector.
    public func queryFirst(_ selector: Selector) -> Content? {
        switch selector {
        case let .location(location):
            return getByLoc(location)
        case let .label(label):
            return labels.get(label).first.map { getByIdx($0) }
        default:
            return query(selector).first
        }
    }

    /// Queries for a unique element matching the selector.
    public func queryUnique(_ selector: Selector) -> StrResult<Content> {
        switch selector {
        case let .location(location):
            if let elem = getByLoc(location) { return .success(elem) }
            return .failure(StrError("element does not exist in the document"))
        case let .label(label):
            return queryLabel(label)
        default:
            let elems = query(selector)
            if elems.count > 1 {
                return .failure(StrError("selector matches multiple elements"))
            }
            guard let first = elems.first else {
                return .failure(StrError("selector does not match any element"))
            }
            return .success(first)
        }
    }

    /// Queries for a unique element with the label.
    public func queryLabel(_ label: Label) -> StrResult<Content> {
        let indices = labels.get(label)
        if indices.count == 1 { return .success(getByIdx(indices[0])) }
        if indices.isEmpty {
            return .failure(StrError(
                "label \(label.repr()) does not exist in the document"))
        }
        return .failure(StrError(
            "label \(label.repr()) occurs multiple times in the document"))
    }

    /// Queries for all elements with a label.
    public func queryLabelled() -> [Content] {
        all().filter { $0.label != nil }
    }

    /// How many elements match `selector` before `end` (inclusive).
    public func queryCountBefore(_ selector: Selector, end: Location) -> Int {
        let list = query(selector)
        guard let end = getByLoc(end) else { return list.count }
        switch binarySearch(list, end) {
        case let .found(i): return i + 1
        case let .missing(i): return i
        }
    }

    /// How many times a label exists.
    public func labelCount(_ label: Label) -> Int {
        labels.get(label).count
    }

    /// Finds a location for an element with `key` closest after `base`.
    public func locator(_ key: Hash128, base: Location) -> Location? {
        let baseIdx = locIndex(base)
        return keys.get(key).min { a, b in
            (locIndex(a) &- baseIdx) < (locIndex(b) &- baseIdx)
        }
    }

    /// The position of the element at `location`.
    public func position(_ location: Location) -> P? {
        locations[location].map { getPosByIdx($0.lowerBound) }
    }

    /// Iterates over all locatable elements.
    public func all() -> [Content] { elems.map(\.0) }

    /// Retrieves the element with the given index.
    public func getByIdx(_ idx: Int) -> Content { elems[idx].0 }

    /// Retrieves the position of the element with the given index.
    public func getPosByIdx(_ idx: Int) -> P { elems[idx].1 }

    /// Retrieves an element by its location.
    public func getByLoc(_ location: Location) -> Content? {
        locations[location].map { getByIdx($0.lowerBound) }
    }

    /// Binary search for `elem` among `list` by element index.
    func binarySearch(_ list: [Content], _ elem: Content) -> SearchIndex {
        let needle = elemIndex(elem)
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let midIdx = elemIndex(list[mid])
            if midIdx == needle { return .found(mid) }
            if midIdx < needle { lo = mid + 1 } else { hi = mid }
        }
        return .missing(lo)
    }

    /// The index of this element among all.
    public func elemIndex(_ elem: Content) -> Int {
        locIndex(elem.location!)
    }

    /// The index of the element with this location among all.
    public func locIndex(_ location: Location) -> Int {
        locations[location]?.lowerBound ?? Int.max
    }

    /// The range of the element with this location among all.
    public func locRange(_ location: Location) -> Range<Int> {
        locations[location] ?? (Int.max..<Int.max)
    }
}

/// Result of a binary search: found index or insertion index.
enum SearchIndex {
    case found(Int)
    case missing(Int)

    /// Whether the element was found.
    var isFound: Bool {
        if case .found = self { return true }
        return false
    }
}

/// Constructs the `ElementIntrospector`.
///
/// Port of `ElementIntrospectorBuilder<P>`.
public struct ElementIntrospectorBuilder<P: Sendable> {
    var stack: [[BuilderItem]] = []
    var sink: [BuilderItem] = []
    var seen = Set<Location>()
    var insertions = MultiMap<Location, [BuilderItem]>()
    var keys = MultiMap<Hash128, Location>()
    var locations: [Location: Range<Int>] = [:]
    var labels = MultiMap<Label, Int>()

    public init() {}

    /// An item in the builder's sink.
    enum BuilderItem {
        /// Start of an element, with its position.
        case start(Content, P)
        /// End of the element with the given location.
        case end(Location)
    }

    /// Discovers an introspectible element in a tag.
    public mutating func discoverTag(_ tag: Tag, position: P) {
        switch tag {
        case let .start(elem, flags):
            if flags.introspectable, let loc = elem.location,
               seen.insert(loc).inserted {
                sink.append(.start(elem, position))
            }
        case let .end(loc, key, flags):
            if flags.introspectable {
                keys.insert(key, loc)
                sink.append(.end(loc))
            }
        }
    }

    /// Discovers elements from another already built introspector.
    public mutating func discoverElements<Q: Sendable>(
        _ elements: ElementIntrospector<Q>,
        mapPosition: (Q) -> P
    ) {
        sink.reserveCapacity(sink.count + 2 * elements.elems.count)
        var queued = MultiMap<Int, Location>()
        for (i, pair) in elements.elems.enumerated() {
            let (elem, q) = pair
            guard let loc = elem.location else { continue }
            if seen.insert(loc).inserted {
                let range = elements.locations[loc]!
                sink.append(.start(elem, mapPosition(q)))
                queued.insert(range.upperBound, loc)
            }
            for end in queued.get(i + 1).reversed() {
                sink.append(.end(end))
            }
        }
        keys.extend(elements.keys)
    }

    /// Future content until a matching `endInsertion` is ordering-wise
    /// treated as belonging to the `parent`.
    public mutating func startInsertion() {
        stack.append(sink)
        sink = []
    }

    /// Closes an insertion group started by `startInsertion`.
    public mutating func endInsertion(parent: Location) {
        let elems = sink
        sink = stack.popLast()!
        insertions.insert(parent, elems)
    }

    /// Builds a complete introspector with all acceleration structures.
    public mutating func finalize() -> ElementIntrospector<P> {
        locations.reserveCapacity(seen.count)

        var elems: [(Content, P)] = []
        elems.reserveCapacity(seen.count)
        for item in sink {
            visit(&elems, item)
        }
        sink = []

        var result = ElementIntrospector<P>()
        result.elems = elems
        result.keys = keys
        result.locations = locations
        result.labels = labels
        result.queries = QueryCache()
        return result
    }

    /// Saves a pair and all its descendants into `elems`.
    private mutating func visit(_ elems: inout [(Content, P)], _ item: BuilderItem) {
        switch item {
        case let .start(elem, pos):
            guard let loc = elem.location else { return }
            let idx = elems.count
            locations[loc] = idx..<(idx + 1)
            if let label = elem.label {
                labels.insert(label, idx)
            }
            elems.append((elem, pos))
            if let groups = insertions.take(loc) {
                for group in groups {
                    for pair in group {
                        visit(&elems, pair)
                    }
                }
            }
        case let .end(loc):
            if let range = locations[loc] {
                locations[loc] = range.lowerBound..<elems.count
            }
        }
    }
}

/// A map from keys to multiple values.
///
/// Port of the private `MultiMap` in `introspector.rs`.
struct MultiMap<K: Hashable & Sendable, V: Sendable>: Sendable {
    var map: [K: [V]] = [:]

    func get(_ key: K) -> [V] { map[key] ?? [] }

    mutating func insert(_ key: K, _ value: V) {
        map[key, default: []].append(value)
    }

    mutating func take(_ key: K) -> [V]? {
        map.removeValue(forKey: key)
    }

    mutating func extend(_ other: MultiMap<K, V>) {
        for (key, values) in other.map {
            map[key, default: []].append(contentsOf: values)
        }
    }
}

/// Caches queries by selector hash.
///
/// Port of `QueryCache`; a lock-guarded class since `query` is non-mutating.
final class QueryCache: @unchecked Sendable {
    private var cache: [Hash128: [Content]] = [:]
    private let lock = NSLock()

    func get(_ hash: Hash128) -> [Content]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[hash]
    }

    func insert(_ hash: Hash128, _ output: [Content]) {
        lock.lock()
        cache[hash] = output
        lock.unlock()
    }
}
