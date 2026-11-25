import Foundation
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Minimal `World` for exercising foundations functions without files,
/// fonts, or packages.
struct MockWorld: World {
    let library: LazyHash<Library>
    let book: LazyHash<FontBook>
    let main: FileId
    /// In-memory files for data-loading tests, keyed by interned `FileId`.
    var files: [FileId: Bytes] = [:]
    /// In-memory source texts for import/eval tests, keyed by interned
    /// `FileId` (`Source` is not `Sendable`, so texts are stored).
    var sourceTexts: [FileId: String] = [:]

    init(files: [FileId: Bytes] = [:],
         sources: [FileId: String] = [:]) {
        let scope = Scope()
        defineFoundations(scope)
        let rules = NativeRuleMap()
        defineNativeRules(rules)
        self.library = LazyHash(Library(scope: scope, rules: rules))
        self.book = LazyHash(FontBook())
        self.main = FileId.newForTest("main.typ")
        self.files = files
        self.sourceTexts = sources
    }

    func source(_ id: FileId) -> FileResult<Source> {
        if let text = sourceTexts[id] {
            return .success(Source(id: id, text: text))
        }
        return .failure(FileError("no source", kind: .notFound))
    }

    func file(_ id: FileId) -> FileResult<Bytes> {
        if let data = files[id] { return .success(data) }
        return .failure(FileError("no file", kind: .notFound))
    }

    func font(_ index: Int) -> Font? { nil }

    /// Fixed clock matching upstream's test world: 1970-01-01 12:00 UTC.
    let clock: WorldTime = {
        // Valid by construction.
        if case let .success(t) = WorldTime.fixed(.datetime(TypstDateTime(
            date: TypstDate(year: 1970, month: 1, day: 1)!,
            time: TypstTime(hour: 12, minute: 0, second: 0)!))) {
            return t
        }
        fatalError("invalid fixed clock")
    }()

    func today(_ offset: Duration?) -> Datetime? {
        clock.today(offset)
    }
}

/// `Introspector` existential backed by `ElementIntrospector` — stands in
/// for the paged introspector until the layout milestone provides the real
/// one. Page-level queries return nil, matching `EmptyIntrospector`'s
/// shape.
struct TestIntrospector: Introspector {
    let inner: ElementIntrospector<Int>

    func query(_ selector: TypstLibrary.Selector) -> [Content] {
        inner.query(selector)
    }
    func queryFirst(_ selector: TypstLibrary.Selector) -> Content? {
        inner.queryFirst(selector)
    }
    func queryUnique(_ selector: TypstLibrary.Selector) -> StrResult<Content> {
        inner.queryUnique(selector)
    }
    func queryLabel(_ label: TypstLibrary.Label) -> StrResult<Content> {
        inner.queryLabel(label)
    }
    func queryLabelled() -> [Content] { inner.queryLabelled() }
    func queryCountBefore(_ selector: TypstLibrary.Selector,
                          end: Location) -> Int {
        inner.queryCountBefore(selector, end: end)
    }
    func labelCount(_ label: TypstLibrary.Label) -> Int {
        inner.labelCount(label)
    }
    func locator(_ key: Hash128, base: Location) -> Location? {
        inner.locator(key, base: base)
    }
    func pages(_ location: Location) -> Int? { nil }
    func page(_ location: Location) -> Int? { nil }
    func position(_ location: Location) -> DocumentPosition? { nil }
    func pageNumbering(_ location: Location) -> Numbering? { nil }
    func pageSupplement(_ location: Location) -> Content? { nil }
    func anchor(_ location: Location) -> String? { nil }
    func document(_ location: Location) -> Location? { nil }
    func path(_ location: Location) -> VirtualPath? { nil }
}

/// Shared engine/context for direct function invocation.
final class FuncHarness {
    var engine: Engine
    var context = Context()
    let world: MockWorld

    init(world: MockWorld = MockWorld()) {
        self.world = world
        engine = Engine(world: world)
    }

    /// Invoke a native function by name from the calc module (or global).
    func call(_ data: NativeFuncData, _ args: TypstLibrary.Args) -> SourceResult<Value> {
        var args = args
        return data.function(&engine, context, &args)
    }

    /// Positional args helper.
    func args(_ values: [Value]) -> TypstLibrary.Args {
        var args = TypstLibrary.Args(span: .detached)
        for value in values {
            args.push(span: .detached, value: value)
        }
        return args
    }

    /// Named arg helper.
    static func named(_ name: String, _ value: Value) -> TypstLibrary.Arg {
        Arg(span: .detached, name: Str(name), value: .detached(value))
    }

    /// Extract the value or fail the test with diagnostics.
    func unwrap(_ result: SourceResult<Value>) throws -> Value {
        try result.get()
    }
}
