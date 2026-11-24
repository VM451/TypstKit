import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `str` type scope — mirrors assertions
/// from upstream `tests/suite/foundations/str.typ`.
@Suite struct StrTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func s(_ string: String) -> Value { .str(Str(string)) }
    private func i(_ n: Int64) -> Value { .int(n) }

    private func regex(_ pattern: String) -> Value {
        .dynamic(Dynamic(try! Regex(pattern)))
    }

    // MARK: constructor

    @Test func construct() throws {
        #expect(try eval(strConstruct, [s("hi")]) == s("hi"))
        #expect(try eval(strConstruct, [i(42)]) == s("42"))
        #expect(try eval(strConstruct, [i(255)],
                        named: [FuncHarness.named("base", i(16))]) == s("ff"))
        #expect(try eval(strConstruct, [i(10)]) == s("10"))
        #expect(try eval(strConstruct, [.float(2.5)]) == s("2.5"))
    }

    @Test func constructBadBase() {
        switch harness.call(strConstruct, {
            var a = harness.args([i(10)])
            a.items.append(FuncHarness.named("base", i(1)))
            return a
        }()) {
        case .failure(let d):
            #expect(d.diagnostics.first?.message.contains("base must be between 2 and 36") == true)
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: len / first / last / at / slice

    @Test func lenFirstLast() throws {
        #expect(try eval(strLen, [s("hello")]) == i(5))
        #expect(try eval(strLen, [s("héllo")]) == i(6)) // é is 2 bytes
        #expect(try eval(strFirst, [s("hello")]) == s("h"))
        #expect(try eval(strFirst, [s("")],
                        named: [FuncHarness.named("default", s("d"))]) == s("d"))
        #expect(try eval(strLast, [s("hello")]) == s("o"))
        #expect(try eval(strAt, [s("hello"), i(1)]) == s("e"))
        #expect(try eval(strAt, [s("hello"), i(-1)]) == s("o"))
        #expect(try eval(strAt, [s("hello"), i(99)],
                        named: [FuncHarness.named("default", s("d"))]) == s("d"))
    }

    @Test func slice() throws {
        #expect(try eval(strSlice, [s("hello"), i(1), i(4)]) == s("ell"))
        #expect(try eval(strSlice, [s("hello"), i(1)]) == s("ello"))
        #expect(try eval(strSlice, [s("hello"), i(0)],
                        named: [FuncHarness.named("count", i(2))]) == s("he"))
        #expect(try eval(strSlice, [s("hello"), i(-3)]) == s("llo"))
    }

    // MARK: clusters / codepoints / unicode

    @Test func clustersCodepoints() throws {
        #expect(try eval(strClusters, [s("a🇩🇪b")]) == .array(ArrayValue(items: [
            s("a"), s("🇩🇪"), s("b")
        ])))
        #expect(try eval(strCodepoints, [s("aé")]) == .array(ArrayValue(items: [
            s("a"), s("é")
        ])))
        #expect(try eval(strToUnicode, [s("a")]) == .int(97))
        #expect(try eval(strFromUnicode, [.int(97)]) == s("a"))
        #expect(try eval(strFromUnicode, [.int(0x1F600)]) == s("😀"))
    }

    // MARK: normalize

    @Test func normalize() throws {
        // "é" precomposed vs "e" + combining acute
        let nfd = try eval(strNormalize, [s("é")],
                           named: [FuncHarness.named("form", s("nfd"))])
        #expect(nfd == s("e\u{301}"))
        let nfc = try eval(strNormalize, [s("e\u{301}")],
                           named: [FuncHarness.named("form", s("nfc"))])
        #expect(nfc == s("é"))
    }

    // MARK: contains / starts / ends / find / position

    @Test func search() throws {
        #expect(try eval(strContains, [s("hello"), s("ell")]) == .bool(true))
        #expect(try eval(strContains, [s("hello"), s("xyz")]) == .bool(false))
        #expect(try eval(strContains, [s("abc123"), regex("\\d+")]) == .bool(true))
        #expect(try eval(strStartsWith, [s("hello"), s("he")]) == .bool(true))
        #expect(try eval(strEndsWith, [s("hello"), regex("o$")]) == .bool(true))
        #expect(try eval(strFind, [s("hello"), s("ll")]) == s("ll"))
        #expect(try eval(strFind, [s("hello"), s("xyz")]) == .none)
        #expect(try eval(strFind, [s("abc123"), regex("\\d+")]) == s("123"))
        #expect(try eval(strPosition, [s("hello"), s("ll")]) == i(2))
        #expect(try eval(strPosition, [s("abc123"), regex("\\d+")]) == i(3))
    }

    // MARK: match / matches

    @Test func matchDicts() throws {
        let m = try eval(strMatch, [s("hello"), s("ll")])
        guard case .dict(let d) = m else {
            Issue.record("expected dict, got \(m)")
            return
        }
        #expect(try d.at("text").get() == .str(Str("ll")))
        #expect(try d.at("start").get() == .int(2))
        #expect(try d.at("end").get() == .int(4))

        let all = try eval(strMatches, [s("a1b22"), regex("\\d+")])
        guard case .array(let arr) = all else {
            Issue.record("expected array")
            return
        }
        #expect(arr.items.count == 2)
    }

    // MARK: replace / trim / split / rev

    @Test func replaceTrimSplitRev() throws {
        #expect(try eval(strReplace, [s("hello"), s("l"), s("L")]) == s("heLLo"))
        #expect(try eval(strReplace, [s("hello"), s("l"), s("L")],
                        named: [FuncHarness.named("count", .int(1))]) == s("heLlo"))
        #expect(try eval(strReplace, [s("a1b2"), regex("\\d"), s("#")]) == s("a#b#"))
        #expect(try eval(strTrim, [s("  hi  ")]) == s("hi"))
        #expect(try eval(strTrim, [s("xxhixx"), s("x")]) == s("hi"))
        #expect(try eval(strSplit, [s("a,b,c"), s(",")]) ==
                .array(ArrayValue(items: [s("a"), s("b"), s("c")])))
        #expect(try eval(strSplit, [s("a1b22"), regex("\\d+")]) ==
                .array(ArrayValue(items: [s("a"), s("b"), s("")])))
        #expect(try eval(strRev, [s("abc")]) == s("cba"))
    }
}
