import Testing
import Foundation
@testable import Python

@Suite(.serialized)
@MainActor
struct ConversionTests {
    init() throws { try Python.initialize() }

    /// `str()` of the object a Swift value converts to.
    private func roundTrip(_ value: some PythonConvertible) throws -> String {
        try Python.string(of: value.toPython())
    }

    @Test func convertsScalarsToPython() throws {
        #expect(try roundTrip(true) == "True")
        #expect(try roundTrip(42) == "42")
        #expect(try roundTrip(Int64(9_000_000_000)) == "9000000000")
        #expect(try roundTrip(3.5) == "3.5")
        #expect(try roundTrip(Float(0.5)) == "0.5")
        #expect(try roundTrip("héllo") == "héllo")
        #expect(try roundTrip(Data([0x68, 0x69])) == "b'hi'")
    }

    @Test func convertsScalarsBackToSwift() throws {
        func evaluate(_ expression: String) throws -> PythonObject {
            try Python.execute(PythonCompiler.compile(expression, mode: .evaluation))
        }

        #expect(Bool(try evaluate("True")) == true)
        #expect(Int(try evaluate("42")) == 42)
        #expect(Int64(try evaluate("9000000000")) == 9_000_000_000)
        #expect(Double(try evaluate("3.5")) == 3.5)
        #expect(Float(try evaluate("0.5")) == 0.5)
        #expect(String(try evaluate("'héllo'")) == "héllo")
        #expect(Data(try evaluate("b'hi'")) == Data([0x68, 0x69]))
    }

    /// `bool` subclasses `int` in Python; Swift's types do not.
    @Test func keepsBoolAndIntApart() throws {
        let yes = try true.toPython()
        #expect(Int(yes) == nil)
        #expect(Bool(yes) == true)

        let number = try 1.toPython()
        #expect(Int(number) == 1)
    }

    @Test func convertsOptionals() throws {
        let nothing: String? = nil
        #expect(try roundTrip(nothing) == "None")
        #expect(try roundTrip(String?("here")) == "here")

        let none = PythonObject.none
        #expect(String?(none) == nil)
        #expect(String?(try "here".toPython()) == "here")
    }

    /// A borrowed reference converts without wrapping it in a box first.
    @Test func convertsFromABorrowedReference() throws {
        let object = try "borrowed".toPython()
        let reference: PythonRef = object.reference

        #expect(String(reference) == "borrowed")
        #expect(try String.cast(reference) == "borrowed")
        #expect(reference.typeName == "str")
    }
}

@Suite(.serialized)
@MainActor
struct CollectionConversionTests {
    init() throws { try Python.initialize() }

    private func evaluate(_ expression: String) throws -> PythonObject {
        try Python.execute(PythonCompiler.compile(expression, mode: .evaluation))
    }

    @Test func convertsArrays() throws {
        #expect(try Python.string(of: [1, 2, 3].toPython()) == "[1, 2, 3]")
        #expect(try Python.string(of: ["a", "b"].toPython()) == "['a', 'b']")

        #expect([Int](try evaluate("[1, 2, 3]")) == [1, 2, 3])

        // Only a real list converts, the same gate SwiftPy applies. Other
        // iterables go through `fromPython`, which just iterates.
        let tuple = try evaluate("('a', 'b')")
        #expect([String](tuple) == nil)
        #expect([String].fromPython(tuple.reference) == ["a", "b"])
        #expect([Int].fromPython(try evaluate("range(3)").reference) == [0, 1, 2])
    }

    @Test func convertsDictionaries() throws {
        let object = try ["answer": 42].toPython()
        #expect(try Python.string(of: object) == "{'answer': 42}")

        let read = [String: Int](try evaluate("{'a': 1, 'b': 2}"))
        #expect(read == ["a": 1, "b": 2])
    }

    @Test func convertsNestedValuesAsAny() throws {
        let values = [String: Any](try evaluate("{'n': 1, 's': 'x', 'f': 1.5, 'b': True}"))
        #expect(values?["n"] as? Int == 1)
        #expect(values?["s"] as? String == "x")
        #expect(values?["f"] as? Double == 1.5)
        #expect(values?["b"] as? Bool == true)

        let items = [Any?](try evaluate("[1, 'x', None]"))
        #expect(items?[0] as? Int == 1)
        #expect(items?[1] as? String == "x")
        #expect(items?[2] == nil)
    }

    @Test func readsAndWritesAttributesAsSwiftTypes() throws {
        let sys = try cpy.module("sys")

        // No annotation: falls back to the object, not a Swift type.
        let stdout = sys.stdout
        #expect(stdout != nil)

        let version: String? = sys.version
        #expect(version?.hasPrefix("3.16") == true)

        sys.swiftpy_number = 7
        let number: Int? = sys.swiftpy_number
        #expect(number == 7)

        // Wrong Swift type reads as nil rather than converting.
        let wrong: Double? = sys.swiftpy_number
        #expect(wrong == nil)
    }
}

@Suite(.serialized)
@MainActor
struct CallTests {
    init() throws { try Python.initialize() }

    @Test func callsBuiltinsAndBridgesTheResult() throws {
        let builtins = try cpy.module("builtins")

        let absolute: PythonObject = try #require(builtins.abs)
        #expect(try absolute(-7) == 7 as Int)

        let maximum: PythonObject = try #require(builtins.max)
        #expect(try maximum(3, 9, 4) == 9 as Int)

        let text: PythonObject = try #require(builtins.str)
        #expect(try text(42) == "42" as String)
    }

    @Test func passesNilAsNone() throws {
        let builtins = try cpy.module("builtins")
        let isNone: PythonObject = try #require(builtins.repr)

        #expect(try isNone(nil) == "None" as String)
    }

    @Test func aCallThatReturnsNoneReadsAsNil() throws {
        let sys = try cpy.module("sys")
        let setRecursionLimit: PythonObject = try #require(sys.setrecursionlimit)

        // Unannotated: the disfavoured generic overload steps aside.
        let result = try setRecursionLimit(2000)
        #expect(result == nil)
    }

    @Test func aRaisingCallThrows() throws {
        let builtins = try cpy.module("builtins")
        let integer: PythonObject = try #require(builtins.int)

        do {
            let _: Int = try integer("not a number")
            Issue.record("expected a ValueError")
        } catch {
            #expect(error.type == "ValueError")
            #expect(error.value.contains("invalid literal"))
        }
    }
}
