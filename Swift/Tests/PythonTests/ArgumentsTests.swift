import Testing
@testable import Python

@Suite(.serialized)
@MainActor
struct ArgumentsTests {
    init() throws { try PyRuntime.initialize() }

    /// A method's receiver is argument 0, which is where pocketpy puts it and
    /// what the shared binding code reads.
    @Test func aMethodCountsItsReceiverAsTheFirstArgument() throws {
        let module = try #require(cpy.newmodule("argument_module"))
        let type = try #require(cpy.newtype(name: "Probe", module: module))

        type.function("describe(self, a: int, b: str) -> str") { receiver, args in
            PyAPI.return {
                let arguments = PyArguments(method: receiver, args)
                let number = try Int.cast(arguments, 1)
                let text = try String.cast(arguments, 2)
                return "\(arguments.count):\(arguments[0] == receiver):\(number):\(text)"
            }
        }

        try PyRuntime.run("import argument_module")
        #expect(try PyRuntime.evaluate("argument_module.Probe().describe(7, 'x')") == "3:true:7:x")
    }

    /// A module function's `self` is the module, so it is not an argument.
    @Test func aFunctionStartsAtItsFirstArgument() throws {
        let module = try #require(cpy.newmodule("function_module"))

        module.def("joined(a: str, b: str) -> str") { receiver, args in
            PyAPI.return {
                let arguments = PyArguments(function: receiver, args)
                return "\(arguments.count):" + (try String.cast(arguments, 0))
                    + (try String.cast(arguments, 1))
            }
        }

        try PyRuntime.run("import function_module")
        #expect(try PyRuntime.evaluate("function_module.joined('a', 'b')") == "2:ab")
    }

    @Test func readingPastTheEndIsNil() throws {
        let empty = PyArguments(function: nil, nil)
        #expect(empty.count == 0)
        #expect(empty[0] == nil)
        #expect(empty[-1] == nil)

        let text = try "only".toPython()
        let single = PyArguments(method: text.reference, nil)
        #expect(single.count == 1)
        #expect(single[0] == text.reference)
        #expect(single[1] == nil)
    }
}
