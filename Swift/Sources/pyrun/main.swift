import Python

// pyrun "print('hi')"  — runs its argument, or a smoke test when given none.
let source = CommandLine.arguments.dropFirst().joined(separator: "\n")

// No initialize call: the first use of `cpy` starts the interpreter.
defer { PyRuntime.finalize() }

if source.isEmpty {
    print("CPython \(cpy.version)")
    print(try cpy.evaluate("sum(range(10))"))
} else {
    try cpy.run(source)
}
