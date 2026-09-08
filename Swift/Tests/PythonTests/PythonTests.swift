import Testing
@testable import Python

// One interpreter per process: the suite is serialized and never finalizes.
// Main actor because the interpreter keeps the GIL on whichever thread starts
// it, so every test has to run on that same thread.
@Suite(.serialized)
@MainActor
struct PythonTests {
    init() throws { try Python.initialize() }

    @Test func interpreterStarts() {
        #expect(Python.isInitialized)
        #expect(Python.version.hasPrefix("3.16"))
    }

    @Test func evaluatesAnExpression() throws {
        #expect(try Python.evaluate("2 ** 10") == "1024")
    }

    @Test func runsStatements() throws {
        try Python.run("greeting = 'hello from ' + 'python'")
        #expect(try Python.evaluate("greeting") == "hello from python")
    }

    @Test func decodesUTF8() throws {
        #expect(try Python.evaluate("'héllo'.upper()") == "HÉLLO")
    }

    @Test func redirectsOutputToSwift() throws {
        nonisolated(unsafe) var captured = ""
        try Python.redirectOutput { captured += $0 }
        defer { try? Python.redirectOutput(to: nil) }

        try Python.run("print('from python', 1 + 1)")
        #expect(captured == "from python 2\n")

        // stderr too, which is where tracebacks go.
        try Python.run("import sys; sys.stderr.write('to stderr')")
        #expect(captured.hasSuffix("to stderr"))
    }

    @Test func globalStartsTheInterpreter() throws {
        #expect(cpy.isInitialized)
        #expect(try cpy.evaluate("1 + 1") == "2")
    }

    @Test func runsACellOfSeveralStatements() throws {
        nonisolated(unsafe) var captured = ""
        try Python.redirectOutput { captured += $0 }
        defer { try? Python.redirectOutput(to: nil) }

        // Every expression statement echoes, which plain `single` input cannot
        // do for more than one statement.
        let cell = try PythonCompiler.compile("a = 1\na + 1\nprint('hi')\n2 + 2", mode: .single)
        try Python.execute(cell)
        #expect(captured == "2\nhi\n4\n")
    }

    @Test(arguments: [PythonCompiler.Mode.execution, .evaluation, .single])
    func compilesInEveryMode(mode: PythonCompiler.Mode) throws {
        _ = try PythonCompiler.compile("1 + 1", mode: mode)
    }

    /// The reason `single` goes through the helper: CPython's own single input
    /// takes exactly one statement, a console cell does not.
    @Test func compilesAMultiStatementCellInSingleMode() throws {
        _ = try PythonCompiler.compile("a = 1\na + 1", mode: .single)
    }

    @Test func executesCompiledCode() throws {
        let code = try PythonCompiler.compile("2 ** 8", mode: .evaluation)
        #expect(try Python.string(of: Python.execute(code)) == "256")
    }

    @Test func namespacesAreIsolatedFromMain() throws {
        let session = try Python.namespace()
        try Python.execute(
            PythonCompiler.compile("hidden = 'only here'"),
            globals: session
        )

        // Visible in its own namespace, invisible to __main__.
        let read = try PythonCompiler.compile("hidden", mode: .evaluation)
        #expect(try Python.string(of: Python.execute(read, globals: session)) == "only here")
        #expect(throws: PythonError.self) { try Python.execute(read) }
    }

    @Test func readsAttributesByDynamicMember() throws {
        let sys = try cpy.module("sys")
        let version = try #require(sys.version)
        #expect(try Python.string(of: version).hasPrefix("3.16"))

        // Missing reads as nil, and clears the exception it raised rather than
        // leaving it to surface at the next call.
        #expect(sys.no_such_attribute == nil)
        #expect(try Python.evaluate("1 + 1") == "2")

        // So does None, matching pocketpy's PyObject.
        let none = try Python.execute(
            PythonCompiler.compile("type('X', (), {'nothing': None})()", mode: .evaluation)
        )
        #expect(none.nothing == nil)
    }

    @Test func writesAttributesByDynamicMember() throws {
        let sys = try cpy.module("sys")
        sys.swiftpy_marker = try Python.execute(
            PythonCompiler.compile("'written'", mode: .evaluation)
        )
        #expect(try Python.evaluate("__import__('sys').swiftpy_marker") == "written")

        // nil writes None, so a cleared attribute reads back as nil.
        sys.swiftpy_marker = nil
        #expect(sys.swiftpy_marker == nil)
    }

    @Test func convertsStringsBothWays() throws {
        let object = try "héllo".toPython()
        #expect(String(object) == "héllo")
        #expect(try Python.string(of: object) == "héllo")

        // A wrong type reads as nil, and `cast` says what it wanted.
        let number = try PythonCompiler.compile("42", mode: .evaluation)
        let notAString = try Python.execute(number)
        #expect(String(notAString) == nil)

        do {
            _ = try String.cast(notAString)
            Issue.record("expected a TypeError")
        } catch {
            #expect(error.type == "TypeError")
            #expect(error.value == "Expected str got int at position 0")
        }
    }

    @Test func writesIntoAnExistingBox() throws {
        let box = try "first".toPython()
        let held = box.reference

        try "second".toPython(box)
        #expect(String(box) == "second")

        // The old object is released, not rewritten: only the box moved.
        #expect(box.reference != held)
    }

    @Test func compileErrorsCarryTheFilename() throws {
        do {
            _ = try PythonCompiler.compile("def f(", filename: "<cell>")
            Issue.record("expected a SyntaxError")
        } catch {
            #expect(error.type == "SyntaxError")
            #expect("\(error)".contains("<cell>"))
        }
    }

    @Test func cellErrorsCarryATraceback() throws {
        do {
            let cell = try PythonCompiler.compile("raise ValueError('nope')", filename: "<cell>", mode: .single)
            try Python.execute(cell)
            Issue.record("expected the cell to raise")
        } catch {
            #expect(error.type == "ValueError")
            #expect(error.value == "nope")
            #expect(error.traceback?.contains("<cell>") == true)
        }
    }

    @Test func reportsPythonExceptions() throws {
        do {
            _ = try Python.evaluate("(_ for _ in ()).throw(ValueError('nope'))")
            Issue.record("expected the expression to raise")
        } catch {
            #expect(error.type == "ValueError")
            #expect(error.value == "nope")
        }
    }
}
