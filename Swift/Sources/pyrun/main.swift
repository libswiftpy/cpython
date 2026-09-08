import Python

// pyrun "print('hi')"  — runs its argument, or a smoke test when given none.
let source = CommandLine.arguments.dropFirst().joined(separator: "\n")

try Python.initialize()
defer { Python.finalize() }

if source.isEmpty {
    print("CPython \(Python.version)")
    print(try Python.evaluate("sum(range(10))"))
} else {
    try Python.run(source)
}
