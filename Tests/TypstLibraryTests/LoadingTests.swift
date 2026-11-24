import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for the data-loading milestone: `read`, `json`/`json.encode`,
/// `csv`, and the `path` type — port coverage for upstream
/// `tests/suite/loading/*`.
@Suite("Loading")
struct LoadingTests {
    let harness = FuncHarness()

    /// Intern a project-root file id, mirroring `FileId::new_for_test`.
    func fileId(_ name: String) -> FileId {
        RootedPath(root: .project, vpath: try! VirtualPath(name)).intern()
    }

    /// Append named args to an `Args`.
    func withNamed(_ args: TypstLibrary.Args,
                   _ pairs: [(String, Value)]) -> TypstLibrary.Args {
        var args = args
        for (name, value) in pairs {
            args.items.append(
                Arg(span: .detached, name: Str(name),
                    value: .detached(value)))
        }
        return args
    }

    func bytes(_ s: String) -> Value {
        DataSource.bytes(Bytes(string: s)).intoValue()
    }

    func path(_ s: String) -> Value {
        DataSource.path(.str(Str(s))).intoValue()
    }

    /// Build args for a path-taking function: positional path-or-str
    /// pushed with a span carrying `world.main`'s FileId.
    func readArgs(_ world: MockWorld, _ name: String,
                  named: [(String, Value)] = []) -> (FuncHarness, TypstLibrary.Args) {
        let h = FuncHarness(world: world)
        var args = TypstLibrary.Args(
            span: Span.fromRange(id: h.world.main, 0..<0))
        args.push(span: Span.fromRange(id: h.world.main, 0..<0),
                  value: path(name))
        for (n, v) in named {
            args.items.append(Arg(span: .detached, name: Str(n),
                                  value: .detached(v)))
        }
        return (h, args)
    }

    // MARK: - read

    @Test func readFileAsString() throws {
        var world = MockWorld()
        world.files[fileId("hello.txt")] = Bytes(string: "hello")
        let (h, args) = readArgs(world, "hello.txt")
        let result = try h.unwrap(h.call(readFunc, args))
        #expect(result == .str(Str("hello")))
    }

    @Test func readFileWithNoneEncoding() throws {
        var world = MockWorld()
        world.files[fileId("bin.dat")] = Bytes(string: "a\u{0}b")
        let (h, args) = readArgs(world, "bin.dat", named: [("encoding", .none)])
        let result = try h.unwrap(h.call(readFunc, args))
        guard case .bytes(let b) = result else {
            Issue.record("expected bytes, got \(result.repr())")
            return
        }
        #expect(b.storage == Array("a\u{0}b".utf8))
    }

