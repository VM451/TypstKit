import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `array` type scope and the global
/// `range` function — mirrors assertions from upstream
/// `tests/suite/foundations/array.typ`. Closure-based cases are covered
/// with native `calc` functions; eval-dependent tests (lvalue mutation,
/// spread syntax) are out of scope until the eval milestone.
@Suite struct ArrayTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func arr(_ values: Value...) -> Value { .array(ArrayValue(values)) }
    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }

    private func named(_ name: String, _ value: Value) -> TypstLibrary.Arg {
        FuncHarness.named(name, value)
    }

    /// A native `calc` function as a `Value`, for callback-method tests.
    private func calcFunc(_ name: String) -> Value {
        let binding = calcModule().scope.get(name)
        guard let binding, case .function = binding.value else {
            Issue.record("calc.\(name) missing")
            return .none
        }
        return binding.value
    }

    // MARK: constructor

    @Test func constructFromArrayLiteral() throws {
        #expect(try eval(arrayConstruct, [arr(i(1), i(2))]) == arr(i(1), i(2)))
        #expect(try eval(arrayConstruct, [arr()]) == arr())
    }

    @Test func constructFromBytes() throws {
        #expect(try eval(arrayConstruct, [.bytes(Bytes([65, 66]))])
            == arr(i(65), i(66)))
    }

    @Test func constructFromVersion() throws {
        let v = Version(components: [1, 2, 3])
        #expect(try eval(arrayConstruct, [.version(v)])
            == arr(i(1), i(2), i(3)))
    }

    @Test func constructBadType() {
        switch harness.call(arrayConstruct, harness.args([s("hello")])) {
        case .failure(let result):
            #expect(result.diagnostics.first?.message
                == "expected array, bytes, or version, found string")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: len / first / last / at

    @Test func len() throws {
        #expect(try eval(arrayLen, [arr()]) == i(0))
        #expect(try eval(arrayLen, [arr(s("A"), s("B"), s("C"))]) == i(3))
    }

    @Test func firstLast() throws {
        #expect(try eval(arrayFirst, [arr(i(1))]) == i(1))
        #expect(try eval(arrayLast, [arr(i(2))]) == i(2))
        #expect(try eval(arrayFirst, [arr(i(1), i(2), i(3))]) == i(1))
        #expect(try eval(arrayLast, [arr(i(1), i(2), i(3))]) == i(3))
        #expect(try eval(arrayFirst, [arr(i(1), i(2))],
                         named: [named("default", i(99))]) == i(1))
        #expect(try eval(arrayFirst, [arr()],
                         named: [named("default", i(99))]) == i(99))
        #expect(try eval(arrayLast, [arr(i(1), i(2))],
                         named: [named("default", i(99))]) == i(2))
        #expect(try eval(arrayLast, [arr()],
                         named: [named("default", i(99))]) == i(99))
    }

    @Test func firstEmptyError() {
        switch harness.call(arrayFirst, harness.args([arr()])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "array is empty")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func lastEmptyError() {
        switch harness.call(arrayLast, harness.args([arr()])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "array is empty")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func atPositiveNegative() throws {
        let a = arr(i(1), i(2), i(3), i(4))
        #expect(try eval(arrayAt, [a, i(0)]) == i(1))
        #expect(try eval(arrayAt, [a, i(-1)]) == i(4))
        #expect(try eval(arrayAt, [a, i(-2)]) == i(3))
        #expect(try eval(arrayAt, [a, i(-3)]) == i(2))
        #expect(try eval(arrayAt, [a, i(-4)]) == i(1))
    }

    @Test func atWithDefault() throws {
        #expect(try eval(arrayAt, [arr(i(1), i(2), i(3)), i(2)],
                         named: [named("default", i(5))]) == i(3))
        #expect(try eval(arrayAt, [arr(i(1), i(2), i(3)), i(3)],
                         named: [named("default", i(5))]) == i(5))
    }

    @Test func atOutOfBoundsError() {
        let cases: [(Int64, String)] = [
            (5, "array index out of bounds (index: 5, len: 3) and no default value was specified"),
            (-4, "array index out of bounds (index: -4, len: 3) and no default value was specified"),
        ]
        for (index, expected) in cases {
            switch harness.call(arrayAt,
                                harness.args([arr(i(1), i(2), i(3)), i(index)])) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message == expected)
            case .success:
                Issue.record("expected error for index \(index)")
            }
        }
    }

    // MARK: mutating methods (first-class call returns `none`)

    @Test func pushPopInsertRemove() throws {
        // `push`/`insert` return `none` as plain functions; the evaluator
        // writes the mutated copy back for lvalues (eval milestone).
        #expect(try eval(arrayPush, [arr(i(1), i(2)), i(3)]) == .none)
        #expect(try eval(arrayInsert, [arr(i(0), i(2)), i(1), i(1)]) == .none)
        #expect(try eval(arrayPop, [arr(i(1), i(2), i(3))]) == i(3))
        #expect(try eval(arrayRemove, [arr(i(1), i(2), i(3)), i(1)]) == i(2))
        #expect(try eval(arrayRemove, [arr(i(1), i(2), i(3)), i(3)],
                         named: [named("default", i(5))]) == i(5))
    }

    @Test func popEmptyError() {
        switch harness.call(arrayPop, harness.args([arr()])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "array is empty")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: range

    @Test func range() throws {
        func r(_ values: [Value], _ named: [TypstLibrary.Arg] = []) throws -> Value {
            try eval(arrayRange, values, named: named)
        }
        func rng(_ lo: Int64, _ hi: Int64, step: Int64 = 1,
                 inclusive: Bool = false) -> Value {
            var n = [named("step", i(step))]
            if inclusive { n.append(named("inclusive", .bool(true))) }
            return try! r([i(lo), i(hi)], n)
        }

        #expect(try eval(arrayRange, [i(4)]) == arr(i(0), i(1), i(2), i(3)))
        #expect(try eval(arrayRange, [i(1), i(4)]) == arr(i(1), i(2), i(3)))
        #expect(try eval(arrayRange, [i(-4), i(2)])
            == arr(i(-4), i(-3), i(-2), i(-1), i(0), i(1)))
        #expect(try eval(arrayRange, [i(10), i(5)]) == arr())
        #expect(try rng(0, 10, step: 3) == arr(i(0), i(3), i(6), i(9)))
        #expect(try rng(1, 4, step: 1) == arr(i(1), i(2), i(3)))
        #expect(try rng(1, 8, step: 2) == arr(i(1), i(3), i(5), i(7)))
        #expect(try rng(5, 2, step: -1) == arr(i(5), i(4), i(3)))
        #expect(try rng(10, 0, step: -3) == arr(i(10), i(7), i(4), i(1)))
        #expect(try eval(arrayRange, [i(0), i(0)],
                         named: [named("inclusive", .bool(true))]) == arr(i(0)))
        #expect(try eval(arrayRange, [i(-10), i(-8)],
                         named: [named("inclusive", .bool(true))])
            == arr(i(-10), i(-9), i(-8)))
        #expect(try eval(arrayRange, [i(-2), i(4)],
                         named: [named("inclusive", .bool(true)),
                                 named("step", i(2))])
            == arr(i(-2), i(0), i(2), i(4)))
        #expect(try eval(arrayRange, [i(5), i(2)],
                         named: [named("inclusive", .bool(true)),
                                 named("step", i(-1))])
            == arr(i(5), i(4), i(3), i(2)))
        #expect(try eval(arrayRange, [i(0), i(-2)],
                         named: [named("inclusive", .bool(true)),
                                 named("step", i(-1))])
            == arr(i(0), i(-1), i(-2)))
        // Overflow-safe boundaries (upstream `int.max`/`int.min` = Int64).
        let max = Int64.max, min = Int64.min
        #expect(try eval(arrayRange, [i(max - 2), i(max)])
            == arr(i(max - 2), i(max - 1)))
        #expect(try eval(arrayRange, [i(min + 2), i(min)],
                         named: [named("step", i(-1))])
            == arr(i(min + 2), i(-max)))
        #expect(try eval(arrayRange, [i(max - 2), i(max)],
                         named: [named("inclusive", .bool(true))])
            == arr(i(max - 2), i(max - 1), i(max)))
        #expect(try eval(arrayRange, [i(min + 2), i(min)],
                         named: [named("inclusive", .bool(true)),
                                 named("step", i(-1))])
            == arr(i(min + 2), i(-max), i(min)))
        // Stepping would overflow — loop breaks instead of trapping.
        #expect(try rng(2, 3, step: max) == arr(i(2)))
        #expect(try rng(-2, -3, step: min) == arr(i(-2)))
        #expect(try eval(arrayRange, [i(max - 1), i(max)],
                         named: [named("inclusive", .bool(true)),
                                 named("step", i(2))]) == arr(i(max - 1)))
        #expect(try eval(arrayRange, [i(min + 1), i(min)],
                         named: [named("inclusive", .bool(true)),
                                 named("step", i(-2))]) == arr(i(-max)))
    }

    @Test func rangeErrors() {
        // missing `end`
        switch harness.call(arrayRange, harness.args([])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "missing argument: end")
        case .success:
            Issue.record("expected error")
        }
        // float end
        switch harness.call(arrayRange, harness.args([i(1), .float(2.0)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "expected integer, found float")
        case .success:
            Issue.record("expected error")
        }
        // bad step type
        switch harness.call(arrayRange,
                            harness.args([i(4)]).withNamed("step", s("one"))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "expected integer, found string")
        case .success:
            Issue.record("expected error")
        }
        // zero step
        switch harness.call(arrayRange,
                            harness.args([i(10)]).withNamed("step", i(0))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "number must not be zero")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: slice / contains

    @Test func slice() throws {
        let ten = try eval(arrayRange, [i(10)])
        #expect(try eval(arraySlice, [arr(i(1), i(2), i(3), i(4)), i(2)])
            == arr(i(3), i(4)))
        #expect(try eval(arraySlice, [ten, i(2), i(6)])
            == arr(i(2), i(3), i(4), i(5)))
        #expect(try eval(arraySlice, [ten, i(4)],
                         named: [named("count", i(3))])
            == arr(i(4), i(5), i(6)))
        #expect(try eval(arraySlice, [ten, i(-5)],
                         named: [named("count", i(2))])
            == arr(i(5), i(6)))
        #expect(try eval(arraySlice, [arr(i(1), i(2), i(3)), i(-3)],
                         named: [named("count", i(3))])
            == arr(i(1), i(2), i(3)))
        #expect(try eval(arraySlice, [arr(i(1), i(2), i(3)), i(-1)],
                         named: [named("count", i(1))]) == arr(i(3)))
        #expect(try eval(arraySlice, [arr(i(1), i(2), i(3)), i(2), i(-2)])
            == arr())
        #expect(try eval(arraySlice, [arr(i(1), i(2), i(3)), i(-2), i(2)])
            == arr(i(2)))
        #expect(try eval(arraySlice, [arr(i(1), i(2), i(3)), i(-3), i(2)])
            == arr(i(1), i(2)))
    }

    @Test func sliceErrors() {
        // `end` and `count` mutually exclusive.
        switch harness.call(arraySlice, harness.args(
            [arr(i(1), i(2), i(3)), i(0), i(1)]).withNamed("count", i(2))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "`end` and `count` are mutually exclusive")
        case .success:
            Issue.record("expected error")
        }
        // count out of bounds (forward and from-back).
        for args in [
            harness.args([try! arrayRangeValue(10), i(9)]).withNamed("count", i(3)),
            harness.args([try! arrayRangeValue(10), i(-2)]).withNamed("count", i(4)),
        ] {
            switch harness.call(arraySlice, args) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message
                    == "array index out of bounds (index: 12, len: 10)")
            case .success:
                Issue.record("expected error")
            }
        }
        // negative end out of bounds.
        switch harness.call(arraySlice,
                            harness.args([arr(i(1), i(2), i(3)), i(0), i(-4)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "array index out of bounds (index: -4, len: 3)")
        case .success:
            Issue.record("expected error")
        }
    }

    private func arrayRangeValue(_ n: Int64) throws -> Value {
        try eval(arrayRange, [i(0), i(n)])
    }

    @Test func contains() throws {
        #expect(try eval(arrayContains, [arr(i(1), i(2), i(3)), i(2)]) == .bool(true))
        #expect(try eval(arrayContains, [arr(i(1), i(2), i(3)), i(5)]) == .bool(false))
        #expect(try eval(arrayContains, [arr(), i(1)]) == .bool(false))
    }

    // MARK: callback methods (native funcs stand in for closures)

    @Test func positionFindFilterMapAnyAll() throws {
        let even = calcFunc("even")
        let absF = calcFunc("abs")

        // position: first index where predicate holds.
        #expect(try eval(arrayPosition, [arr(i(1), i(3), i(4)), even]) == i(2))
        #expect(try eval(arrayPosition, [arr(i(1), i(3), i(5)), even]) == .none)

        // find: first element where predicate holds.
        #expect(try eval(arrayFind, [arr(i(1), i(3), i(4)), even]) == i(4))
        #expect(try eval(arrayFind, [arr(i(1), i(3), i(5)), even]) == .none)

        // filter.
        #expect(try eval(arrayFilter, [arr(i(1), i(2), i(3), i(4)), even])
            == arr(i(2), i(4)))
        #expect(try eval(arrayFilter, [arr(), even]) == arr())

        // map.
        #expect(try eval(arrayMap, [arr(i(-1), i(2), i(-3)), absF])
            == arr(i(1), i(2), i(3)))
        #expect(try eval(arrayMap, [arr(), absF]) == arr())

        // any / all.
        #expect(try eval(arrayAny, [arr(i(1), i(2), i(3)), even]) == .bool(true))
        #expect(try eval(arrayAny, [arr(i(1), i(3), i(5)), even]) == .bool(false))
        #expect(try eval(arrayAll, [arr(i(2), i(4), i(6)), even]) == .bool(true))
        #expect(try eval(arrayAll, [arr(i(2), i(3), i(6)), even]) == .bool(false))
        #expect(try eval(arrayAll, [arr(), even]) == .bool(true))
    }

    @Test func filterWrongReturnType() {
        // `calc.abs` returns the element, not a bool — filter must reject.
        switch harness.call(arrayFilter, harness.args(
            [arr(i(1), i(2)), calcFunc("abs")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "expected boolean, found integer")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: enumerate / zip

    @Test func enumerate() throws {
        #expect(try eval(arrayEnumerate, [arr()]) == arr())
        #expect(try eval(arrayEnumerate, [arr(s("a"), s("b"), s("c"))])
            == arr(arr(i(0), s("a")), arr(i(1), s("b")), arr(i(2), s("c"))))
        #expect(try eval(arrayEnumerate, [arr(s("a"), s("b"), s("c"))],
                         named: [named("start", i(1))])
            == arr(arr(i(1), s("a")), arr(i(2), s("b")), arr(i(3), s("c"))))
        #expect(try eval(arrayEnumerate, [arr(s("a"), s("b"), s("c"))],
                         named: [named("start", i(42))])
            == arr(arr(i(42), s("a")), arr(i(43), s("b")), arr(i(44), s("c"))))
        #expect(try eval(arrayEnumerate, [arr(s("a"), s("b"), s("c"))],
                         named: [named("start", i(-7))])
            == arr(arr(i(-7), s("a")), arr(i(-6), s("b")), arr(i(-5), s("c"))))
    }

    @Test func zip() throws {
        #expect(try eval(arrayZip, [arr(), arr()]) == arr())
        #expect(try eval(arrayZip, [arr(i(1)), arr()]) == arr())
        #expect(try eval(arrayZip, [arr(i(1)), arr(i(2))]) == arr(arr(i(1), i(2))))
        #expect(try eval(arrayZip, [arr(i(1), i(2)), arr(i(3), i(4))])
            == arr(arr(i(1), i(3)), arr(i(2), i(4))))
        #expect(try eval(arrayZip, [arr(i(1), i(2), i(3), i(4)), arr(i(5), i(6))])
            == arr(arr(i(1), i(5)), arr(i(2), i(6))))
        #expect(try eval(arrayZip, [arr(i(1), i(2), i(3)),
                                   arr(i(3), i(4), i(5)), arr(i(6), i(7), i(8))])
            == arr(arr(i(1), i(3), i(6)), arr(i(2), i(4), i(7)),
                   arr(i(3), i(5), i(8))))
        #expect(try eval(arrayZip, [arr(i(1), i(2), i(3))])
            == arr(arr(i(1)), arr(i(2)), arr(i(3))))
        // exact: mismatched lengths error; equal lengths pass.
        #expect(try eval(arrayZip, [arr(i(1), i(2)), arr(i(1), i(2), i(3))],
                         named: [named("exact", .bool(false))])
            == arr(arr(i(1), i(1)), arr(i(2), i(2))))
        switch harness.call(arrayZip, harness.args(
            [arr(i(1), i(2)), arr(i(1), i(2), i(3))]).withNamed("exact", .bool(true))) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "second array has different length (3) from first array (2)")
        case .success:
            Issue.record("expected error")
        }
        // Multi-array exact reports each mismatch without ordinals
        // (upstream: "array has different length ...").
        switch harness.call(arrayZip, harness.args(
            [arr(i(1), i(2)), arr(i(1), i(2), i(3)), arr(i(1), i(2), i(3), i(4))])
            .withNamed("exact", .bool(true))) {
        case .failure(let r):
            let messages = r.diagnostics.map { $0.message }
            #expect(messages.contains(
                "array has different length (3) from first array (2)"))
            #expect(messages.contains(
                "array has different length (4) from first array (2)"))
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: fold / sum / product / any-reduce

    @Test func sumProduct() throws {
        #expect(try eval(arraySum, [arr()],
                         named: [named("default", i(0))]) == i(0))
        #expect(try eval(arraySum, [arr()],
                         named: [named("default", arr())]) == arr())
        #expect(try eval(arraySum, [arr(i(1), i(2), i(3))]) == i(6))
        #expect(try eval(arrayProduct, [arr()],
                         named: [named("default", i(0))]) == i(0))
        #expect(try eval(arrayProduct, [arr(i(1), i(2), i(3))]) == i(6))
    }

    @Test func sumProductEmptyErrors() {
        switch harness.call(arraySum, harness.args([arr()])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "cannot calculate sum of empty array with no default")
        case .success:
            Issue.record("expected error")
        }
        switch harness.call(arrayProduct, harness.args([arr()])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "cannot calculate product of empty array with no default")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func productContent() throws {
        // `([ab], 3).product()` → `[ab] * 3` via ops — needs content values;
        // verify int product only here.
        #expect(try eval(arrayProduct, [arr(i(2), i(3), i(4))]) == i(24))
    }

    // MARK: flatten / rev / split / join / intersperse

    @Test func flattenRev() throws {
        #expect(try eval(arrayFlatten, [arr(arr(i(1), i(2)), arr(i(3)))])
            == arr(i(1), i(2), i(3)))
        #expect(try eval(arrayFlatten, [arr()]) == arr())
        #expect(try eval(arrayFlatten, [arr(i(1), arr(i(2)))])
            == arr(i(1), i(2)))
        #expect(try eval(arrayRev, [try eval(arrayRange, [i(3)])])
            == arr(i(2), i(1), i(0)))
        #expect(try eval(arrayRev, [arr()]) == arr())
    }

    @Test func split() throws {
        // `array.split(at)` splits at EVERY element equal to `at`
        // (the separator value is excluded from the output).
        #expect(try eval(arraySplit, [arr(i(1), i(2), i(3), i(2), i(4)), i(2)])
            == arr(arr(i(1)), arr(i(3)), arr(i(4))))
        #expect(try eval(arraySplit, [arr(i(1), i(2)), i(9)])
            == arr(arr(i(1), i(2))))
        #expect(try eval(arraySplit, [arr(i(2), i(2)), i(2)])
            == arr(arr(), arr(), arr()))
        #expect(try eval(arraySplit, [arr(), i(2)]) == arr(arr()))
    }

    @Test func join() throws {
        #expect(try eval(arrayJoin, [arr()]) == .none)
        #expect(try eval(arrayJoin, [arr(i(1))]) == i(1))
        #expect(try eval(arrayJoin, [arr(s("a"), s("b"), s("c"))]) == s("abc"))
        #expect(try eval(arrayJoin, [arr(s("a"), s("b"), s("c")), s(", ")])
            == s("a, b, c"))
        // Empty array yields `none` (or `default`) regardless of separator.
        #expect(try eval(arrayJoin, [arr(), s(", ")]) == .none)
        #expect(try eval(arrayJoin, [arr()],
                         named: [named("default", s("EMPTY"))]) == s("EMPTY"))
        #expect(try eval(arrayJoin, [arr(s("hello"))],
                         named: [named("default", s("EMPTY"))]) == s("hello"))
        #expect(try eval(arrayJoin, [arr(s("hello"), s("world")), s(", ")],
                         named: [named("default", s("EMPTY"))])
            == s("hello, world"))
        // `last` joins the final pair differently.
        #expect(try eval(arrayJoin,
                         [arr(s("a"), s("b"), s("c")), s(", ")],
                         named: [named("last", s(" and "))])
            == s("a, b and c"))
    }

    @Test func joinErrors() {
        // cannot join boolean with boolean
        switch harness.call(arrayJoin, harness.args([arr(.bool(true), .bool(false))])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "cannot join boolean with boolean")
        case .success:
            Issue.record("expected error")
        }
        // cannot join string with integer (separator type mismatch)
        switch harness.call(arrayJoin,
                            harness.args([arr(s("a"), s("b")), i(1)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "cannot join string with integer")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func intersperse() throws {
        #expect(try eval(arrayIntersperse, [arr(), s("a")]) == arr())
        #expect(try eval(arrayIntersperse, [arr(i(1)), s("a")]) == arr(i(1)))
        #expect(try eval(arrayIntersperse, [arr(i(1), i(2)), s("a")])
            == arr(i(1), s("a"), i(2)))
        #expect(try eval(arrayIntersperse, [arr(i(1), i(2), s("b")), s("a")])
            == arr(i(1), s("a"), i(2), s("a"), s("b")))
    }

    // MARK: chunks / windows

    @Test func chunks() throws {
        #expect(try eval(arrayChunks, [arr(), i(10)]) == arr())
        #expect(try eval(arrayChunks, [arr(i(1), i(2), i(3)), i(10)])
            == arr(arr(i(1), i(2), i(3))))
        #expect(try eval(arrayChunks,
                         [arr(i(1), i(2), i(3), i(4), i(5), i(6)), i(3)])
            == arr(arr(i(1), i(2), i(3)), arr(i(4), i(5), i(6))))
        #expect(try eval(arrayChunks,
                         [arr(i(1), i(2), i(3), i(4), i(5), i(6), i(7), i(8)), i(3)])
            == arr(arr(i(1), i(2), i(3)), arr(i(4), i(5), i(6)),
                   arr(i(7), i(8))))
        // exact: true drops the trailing partial chunk.
        #expect(try eval(arrayChunks, [arr(i(1), i(2), i(3)), i(10)],
                         named: [named("exact", .bool(true))]) == arr())
        #expect(try eval(arrayChunks,
                         [arr(i(1), i(2), i(3), i(4), i(5), i(6), i(7), i(8)), i(3)],
                         named: [named("exact", .bool(true))])
            == arr(arr(i(1), i(2), i(3)), arr(i(4), i(5), i(6))))
    }

    @Test func chunksSizeErrors() {
        for size in [i(0), i(-5)] {
            switch harness.call(arrayChunks,
                                harness.args([arr(i(1), i(2), i(3)), size])) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message == "number must be positive")
            case .success:
                Issue.record("expected error")
            }
        }
    }

    @Test func windows() throws {
        #expect(try eval(arrayWindows, [arr(), i(5)]) == arr())
        #expect(try eval(arrayWindows, [arr(i(1), i(2), i(3)), i(5)]) == arr())
        #expect(try eval(arrayWindows,
                         [arr(i(1), i(2), i(3), i(4), i(5)), i(3)])
            == arr(arr(i(1), i(2), i(3)), arr(i(2), i(3), i(4)),
                   arr(i(3), i(4), i(5))))
        #expect(try eval(arrayWindows,
                         [arr(i(1), i(2), i(3), i(4), i(5), i(6)), i(3)])
            == arr(arr(i(1), i(2), i(3)), arr(i(2), i(3), i(4)),
                   arr(i(3), i(4), i(5)), arr(i(4), i(5), i(6))))
        // window-size 1 yields singleton windows.
        #expect(try eval(arrayWindows, [arr(i(1), i(2)), i(1)])
            == arr(arr(i(1)), arr(i(2))))
    }

    @Test func windowsErrors() {
        switch harness.call(arrayWindows, harness.args([arr(i(1), i(2), i(3)), i(0)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "number must be positive")
        case .success:
            Issue.record("expected error")
        }
        switch harness.call(arrayWindows, harness.args([arr(i(1), i(2), i(3)), i(-5)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "number must be positive")
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: sorted / dedup / to_dict / reduce

    @Test func sorted() throws {
        #expect(try eval(arraySorted, [arr()]) == arr())
        #expect(try eval(arraySorted,
                         [arr(.bool(true), .bool(false))])
            == arr(.bool(false), .bool(true)))
        #expect(try eval(arraySorted, [arr(s("it"), s("the"), s("hi"), s("text"))])
            == arr(s("hi"), s("it"), s("text"), s("the")))
        #expect(try eval(arraySorted,
                         [arr(i(2), i(1), i(3), i(10), i(5), i(8), i(6), i(-7), i(2))])
            == arr(i(-7), i(1), i(2), i(2), i(3), i(5), i(6), i(8), i(10)))
    }

    @Test func sortedUncomparable() {
        // content values cannot be compared without a key/by.
        let content: Value = .content(Content(TextElem(Str("Hi"))))
        switch harness.call(arraySorted,
                            harness.args([arr(content, content)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "cannot compare content and content")
            #expect(r.diagnostics.first?.hints.map { $0.value }.contains(
                "consider choosing a `key` or defining the comparison with `by`") == true)
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func dedup() throws {
        #expect(try eval(arrayDedup, [arr()]) == arr())
        #expect(try eval(arrayDedup, [arr(i(1))]) == arr(i(1)))
        #expect(try eval(arrayDedup, [arr(i(1), i(1))]) == arr(i(1)))
        #expect(try eval(arrayDedup, [arr(i(1), i(2), i(1))]) == arr(i(1), i(2)))
        #expect(try eval(arrayDedup,
                         [arr(s("Jane"), s("John"), s("Eric"), s("John"))])
            == arr(s("Jane"), s("John"), s("Eric")))
    }

    @Test func toDict() throws {
        #expect(try eval(arrayToDict, [arr()]) == .dict(Dict()))
        #expect(try eval(arrayToDict,
                         [arr(arr(s("a"), i(1)), arr(s("b"), i(2)), arr(s("c"), i(3)))])
            == .dict(Dict([("a", i(1)), ("b", i(2)), ("c", i(3))])))
        // last wins on duplicate keys.
        #expect(try eval(arrayToDict,
                         [arr(arr(s("a"), i(1)), arr(s("b"), i(2)),
                               arr(s("c"), i(3)), arr(s("b"), i(4)))])
            == .dict(Dict([("a", i(1)), ("b", i(4)), ("c", i(3))])))
    }

    @Test func toDictErrors() {
        let cases: [(Value, String)] = [
            (arr(i(1)), "expected (str, any) pairs, found integer"),
            (arr(arr(i(1))), "expected pairs of length 2, found length 1"),
            (arr(arr(s("key"), i(1), i(2))), "expected pairs of length 2, found length 3"),
            (arr(arr(i(1), i(2))), "expected key of type string, found integer"),
            (arr(arr(.none, i(2))), "expected key of type string, found none"),
        ]
        for (input, expected) in cases {
            switch harness.call(arrayToDict, harness.args([input])) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message == expected)
            case .success:
                Issue.record("expected error for \(input)")
            }
        }
    }

    @Test func reduce() throws {
        // `reduce` uses the first element as the accumulator.
        // rem(rem(10, 4), 2) = rem(2, 2) = 0.
        #expect(try eval(arrayReduce, [arr(i(10), i(4), i(2)),
                                      calcFunc("rem")]) == i(0))
    }

    @Test func foldWithNativeFunc() throws {
        // `calc.gcd` as a 2-arg fold function: gcd(gcd(0? no—init=12, 18), 24)
        // fold(12, gcd) on (18, 24): gcd(12,18)=6, gcd(6,24)=6.
        #expect(try eval(arrayFold, [arr(i(18), i(24)), i(12),
                                     calcFunc("gcd")]) == i(6))
        // reduce without initial value uses first element as accumulator:
        // gcd(gcd(12,18),24)=6.
        #expect(try eval(arrayReduce, [arr(i(12), i(18), i(24)),
                                      calcFunc("gcd")]) == i(6))
    }
}

private extension TypstLibrary.Args {
    /// Append a named arg for test convenience.
    func withNamed(_ name: String, _ value: Value) -> TypstLibrary.Args {
        var copy = self
        copy.items.append(FuncHarness.named(name, value))
        return copy
    }
}
