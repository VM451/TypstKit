import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for the `sys` module — port coverage for upstream `sys.rs`.
@Suite("Sys")
struct SysTests {
    /// Read a module binding's value directly.
    private func moduleValue(_ module: Module, _ name: String) -> Value? {
        module.scope.get(name)?.value
    }

    @Test func sysVersion() {
        let sys = sysModule(inputs: Dict())
        #expect(moduleValue(sys, "version") == .version(Version(components: [0, 15, 1])))
    }

    @Test func sysInputsEmptyByDefault() {
        let sys = sysModule(inputs: Dict())
        #expect(moduleValue(sys, "inputs") == .dict(Dict()))
    }

    @Test func sysInputsFlowThrough() {
        var inputs = Dict()
        inputs.insert("key", .str(Str("value")))
        let sys = sysModule(inputs: inputs)
        #expect(moduleValue(sys, "inputs") == .dict(inputs))
    }

    @Test func defineFoundationsRegistersSys() {
        var scope = Scope()
        defineFoundations(scope)
        guard let binding = scope.get("sys"),
              case .module(let sys) = binding.value else {
            Issue.record("sys module missing from global scope")
            return
        }
        #expect(sys.name == Str("sys"))
        #expect(moduleValue(sys, "version") != nil)
        #expect(moduleValue(sys, "inputs") == .dict(Dict()))
    }

    @Test func defineFoundationsPassesInputs() {
        var inputs = Dict()
        inputs.insert("answer", .str(Str("42")))
        var scope = Scope()
        defineFoundations(scope, inputs: inputs)
        guard let binding = scope.get("sys"),
              case .module(let sys) = binding.value else {
            Issue.record("sys module missing")
            return
        }
        #expect(moduleValue(sys, "inputs") == .dict(inputs))
    }

    @Test func libraryWithInputs() {
        var inputs = Dict()
        inputs.insert("k", .str(Str("v")))
        let library = Library(scope: Scope()).withInputs(inputs)
        #expect(library.inputs == inputs)
    }
}