    @Test func readRejectsBytes() throws {
        // Upstream `read` takes `PathOrStr`, not `DataSource` — raw bytes
        // are rejected.
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(readFunc, harness.args([bytes("x")])))
        }
    }

    @Test func readPathResolvesRelativeToMain() throws {
        var world = MockWorld()
        world.files[fileId("data.txt")] = Bytes(string: "file contents")
        let (h, args) = readArgs(world, "data.txt")
        let result = try h.unwrap(h.call(readFunc, args))
        #expect(result == .str(Str("file contents")))
    }

    @Test func readMissingFileErrors() throws {
        let (h, args) = readArgs(MockWorld(), "nope.txt")
        #expect(throws: (any Error).self) {
            try h.unwrap(h.call(readFunc, args))
        }
    }

    @Test func readDetachedSpanCannotResolve() throws {
        // Detached spans have no FileId → upstream "cannot access file
        // system from here".
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(readFunc, harness.args([path("x")])))
        }
    }

    // MARK: - json

    @Test func jsonParsesObject() throws {
        let result = try harness.unwrap(harness.call(
            jsonFunc,
            harness.args([bytes(#"{"a": 1, "b": "x", "c": [true, null]}"#)])))
        guard case .dict(let d) = result else {
            Issue.record("expected dict, got \(result.repr())")
            return
        }
        #expect(d.get("a") == .int(1))
        #expect(d.get("b") == .str(Str("x")))
        guard case .array(let arr) = d.get("c") else {
            Issue.record("expected array")
            return
        }
        #expect(arr.items == [.bool(true), .none])
    }

    @Test func jsonParsesNumbers() throws {
        let result = try harness.unwrap(harness.call(
            jsonFunc, harness.args([bytes("[1, 2.5, -3]")])))
        guard case .array(let arr) = result else {
            Issue.record("expected array")
            return
        }
        #expect(arr.items == [.int(1), .float(2.5), .int(-3)])
    }

    @Test func jsonRejectsInvalid() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                jsonFunc, harness.args([bytes("{not json")])))
        }
    }

    @Test func jsonRejectsBOM() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                jsonFunc, harness.args([bytes("\u{FEFF}{\"a\":1}")])))
        }
    }

    @Test func jsonFromPath() throws {
        let id = fileId("data.json")
        var world = MockWorld()
        world.files[id] = Bytes(string: #"{"key": "value"}"#)
        let h = FuncHarness(world: world)
        var args = TypstLibrary.Args(
            span: Span.fromRange(id: h.world.main, 0..<0))
        args.push(span: Span.fromRange(id: h.world.main, 0..<0),
                  value: path("data.json"))
        let result = try h.unwrap(h.call(jsonFunc, args))
        guard case .dict(let d) = result else {
            Issue.record("expected dict")
            return
        }
        #expect(d.get("key") == .str(Str("value")))
    }

    @Test func jsonEncodeRoundtrip() throws {
        var d = Dict()
        d.insert("a", .int(1))
        d.insert("b", .str(Str("x")))
        let result = try harness.unwrap(harness.call(
            jsonEncode, harness.args([.dict(d)])))
        guard case .str(let s) = result else {
            Issue.record("expected str")
            return
        }
        #expect(s.value.contains("\"a\": 1") || s.value.contains("\"a\":1"))
        #expect(s.value.contains("\"b\": \"x\"") || s.value.contains("\"b\":\"x\""))
    }

    @Test func jsonEncodeCompact() throws {
        let args = withNamed(harness.args([.int(42)]),
                             [("pretty", .bool(false))])
        let result = try harness.unwrap(harness.call(jsonEncode, args))
        #expect(result == .str(Str("42")))
    }

    // MARK: - csv

    @Test func csvArrayRows() throws {
        let result = try harness.unwrap(harness.call(
            csvFunc, harness.args([bytes("a,b\n1,2\n3,4")])))
        guard case .array(let rows) = result else {
            Issue.record("expected array")
            return
        }
        #expect(rows.items.count == 3)
        guard case .array(let first) = rows.items[0] else {
            Issue.record("expected row array")
            return
        }
        #expect(first.items == [.str(Str("a")), .str(Str("b"))])
    }

    @Test func csvDictRows() throws {
        let args = withNamed(harness.args([bytes("x,y\n1,2")]),
                             [("row-type", .type(Type.of(Dict.self)))])
        let result = try harness.unwrap(harness.call(csvFunc, args))
        guard case .array(let rows) = result else {
            Issue.record("expected array")
            return
        }
        #expect(rows.items.count == 1)
        guard case .dict(let row) = rows.items[0] else {
            Issue.record("expected dict row")
            return
        }
        #expect(row.get("x") == .str(Str("1")))
        #expect(row.get("y") == .str(Str("2")))
    }

    @Test func csvCustomDelimiter() throws {
        let args = withNamed(harness.args([bytes("a;b\n1;2")]),
                             [("delimiter", .str(Str(";")))])
        let result = try harness.unwrap(harness.call(csvFunc, args))
        guard case .array(let rows) = result,
              case .array(let first) = rows.items[0]
        else {
            Issue.record("expected array rows")
            return
        }
        #expect(first.items == [.str(Str("a")), .str(Str("b"))])
    }

    @Test func csvQuotedFields() throws {
        let result = try harness.unwrap(harness.call(
            csvFunc, harness.args([bytes("a,b\n\"x,1\",\"y\"\"2\"")])))
        guard case .array(let rows) = result,
              case .array(let row) = rows.items[1]
        else {
            Issue.record("expected array rows")
            return
        }
        #expect(row.items == [.str(Str("x,1")), .str(Str("y\"2"))])
    }

    @Test func csvUnequalLengthsErrors() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                csvFunc, harness.args([bytes("a,b\n1,2,3")])))
        }
    }

    // MARK: - path type

    /// Args for `path()` with a span carrying the main FileId.
    func pathCtorArgs(_ s: String) -> TypstLibrary.Args {
        var args = TypstLibrary.Args(
            span: Span.fromRange(id: harness.world.main, 0..<0))
        args.push(span: Span.fromRange(id: harness.world.main, 0..<0),
                  value: .str(Str(s)))
        return args
    }

    @Test func pathConstructorFromString() throws {
        let result = try harness.unwrap(
            harness.call(pathConstruct, pathCtorArgs("data.json")))
        guard case .dynamic(let d) = result, d.is(RootedPath.self) else {
            Issue.record("expected path dynamic, got \(result.repr())")
            return
        }
        #expect(result.repr() == "path(\"/data.json\")")
    }

    @Test func pathConstructorKeepsAbsolute() throws {
        let result = try harness.unwrap(
            harness.call(pathConstruct, pathCtorArgs("/abs/file.txt")))
        #expect(result.repr() == "path(\"/abs/file.txt\")")
    }

    @Test func pathConstructorRejectsEscape() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(
                harness.call(pathConstruct, pathCtorArgs("../escape.txt")))
        }
    }
}
