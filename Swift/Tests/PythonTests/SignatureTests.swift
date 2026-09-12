import Testing
@testable import Python
import CPython

/// A binding's signature string is what pocketpy binds arguments against;
/// here a Python def with that signature does the same in front of the raw
/// C function. See `signatureWrapper`.
@Suite(.serialized)
@MainActor
struct SignatureTests {
    init() throws { try PyRuntime.initialize() }

    @Test func keywordsAndDefaultsReachAFunction() throws {
        let module = try #require(cpy.newmodule("signature_module"))
        module.def("greet(name: str, punctuation: str = '!') -> str", docstring: "Says hello.") { receiver, args in
            PyAPI.return {
                let arguments = PyArguments(function: receiver, args)
                let name = try String.cast(arguments, 0)
                return name + (try String.cast(arguments, 1))
            }
        }

        try PyRuntime.run("import signature_module as m")
        #expect(try PyRuntime.evaluate("m.greet('hi')") == "hi!")
        #expect(try PyRuntime.evaluate("m.greet(punctuation='?', name='why')") == "why?")
        #expect(try PyRuntime.evaluate("m.greet.__doc__") == "Says hello.")

        // The def carries the real signature, which inspect can read.
        #expect(try PyRuntime.evaluate("str(__import__('inspect').signature(m.greet))") == "(name: str, punctuation: str = '!') -> str")
    }

    /// A raw builtin keeps a clinic text signature, which inspect can only read
    /// without annotations.
    @Test func aPositionalBindingKeepsAReadableTextSignature() throws {
        let module = try #require(cpy.newmodule("clinic_module"))
        module.def("scale(value: float, factor: float) -> float") { receiver, args in
            PyAPI.return {
                let arguments = PyArguments(function: receiver, args)
                return try Double.cast(arguments, 0) * Double.cast(arguments, 1)
            }
        }

        try PyRuntime.run("import clinic_module")
        #expect(try PyRuntime.evaluate("str(__import__('inspect').signature(clinic_module.scale))") == "(value, factor, /)")
        #expect(try PyRuntime.evaluate("clinic_module.scale(2.0, 1.5)") == "3.0")
    }

    @Test func anAsyncBindingKeepsItsSignatureAndMarker() throws {
        let module = try #require(cpy.newmodule("async_signature_module"))
        let signature = "fetch(url: str, timeout: float = None) -> Response"
        module.asyncDef(signature, docstring: "Fetches a URL.") { _, _ in
            PyAPI.return { nil }
        }

        try PyRuntime.run("import async_signature_module as m")
        #expect(try PyRuntime.evaluate("str(__import__('inspect').signature(m.fetch))")
            == "(url: str, timeout: float = None) -> Response")
        #expect(try PyRuntime.evaluate("m.fetch._interface") == signature)
        #expect(try PyRuntime.evaluate("m.fetch._is_async") == "True")
        #expect(try PyRuntime.evaluate("m.fetch.__doc__") == "Fetches a URL.")
    }

    /// pocketpy hands `*args` over as one tuple; the raw function sees the same.
    @Test func starArgumentsArriveAsOneTuple() throws {
        let module = try #require(cpy.newmodule("star_module"))
        module.def("count(*items) -> int") { receiver, args in
            PyAPI.return {
                let arguments = PyArguments(function: receiver, args)
                #expect(arguments.count == 1)
                return PyTuple_Size(arguments[0])
            }
        }

        try PyRuntime.run("import star_module")
        #expect(try PyRuntime.evaluate("star_module.count(1, 2, 3)") == "3")
        #expect(try PyRuntime.evaluate("star_module.count()") == "0")
    }

    @Test func aMethodStillBindsItsReceiver() throws {
        let module = try #require(cpy.newmodule("method_module"))
        let type = try #require(cpy.newtype(name: "Box", module: module))
        type.function("fill(self, value: int = 7) -> None") { object, args in
            PyAPI.return {
                let arguments = PyArguments(method: object, args)
                object?.storeUserdata(try Int.cast(arguments, 1))
                return nil
            }
        }
        type.function("read(self) -> int") { object, _ in
            PyAPI.return { object.map { $0.toUserdata(as: Int.self) } }
        }

        try PyRuntime.run("""
        import method_module
        box = method_module.Box()
        box.fill()
        by_default = box.read()
        box.fill(value=3)
        by_keyword = box.read()
        """)
        #expect(try PyRuntime.evaluate("by_default") == "7")
        #expect(try PyRuntime.evaluate("by_keyword") == "3")
    }

    /// What a `@Scriptable` class binds: `__new__(cls, *args, **kwargs)` has
    /// to let keywords through to `__init__`.
    @Test func newAcceptsKeywordsForInit() throws {
        let module = try #require(cpy.newmodule("init_module"))
        let type = try #require(cpy.newtype(name: "Named", module: module))
        type.function("__new__(cls, *args, **kwargs)") { _, args in
            PyAPI.return {
                let cls = try #require(PyArguments(function: nil, args)[0])
                nonisolated(unsafe) let type = cls
                return cpy.newobject(type: PyType(reference: type, name: "Named"))
            }
        }
        type.function("__init__(self, name: str, loud: bool = False) -> None") { object, args in
            PyAPI.return {
                let arguments = PyArguments(method: object, args)
                let name = try String.cast(arguments, 1)
                object?.storeUserdata(try Bool.cast(arguments, 2) ? name.uppercased() : name)
                return nil
            }
        }
        type.function("name(self) -> str") { object, _ in
            PyAPI.return { object.map { $0.toUserdata(as: String.self) } }
        }

        try PyRuntime.run("""
        import init_module
        quiet = init_module.Named('ann').name()
        loud = init_module.Named(name='ann', loud=True).name()
        """)
        #expect(try PyRuntime.evaluate("quiet") == "ann")
        #expect(try PyRuntime.evaluate("loud") == "ANN")
    }
}
