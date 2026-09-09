import Testing
@testable import Python
import CPython

@Suite(.serialized)
@MainActor
struct ModuleTests {
    init() throws { try PyRuntime.initialize() }

    @Test func importsAnExistingModule() throws {
        let sys = try #require(cpy.module("sys"))
        let version: String? = sys.version
        #expect(version?.hasPrefix(expectedVersion) == true)
    }

    @Test func missingModuleIsNilRatherThanAnError() {
        #expect(cpy.module("no_such_module_anywhere") == nil)
        // The failed import must not leave an exception set behind.
        #expect(PyErr_Occurred() == nil)
    }

    @Test func readsAndWritesAttributes() throws {
        let module = try #require(cpy.newmodule("attribute_module"))

        module.count = 7
        let count: Int? = module.count
        #expect(count == 7)

        module.name = "swiftpy"
        let name: String? = module.name
        #expect(name == "swiftpy")

        #expect(module.missing == nil)
    }

    @Test func bindsAFunctionPythonCanCall() throws {
        let module = try #require(cpy.newmodule("binding_module"))
        module.def("double_it(value: int) -> int") { _, args in
            PyAPI.return {
                guard let first = PyTuple_GetItem(args, 0) else {
                    throw PythonError.TypeError("expected one argument")
                }
                return try Int.cast(first) * 2
            }
        }

        try PyRuntime.run("""
        import binding_module
        doubled = binding_module.double_it(21)
        """)
        #expect(try PyRuntime.evaluate("doubled") == "42")
    }

    @Test func aBindingThatThrowsRaisesInPython() throws {
        let module = try #require(cpy.newmodule("raising_module"))
        module.def("always_fails()") { _, _ in
            PyAPI.return {
                throw PythonError.ValueError("no good")
            }
        }

        try PyRuntime.run("""
        import raising_module
        try:
            raising_module.always_fails()
            caught = None
        except ValueError as error:
            caught = str(error)
        """)
        #expect(try PyRuntime.evaluate("caught") == "no good")
    }

    @Test func aBindingReturningNothingGivesNone() throws {
        let module = try #require(cpy.newmodule("none_module"))
        module.def("returns_nothing()") { _, _ in
            PyAPI.return { nil }
        }

        try PyRuntime.run("""
        import none_module
        nothing = none_module.returns_nothing()
        """)
        #expect(try PyRuntime.evaluate("nothing is None") == "True")
    }

    @Test func theSignatureBecomesATextSignature() throws {
        let module = try #require(cpy.newmodule("documented_module"))
        module.def("greet(name: str) -> str", docstring: "Greets someone.") { _, _ in
            PyAPI.return { "hi" }
        }
        try PyRuntime.run("import documented_module; greet = documented_module.greet")

        // A builtin has no __dict__, so __annotations__ cannot be attached --
        // the text signature is where the types survive.
        #expect(try PyRuntime.evaluate("greet.__text_signature__")
            == "($module, name: str, /)")
        #expect(try PyRuntime.evaluate("greet.__doc__").contains("Greets someone."))
        #expect(try PyRuntime.evaluate("hasattr(greet, '__annotations__')") == "False")
    }
}
