import Testing
@testable import Python
import CPython

/// Bumped by a created type's destructor, which cannot capture anything.
private nonisolated(unsafe) var deallocations = 0

/// A named function: a C function pointer cannot be formed inside a macro.
private func countDeallocation(_ userdata: UnsafeMutableRawPointer?) {
    deallocations += 1
}

@Suite(.serialized)
@MainActor
struct TypeCreationTests {
    init() throws { try PyRuntime.initialize() }

    @Test func storesASwiftValueBehindTheObject() throws {
        let type = try #require(cpy.newtype(name: "Boxed"))
        let object = try #require(cpy.newobject(type: type))

        object.storeUserdata(42)
        #expect(object.toUserdata(as: Int.self) == 42)
    }

    @Test func pythonSeesTheTypeAndItsInstances() throws {
        let module = try #require(cpy.newmodule("type_module"))
        let type = try #require(cpy.newtype(name: "Counter", module: module))
        #expect(type.name == "Counter")

        try PyRuntime.run("""
        import type_module
        made = type_module.Counter()
        type_name = type(made).__name__
        """)
        #expect(try PyRuntime.evaluate("type_name") == "Counter")
        #expect(try PyRuntime.evaluate("type_module.Counter.__module__") == "type_module")
    }

    /// A bare spec name draws a DeprecationWarning; without a module the type
    /// reports itself as a builtin, the way pocketpy's do.
    @Test func aTypeWithoutAModuleIsABuiltin() throws {
        let type = try #require(cpy.newtype(name: "Loose"))
        #expect(type.name == "Loose")
        #expect(try PyRuntime.string(of: PyObject(type).__module__!) == "builtins")
        #expect(try PyRuntime.string(of: PyObject(type).__name__!) == "Loose")
    }

    /// The base a `@Scriptable` binding names, which is `object` unless it
    /// says otherwise.
    @Test func aTypeInheritsFromItsBase() throws {
        let module = try #require(cpy.newmodule("base_module"))
        _ = try #require(cpy.newtype(name: "Marker", module: module))
        _ = try #require(cpy.newtype(name: "Derived", base: .object, module: module))

        try PyRuntime.run("import base_module")
        #expect(try PyRuntime.evaluate("issubclass(base_module.Derived, object)") == "True")
        #expect(try PyRuntime.evaluate("issubclass(base_module.Derived, base_module.Marker)") == "False")
    }

    /// What `@Scriptable(base: .View)` needs: a Swift-made base others derive
    /// from. Base and subclass share the one userdata slot, because an object
    /// has one Swift value however deep the chain is.
    @Test func aCreatedTypeCanBeABase() throws {
        let module = try #require(cpy.newmodule("derive_module"))
        let before = deallocations

        // Formed outside the macro: #require cannot expand a C function pointer.
        let made = cpy.newtype(name: "Widget", module: module, dtor: countDeallocation)
        let base = try #require(made)
        base.function("width(self) -> int") { object, _ in
            PyAPI.return { object.map { $0.toUserdata(as: Int.self) } }
        }
        let derived = cpy.newtype(name: "Slider", base: base, module: module, dtor: countDeallocation)
        _ = try #require(derived)

        try PyRuntime.run("""
        import derive_module
        slider = derive_module.Slider()
        inherits = issubclass(derive_module.Slider, derive_module.Widget)
        """)
        #expect(try PyRuntime.evaluate("inherits") == "True")

        // The subclass stores into the slot its base declared, and the method
        // the base bound reads it back.
        var slider: Python.PyObject? = try #require(cpy.main.slider)
        slider?.storeUserdata(7)
        #expect(try PyRuntime.evaluate("slider.width()") == "7")

        // The subclass's own destructor is the one that runs, not the base's.
        slider = nil
        try PyRuntime.run("del slider")
        #expect(deallocations == before + 1)
    }

    @Test func aBoundMethodReceivesItsInstance() throws {
        let module = try #require(cpy.newmodule("method_module"))
        let type = try #require(cpy.newtype(name: "Doubler", module: module))

        type.function("doubled(self) -> int") { object, _ in
            PyAPI.return {
                guard let object else { throw PythonError.TypeError("no self") }
                return object.toUserdata(as: Int.self) * 2
            }
        }

        let object = try #require(cpy.newobject(type: type))
        object.storeUserdata(21)

        // Reached through Python, so the descriptor has to bind `self`.
        cpy.main.subject = object
        #expect(try PyRuntime.evaluate("subject.doubled()") == "42")
    }

    @Test func magicMethodsBind() throws {
        let type = try #require(cpy.newtype(name: "Described"))
        type.magic("__repr__") { object, _ in
            PyAPI.return { "<Described \(object?.toUserdata(as: Int.self) ?? 0)>" }
        }

        let object = try #require(cpy.newobject(type: type))
        object.storeUserdata(7)

        cpy.main.described = object
        #expect(try PyRuntime.evaluate("repr(described)") == "<Described 7>")
    }

    @Test func theDestructorRunsWhenTheObjectGoesAway() throws {
        // Formed outside the macro: #require's expansion cannot hold a C
        // function pointer.
        let created = cpy.newtype(name: "Disposable", dtor: countDeallocation)
        let type = try #require(created)

        let before = deallocations
        do {
            let object = try #require(cpy.newobject(type: type))
            object.storeUserdata(1)
            #expect(deallocations == before)
        }
        #expect(deallocations == before + 1)
    }

    @Test func aMethodThatThrowsRaisesInPython() throws {
        let module = try #require(cpy.newmodule("throwing_type_module"))
        let type = try #require(cpy.newtype(name: "Fails", module: module))
        type.function("boom(self)") { _, _ in
            PyAPI.return { throw PythonError.ValueError("boom") }
        }

        try PyRuntime.run("""
        import throwing_type_module
        try:
            throwing_type_module.Fails().boom()
            message = None
        except ValueError as error:
            message = str(error)
        """)
        #expect(try PyRuntime.evaluate("message") == "boom")
    }

    @Test func theDestructorRunsForAPythonSubclassToo() throws {
        let module = try #require(cpy.newmodule("subclass_module"))
        let created = cpy.newtype(name: "Base", module: module, dtor: countDeallocation)
        _ = try #require(created)

        let before = deallocations
        try PyRuntime.run("""
        import subclass_module
        class Derived(subclass_module.Base):
            pass
        derived = Derived()
        del derived
        """)
        #expect(deallocations == before + 1)
    }

    @Test func aMethodGetsATextSignatureWithSelf() throws {
        let module = try #require(cpy.newmodule("signature_type_module"))
        let type = try #require(cpy.newtype(name: "Greeter", module: module))
        type.function("greet(self, name: str) -> str", "Greets someone.") { _, _ in
            PyAPI.return { "hi" }
        }

        try PyRuntime.run("import signature_type_module as m")
        #expect(try PyRuntime.evaluate("str(__import__('inspect').signature(m.Greeter().greet))") == "(name: str) -> str")
    }
}
