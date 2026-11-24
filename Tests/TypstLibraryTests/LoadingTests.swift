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

    // MARK: - xml

    @Test func xmlStructure() throws {
        let xml = "<data><hello name=\"hi\">1</hello><hello>World</hello></data>"
        let result = try harness.unwrap(harness.call(
            xmlFunc, harness.args([bytes(xml)])))
        guard case .array(let top) = result,
              case .dict(let data) = top.items.first
        else {
            Issue.record("expected [dict], got \(result.repr())")
            return
        }
        #expect(data.get("tag") == .str(Str("data")))
        #expect(data.get("namespace") == .some(.none))
        guard case .array(let children) = data.get("children") else {
            Issue.record("expected children array")
            return
        }
        #expect(children.items.count == 2)
        guard case .dict(let hello) = children.items[0],
              case .array(let hchildren) = hello.get("children"),
              case .dict(let attrs) = hello.get("attrs")
        else {
            Issue.record("expected hello dict")
            return
        }
        #expect(hello.get("tag") == .str(Str("hello")))
        #expect(attrs.get("name") == .str(Str("hi")))
        #expect(hchildren.items == [.str(Str("1"))])
        guard case .dict(let hello2) = children.items[1],
              case .array(let h2children) = hello2.get("children")
        else { Issue.record("expected second hello"); return }
        #expect(h2children.items == [.str(Str("World"))])
    }

    @Test func xmlNamespaces() throws {
        let xml = """
            <data xmlns="http://example.org" xmlns:foo="urn:foo">
              <hello name="hi">1</hello>
              <foo:hello>World</foo:hello>
            </data>
            """
        let result = try harness.unwrap(harness.call(
            xmlFunc, harness.args([bytes(xml)])))
        guard case .array(let top) = result,
              case .dict(let data) = top.items.first,
              case .array(let children) = data.get("children")
        else {
            Issue.record("expected structure, got \(result.repr())")
            return
        }
        #expect(data.get("namespace") == .str(Str("http://example.org")))
        #expect(data.get("tag") == .str(Str("data")))
        // children: text, hello, text, foo:hello, text
        let elems = children.items.compactMap { item -> TypstLibrary.Dict? in
            guard case .dict(let d) = item else { return nil }
            return d
        }
        #expect(elems.count == 2)
        #expect(elems[0].get("namespace") == .str(Str("http://example.org")))
        #expect(elems[0].get("tag") == .str(Str("hello")))
        #expect(elems[1].get("namespace") == .str(Str("urn:foo")))
        #expect(elems[1].get("tag") == .str(Str("hello")))
    }

    @Test func xmlEntitiesAndCData() throws {
        let xml = "<r a=\"x&amp;y\"><![CDATA[<raw>&]]></r>"
        let result = try harness.unwrap(harness.call(
            xmlFunc, harness.args([bytes(xml)])))
        guard case .array(let top) = result,
              case .dict(let r) = top.items.first,
              case .array(let children) = r.get("children"),
              case .dict(let attrs) = r.get("attrs")
        else {
            Issue.record("expected structure")
            return
        }
        #expect(attrs.get("a") == .str(Str("x&y")))
        #expect(children.items == [.str(Str("<raw>&"))])
    }

    @Test func xmlRejectsMismatch() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                xmlFunc, harness.args([bytes("<a><b></a></b>")])))
        }
    }

    // MARK: - cbor

    func cborBytes(_ data: [UInt8]) -> Value {
        DataSource.bytes(Bytes(data)).intoValue()
    }

    @Test func cborDecodesScalars() throws {
        // uint 1, uint8 200, neg -1, false, true, null, float64 1.5
        let cases: [([UInt8], Value)] = [
            ([0x01], .int(1)),
            ([0x18, 0xC8], .int(200)),
            ([0x20], .int(-1)),
            ([0x38, 0x63], .int(-100)),
            ([0xF4], .bool(false)),
            ([0xF5], .bool(true)),
            ([0xF6], .none),
            ([0x60], .str(Str(""))),
            ([0x61, 0x61], .str(Str("a"))),
            ([0x40], .bytes(Bytes())),
            ([0x41, 0xFF], .bytes(Bytes([0xFF]))),
        ]
        for (data, expected) in cases {
            let result = try harness.unwrap(harness.call(
                cborFunc, harness.args([cborBytes(data)])))
            #expect(result == expected, "CBOR \(data) → \(result.repr())")
        }
    }

    @Test func cborDecodesFloat64() throws {
        // 0xFB + f64 1.5 big-endian
        var data: [UInt8] = [0xFB]
        data.append(contentsOf: 1.5.bitPattern.bigEndianBytes)
        let result = try harness.unwrap(harness.call(
            cborFunc, harness.args([cborBytes(data)])))
        #expect(result == .float(1.5))
    }

    @Test func cborDecodesContainers() throws {
        // {"a": [1, 2]} — A1 61 61 82 01 02
        let data: [UInt8] = [0xA1, 0x61, 0x61, 0x82, 0x01, 0x02]
        let result = try harness.unwrap(harness.call(
            cborFunc, harness.args([cborBytes(data)])))
        guard case .dict(let d) = result,
              case .array(let arr) = d.get("a")
        else {
            Issue.record("expected dict, got \(result.repr())")
            return
        }
        #expect(arr.items == [.int(1), .int(2)])
    }

    @Test func cborDecodesLargeUintAsFloat() throws {
        // u64 2^63 → exceeds Int64.max → float
        var data: [UInt8] = [0x1B]
        data.append(contentsOf: (UInt64(Int64.max) + 1).bigEndianBytes)
        let result = try harness.unwrap(harness.call(
            cborFunc, harness.args([cborBytes(data)])))
        #expect(result == .float(9.223372036854776e18))
    }

    @Test func cborRejectsTag() throws {
        // 0xC0 = tag 0
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                cborFunc, harness.args([cborBytes([0xC0, 0x01])])))
        }
    }

    @Test func cborRejectsNonStringKey() throws {
        // {1: "x"} — map key is int
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                cborFunc, harness.args([cborBytes([0xA1, 0x01, 0x61, 0x78])])))
        }
    }

    @Test func cborEncodeDecodeRoundtrip() throws {
        var d = Dict()
        d.insert("n", .int(42))
        d.insert("s", .str(Str("hi")))
        d.insert("arr", .array(ArrayValue(items: [.bool(true), .none])))
        let encoded = try harness.unwrap(harness.call(
            cborEncode, harness.args([.dict(d)])))
        guard case .bytes(let b) = encoded else {
            Issue.record("expected bytes")
            return
        }
        let decoded = try harness.unwrap(harness.call(
            cborFunc, harness.args([cborBytes(b.storage)])))
        #expect(decoded == .dict(d))
    }

    @Test func cborEncodeScalars() throws {
        let cases: [(Value, [UInt8])] = [
            (.int(1), [0x01]),
            (.int(-1), [0x20]),
            (.bool(true), [0xF5]),
            (.none, [0xF6]),
            (.str(Str("a")), [0x61, 0x61]),
        ]
        for (value, expected) in cases {
            let result = try harness.unwrap(harness.call(
                cborEncode, harness.args([value])))
            guard case .bytes(let b) = result else {
                Issue.record("expected bytes")
                return
            }
            #expect(b.storage == expected, "encode \(value.repr())")
        }
    }

    // MARK: - toml

    /// Field lookup on a dict value.
    func field(_ value: Value, _ key: String) -> Value {
        guard case .dict(let d) = value, let v = d.get(key) else {
            Issue.record("expected dict field \(key)")
            return .none
        }
        return v
    }

    func tomlBytes(_ s: String) -> Value {
        DataSource.bytes(Bytes(string: s)).intoValue()
    }

    @Test func tomlParsesAllTypes() throws {
        let text = """
        string = "wonderful"
        integer = 42
        float = 3.14
        boolean = true
        array = [1, "string", 3.0, false]
        inline_table = { first = "amazing", second = "greater" }
        date_time = 2023-02-01T15:38:57
        date_time2 = 2023-02-01 15:38:57
        date = 2023-02-01
        time = 15:38:57

        [table]
        element = 5
        others = [false, "indeed", 7]
        """
        let result = try harness.unwrap(harness.call(
            tomlFunc, harness.args([tomlBytes(text)])))
        #expect(field(result, "string") == .str(Str("wonderful")))
        #expect(field(result, "integer") == .int(42))
        #expect(field(result, "float") == .float(3.14))
        #expect(field(result, "boolean") == .bool(true))
        #expect(field(result, "array") == .array(ArrayValue(items: [
            .int(1), .str(Str("string")), .float(3.0), .bool(false)])))
        #expect(field(field(result, "inline_table"), "first")
            == .str(Str("amazing")))
        #expect(field(field(result, "inline_table"), "second")
            == .str(Str("greater")))
        #expect(field(field(result, "table"), "element") == .int(5))
        #expect(field(field(result, "table"), "others") == .array(
            ArrayValue(items: [.bool(false), .str(Str("indeed")), .int(7)])))
        let expectedDT = Datetime.fromYMDHMS(2023, 2, 1, 15, 38, 57)
        #expect(field(result, "date_time") == .datetime(expectedDT!))
        #expect(field(result, "date_time2") == .datetime(expectedDT!))
        #expect(field(result, "date")
            == .datetime(Datetime.fromYMD(2023, 2, 1)!))
        #expect(field(result, "time")
            == .datetime(Datetime.fromHMS(15, 38, 57)!))
    }

    @Test func tomlReadsThroughPathType() throws {
        var world = MockWorld()
        world.files[fileId("data.toml")] = Bytes(string: "key = 1")
        let (h, args) = readArgs(world, "data.toml")
        // `toml` takes a DataSource — path string resolves within main.
        let result = try h.unwrap(h.call(tomlFunc, args))
        #expect(result == .dict({
            var d = Dict(); d.insert("key", .int(1)); return d }()))
    }

    @Test func tomlRejectsInvalidSyntax() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                tomlFunc, harness.args([tomlBytes("key = [1, 2")])))
        }
    }

    @Test func tomlRejectsIntegerTooLarge() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                tomlFunc, harness.args(
                    [tomlBytes("key = 9223372036854775808")])))
        }
        // i64::MIN is representable.
        let ok = try harness.unwrap(harness.call(
            tomlFunc, harness.args(
                [tomlBytes("key = -9223372036854775808")])))
        #expect(field(ok, "key") == .int(Int64.min))
    }

    @Test func tomlEncodeDict() throws {
        var inner = Dict()
        inner.insert("b", .int(2))
        var d = Dict()
        d.insert("a", .int(1))
        d.insert("t", .dict(inner))
        let result = try harness.unwrap(harness.call(
            tomlEncode, harness.args([.dict(d)])))
        guard case .str(let s) = result else {
            Issue.record("expected str")
            return
        }
        #expect(s.value.contains("a = 1"))
        #expect(s.value.contains("[t]"))
        #expect(s.value.contains("b = 2"))
    }

    @Test func tomlEncodeRejectsNonDict() throws {
        #expect(throws: (any Error).self) {
            try harness.unwrap(harness.call(
                tomlEncode, harness.args([.int(3)])))
        }
    }

    @Test func tomlEncodeSpecialTypesAsRepr() throws {
        // Special types encode as their repr string (upstream
        // `Value::serialize` fallback).
        var d = Dict()
        d.insert("k", .auto)
        let result = try harness.unwrap(harness.call(
            tomlEncode, harness.args([.dict(d)])))
        guard case .str(let s) = result else {
            Issue.record("expected str")
            return
        }
        #expect(s.value.contains("k = \"auto\""))
    }

    @Test func tomlRoundtrip() throws {
        var d = Dict()
        d.insert("name", .str(Str("typst")))
        d.insert("count", .int(3))
        let encoded = try harness.unwrap(harness.call(
            tomlEncode, harness.args([.dict(d)])))
        guard case .str(let s) = encoded else {
            Issue.record("expected str")
            return
        }
        let decoded = try harness.unwrap(harness.call(
            tomlFunc, harness.args([tomlBytes(s.value)])))
        #expect(decoded == .dict(d))
    }

    // MARK: - yaml

    func yamlBytes(_ s: String) -> Value {
        DataSource.bytes(Bytes(string: s)).intoValue()
    }

    @Test func yamlParsesAllTypes() throws {
        let text = """
        null_key:
          - ~
          - ~
        string: text
        integer: 5
        float: 1.12
        mapping:
          "1": one
          "2": two
        seq: [1, 2, 3, 4]
        bool: false
        true: ok
        1: ok
        """
        let result = try harness.unwrap(harness.call(
            yamlFunc, harness.args([yamlBytes(text)])))
        guard case .dict(let d) = result else {
            Issue.record("expected dict")
            return
        }
        #expect(d.get("null_key") == .array(ArrayValue(items: [.none, .none])))
        #expect(d.get("string") == .str(Str("text")))
        #expect(d.get("integer") == .int(5))
        #expect(d.get("float") == .float(1.12))
        #expect(field(d.get("mapping")!, "1") == .str(Str("one")))
        #expect(field(d.get("mapping")!, "2") == .str(Str("two")))
        #expect(d.get("seq") == .array(ArrayValue(items: [
            .int(1), .int(2), .int(3), .int(4)])))
        #expect(d.get("bool") == .bool(false))
        #expect(d.get("true") == .str(Str("ok")))
        #expect(d.get("1") == .str(Str("ok")))
        #expect(d.keys.contains("true"))
    }

    @Test func yamlReadsThroughPathType() throws {
        var world = MockWorld()
        world.files[fileId("data.yaml")] = Bytes(string: "key: 1")
        let (h, args) = readArgs(world, "data.yaml")
        let result = try h.unwrap(h.call(yamlFunc, args))
        var d = Dict()
        d.insert("key", .int(1))
        #expect(result == .dict(d))
    }

    @Test func yamlDecodesLargeIntAsFloat() throws {
        // Integers beyond i64 decode as approximate floats (upstream
        // documented behavior).
        let result = try harness.unwrap(harness.call(
            yamlFunc, harness.args(
                [yamlBytes("9223372036854775808")])))
        #expect(result == .float(9.223372036854776e18))
    }

    @Test func yamlEncodesScalarsAndDict() throws {
        var d = Dict()
        d.insert("a", .int(1))
        d.insert("b", .str(Str("two words")))
        let result = try harness.unwrap(harness.call(
            yamlEncode, harness.args([.dict(d)])))
        guard case .str(let s) = result else {
            Issue.record("expected str")
            return
        }
        #expect(s.value.contains("a: 1"))
        #expect(s.value.contains("b: two words"))
    }

    @Test func yamlEncodeSpecialTypesAsRepr() throws {
        // Special types encode as repr string (upstream
        // `Value::serialize` fallback).
        let result = try harness.unwrap(harness.call(
            yamlEncode, harness.args([.auto])))
        guard case .str(let s) = result else {
            Issue.record("expected str")
            return
        }
        #expect(s.value.contains("auto"))
    }
}
