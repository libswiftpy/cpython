import Testing
@testable import Python

/// A counter the main actor owns, so a test can watch it move while a
/// coroutine is suspended.
@MainActor
private final class Ticks {
    var count = 0
}

@Suite(.serialized)
@MainActor
struct CoroutineTests {
    init() throws { try PyRuntime.initialize() }

    private func coroutine(_ source: String) throws -> PyObject {
        let code = try PythonCompiler.compile(source, filename: "<await>")
        return try PyRuntime.execute(code)
    }

    @Test func topLevelAwaitProducesACoroutine() throws {
        let result = try coroutine("""
        import _swiftpy
        await _swiftpy.sleep(0)
        """)
        #expect(PyRuntime.isCoroutine(result))
    }

    @Test func sourceWithoutAwaitStillRunsInPlace() throws {
        let result = try coroutine("plain = 1 + 1")
        #expect(!PyRuntime.isCoroutine(result))
        #expect(try PyRuntime.evaluate("plain") == "2")
    }

    @Test func drivingRunsTheCoroutineToCompletion() async throws {
        let result = try coroutine("""
        import _swiftpy
        await _swiftpy.sleep(0.01)
        awaited_answer = 42
        """)
        try await PyRuntime.drive(result)

        #expect(try PyRuntime.evaluate("awaited_answer") == "42")
    }

    @Test func awaitEvaluatesToWhatSwiftSendsBack() async throws {
        let result = try coroutine("""
        import _swiftpy
        sent_back = await _swiftpy.sleep(0)
        """)
        try await PyRuntime.drive(result)

        // The driver sends None, which is what the await expression sees.
        #expect(try PyRuntime.evaluate("sent_back is None") == "True")
    }

    /// The point of the whole design: suspending a coroutine must not block
    /// the thread that holds the GIL.
    @Test func theMainActorKeepsRunningWhileSuspended() async throws {
        let ticks = Ticks()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.count += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { ticker.cancel() }

        let result = try coroutine("""
        import _swiftpy
        await _swiftpy.sleep(0.1)
        """)
        try await PyRuntime.drive(result)

        #expect(ticks.count > 1)
    }

    /// A cell goes through `_compile_cell`, where the flag has to be passed a
    /// second time: it does not survive the AST the helper recompiles.
    @Test func aCellCompilesTopLevelAwaitToo() throws {
        let cell = try PythonCompiler.compile("""
        import _swiftpy
        await _swiftpy.sleep(0)
        """, filename: "<cell>", mode: .single)

        #expect(PyRuntime.isCoroutine(try PyRuntime.execute(cell)))
    }

    /// What the host plugs in: its own objects become awaitable through
    /// `awaitable(yielding:)`, and its closure decides what awaiting one does.
    @Test func aPerformClosureDecidesWhatAnAwaitMeans() async throws {
        let result = try coroutine("""
        class Work:
            def __await__(self):
                import _swiftpy
                return _swiftpy._awaitable(self)

        answered = await Work()
        """)

        try await PyRuntime.drive(result) { request in
            #expect(request.typeName == "Work")
            return try "from Swift".toPython()
        }

        #expect(try PyRuntime.evaluate("answered") == "from Swift")
    }

    @Test func anErrorInsideACoroutinePropagates() async throws {
        let result = try coroutine("""
        import _swiftpy
        await _swiftpy.sleep(0)
        raise ValueError('from inside a coroutine')
        """)

        await #expect(throws: PythonError.self) {
            try await PyRuntime.drive(result)
        }
    }

    @Test func awaitingSomethingSwiftCannotRunRaises() async throws {
        let result = try coroutine("""
        class Opaque:
            def __await__(self):
                return (yield self)

        await Opaque()
        """)

        await #expect(throws: PythonError.self) {
            try await PyRuntime.drive(result)
        }
    }
}
