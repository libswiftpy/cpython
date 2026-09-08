import Testing
@testable import Python

// One interpreter per process: the suite is serialized and never finalizes.
@Suite(.serialized)
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

    @Test func reportsPythonExceptions() throws {
        #expect(throws: PythonError.raised("nope")) {
            try Python.evaluate("(_ for _ in ()).throw(ValueError('nope'))")
        }
    }
}
