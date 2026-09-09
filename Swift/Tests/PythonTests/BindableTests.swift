import Testing
@testable import Python
import CPython

/// Counted in `deinit`, to see when Python lets a bound object go.
private nonisolated(unsafe) var livingThings = 0

@MainActor
final class Thing: PythonBindable {
    public var _pythonCache = PythonBindingCache()

    var number: Int

    init(number: Int) {
        self.number = number
        livingThings += 1
    }

    deinit { livingThings -= 1 }

    @MainActor static let pyType: PyType = .make("Thing", module: cpy.newmodule("thing_module")) { type in
        type.function("doubled(self) -> int") { object, _ in
            PyAPI.return { try Thing.cast(object).number * 2 }
        }
    }
}

@Suite(.serialized)
@MainActor
struct BindableTests {
    init() throws { try PyRuntime.initialize() }

    @Test func roundTripsThroughPython() throws {
        let thing = Thing(number: 21)
        let object = try thing.toPython()

        #expect(Thing(object.reference) === thing)
        #expect(object.typeName == "Thing")
    }

    /// The cache is what makes one Swift object one Python object. Without it
    /// each conversion makes a new wrapper, so `is` fails and anything Python
    /// put on the object is lost.
    @Test func oneSwiftObjectIsOnePythonObject() throws {
        let thing = Thing(number: 1)

        cpy.main.first = try thing.toPython()
        cpy.main.second = try thing.toPython()

        #expect(try PyRuntime.evaluate("first is second") == "True")
    }

    @Test func aBoundMethodReadsTheSwiftValue() throws {
        let thing = Thing(number: 21)
        cpy.main.doubling = try thing.toPython()

        #expect(try PyRuntime.evaluate("doubling.doubled()") == "42")
    }

    @Test func pythonKeepsTheSwiftObjectAlive() throws {
        let before = livingThings
        do {
            let thing = Thing(number: 1)
            cpy.main.held = try thing.toPython()
        }
        // Only Python holds it now.
        #expect(livingThings == before + 1)

        try PyRuntime.run("del held")
        #expect(livingThings == before)
    }

    /// An instance Python built itself carries no Swift value, so converting it
    /// has to answer nil rather than dereference nothing.
    @Test func anEmptyInstanceDoesNotConvert() throws {
        _ = Thing.pyType
        try PyRuntime.run("import thing_module; empty = thing_module.Thing()")

        let empty = try #require(cpy.main.empty)
        #expect(Thing(empty.reference) == nil)
        #expect(throws: PythonError.self) { try Thing.cast(empty.reference) }
    }
}
