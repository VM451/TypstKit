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
        var scope = Scope()
        defineFoundations(scope)
        self.library = LazyHash(Library(scope: scope))
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
