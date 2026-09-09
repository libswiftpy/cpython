import Testing
@testable import Python

@Suite(.serialized)
@MainActor
struct TypeMemberTests {
    init() throws { try PyRuntime.initialize() }

    /// Both halves are ordinary `(self, args)` bindings; the descriptor's own
    /// shape is what the trampolines hide.
    @Test func aPropertyReadsAndWrites() throws {
        let module = try #require(cpy.newmodule("property_module"))
        let type = try #require(cpy.newtype(name: "Counter", module: module))

        type.property(
            "value",
            "How far it has counted.",
            getter: { object, _ in
                PyAPI.return { object.map { $0.toUserdata(as: Int.self) } }
            },
            setter: { object, args in
                PyAPI.return {
                    let arguments = PyArguments(method: object, args)
                    object?.storeUserdata(try Int.cast(arguments, 1))
                    return nil
                }
            }
        )

        try PyRuntime.run("""
        import property_module
        counter = property_module.Counter()
        counter.value = 12
        read = counter.value
        """)
        #expect(try PyRuntime.evaluate("read") == "12")
        #expect(try PyRuntime.evaluate("property_module.Counter.value.__doc__") == "How far it has counted.")
    }

    @Test func aReadOnlyPropertyRefusesAWrite() throws {
        let module = try #require(cpy.newmodule("readonly_module"))
        let type = try #require(cpy.newtype(name: "Fixed", module: module))
        type.property("value", getter: { _, _ in PyAPI.return { 3 } })

        try PyRuntime.run("import readonly_module")
        #expect(try PyRuntime.evaluate("readonly_module.Fixed().value") == "3")
        #expect(throws: PythonError.self) {
            try PyRuntime.run("readonly_module.Fixed().value = 1")
        }
    }

    /// A static method takes no receiver, whichever way it is reached.
    @Test func aStaticMethodTakesNoReceiver() throws {
        let module = try #require(cpy.newmodule("static_module"))
        let type = try #require(cpy.newtype(name: "Maths", module: module))

        type.staticmethod("double(a: int) -> int") { receiver, args in
            PyAPI.return {
                try Int.cast(PyArguments(function: receiver, args), 0) * 2
            }
        }

        try PyRuntime.run("import static_module")
        #expect(try PyRuntime.evaluate("static_module.Maths.double(21)") == "42")
        #expect(try PyRuntime.evaluate("static_module.Maths().double(4)") == "8")
    }
}
