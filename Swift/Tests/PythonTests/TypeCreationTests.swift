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
}
