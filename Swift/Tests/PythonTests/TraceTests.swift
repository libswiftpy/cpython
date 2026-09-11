import Testing
@testable import Python

@MainActor
@Suite(.serialized)
struct TraceTests {
    @MainActor
    final class Recorder {
        struct Entry {
            let event: PyAPI.TraceEvent
            let line: Int?
            let source: String?
        }

        var entries: [Entry] = []

        func record(_ frame: PyAPI.Frame, _ event: PyAPI.TraceEvent) {
            entries.append(Entry(
                event: event,
                line: frame.lineNumber,
                source: frame.sourceLocation
            ))
        }
    }

    init() throws { try PyRuntime.initialize() }

    @Test func reportsLinesCallsAndReturns() throws {
        let recorder = Recorder()
        py.setTrace(recorder.record)
        defer { py.setTrace(nil) }

        let code = try PythonCompiler.compile("""
        x = 10
        def value():
            return x + 1
        result = value()
        """, filename: "<trace>")
        try PyRuntime.execute(code)

        let lines = recorder.entries.compactMap {
            $0.event == .line && $0.source == "<trace>" ? $0.line : nil
        }
        #expect(lines == [1, 2, 4, 3])
        #expect(recorder.entries.filter { $0.event == .push }.count == 2)
        #expect(recorder.entries.filter { $0.event == .pop }.count == 2)
    }

    @Test func replacingAndRemovingTheTraceWorks() throws {
        let first = Recorder()
        let second = Recorder()
        py.setTrace(first.record)
        py.setTrace(second.record)
        try PyRuntime.run("value = 1")
        #expect(first.entries.isEmpty)
        #expect(!second.entries.isEmpty)

        py.setTrace(nil)
        second.entries.removeAll()
        try PyRuntime.run("other = 2")
        #expect(second.entries.isEmpty)
    }
}
