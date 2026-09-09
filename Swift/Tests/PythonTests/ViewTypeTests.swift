import Testing
@testable import Python

@Suite(.serialized)
@MainActor
struct ViewTypeTests {
    init() throws { try PyRuntime.initialize() }

    /// The base `@Scriptable(base: .View)` names. SwiftPy puts it in builtins;
    /// here a module is enough to reach it from Python.
    private func viewModule() throws -> PyModule {
        let module = try #require(cpy.newmodule("view_module"))
        module[dynamicMember: "View"] = PyObject(retaining: PyType.View.reference)
        try PyRuntime.run("import view_module")
        return module
    }

    @Test func pythonSubclassesTheViewBase() throws {
        _ = try viewModule()
        try PyRuntime.run("""
        class Panel(view_module.View):
            def body(self):
                return 'painted'
        made = Panel().body()
        """)
        #expect(try PyRuntime.evaluate("made") == "painted")
        #expect(try PyRuntime.evaluate("isinstance(Panel(), view_module.View)") == "True")
    }

    @Test func theBaseBodyRaises() throws {
        _ = try viewModule()
        do {
            _ = try PyRuntime.evaluate("view_module.View().body()")
            Issue.record("expected a NotImplementedError")
        } catch {
            #expect(error.type == "NotImplementedError")
            #expect(error.value == "def body(self) is not implemented")
        }
    }
}
