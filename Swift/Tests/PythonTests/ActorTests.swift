import Testing
import Foundation
import Synchronization
@testable import Python
import CPython

private typealias PyObject = Python.PyObject

@Suite(.serialized)
@MainActor
struct ActorTests {
    init() throws { try PyRuntime.initialize() }

    private func compile(_ source: String) throws -> PyObject {
        try PythonCompiler.compile(source, filename: "<actor>")
    }

    @Test func executeRunsOffTheMainThreadAndBindingsOnIt() async throws {
        let module = try #require(py.newmodule("actor_probe"))
        Probe.calledFrom.withLock { $0.removeAll() }
        module.def("where()") { _, _ in
            // The thunk has already taken the call to main.
            Probe.noteCaller()
            return PyAPI.return { Thread.isMainThread }
        }

        let code = try compile("""
        import actor_probe, threading
        cell_on_main = threading.get_ident() == threading.main_thread().ident
        binding_ran_on_main = actor_probe.where()
        """)
        try await PyRuntime.execute(code)

        #expect(try PyRuntime.evaluate("cell_on_main") == "False")
        #expect(Probe.calledFrom.withLock { $0 } == [true])
        #expect(try PyRuntime.evaluate("binding_ran_on_main") == "True")
    }

    @Test func mainReachesPythonWhileACellRuns() async throws {
        try PyRuntime.run("""
        class Component:
            ticks = 0
            def update(self, dt):
                self.ticks += 1
                return dt
        component = Component()
        """)
        let component = try #require(py.main.component)

        let busy = try compile("""
        import time
        deadline = time.monotonic() + 0.3
        while time.monotonic() < deadline:
            pass
        """)
        // Its own namespace: other suites clear `__main__` while this runs.
        let namespace = try PyRuntime.namespace()
        let cell = Task { try await PyRuntime.execute(busy, globals: namespace) }

        // Give the cell time to take the GIL, then call in from main.
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        let update = try #require(component.update)
        let result: Double = try update(0.3)
        let waited = start.duration(to: clock.now)

        #expect(result == 0.3)
        #expect(waited < .milliseconds(50), "waited \(waited) for the GIL")
        _ = try await cell.value
        let ticks: Int? = component.ticks
        #expect(ticks == 1)
    }

    @Test func anInterruptStopsACellAtItsNextBytecode() async throws {
        let forever = try compile("""
        while True:
            pass
        """)
        let namespace = try PyRuntime.namespace()
        let cell = Task { try await PyRuntime.execute(forever, globals: namespace) }

        try await Task.sleep(for: .milliseconds(20))
        PyRuntime.interrupt()

        let clock = ContinuousClock()
        let start = clock.now
        let error = await #expect(throws: PythonError.self) { try await cell.value }
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(error?.type == "KeyboardInterrupt")
    }

    @Test func aBindingCanHaveTheCellWaitForSwiftWork() async throws {
        let module = try #require(py.newmodule("actor_waiting"))
        module.def("answer()") { _, _ in
            PyAPI.return {
                try PyWait.result { complete in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        complete(.success(try? 42.toPython()))
                    }
                }
            }
        }
        module.def("failing()") { _, _ in
            PyAPI.return {
                try PyWait.result { complete in
                    DispatchQueue.main.async { complete(.failure(.ValueError("no"))) }
                }
            }
        }

        let code = try compile("""
        import actor_waiting
        waited_answer = actor_waiting.answer()
        try:
            actor_waiting.failing()
        except ValueError as error:
            waited_failure = str(error)
        """)
        try await PyRuntime.execute(code)
        #expect(try PyRuntime.evaluate("waited_answer") == "42")
        #expect(try PyRuntime.evaluate("waited_failure") == "no")

        // Main has nowhere to wait.
        #expect(throws: PythonError.self) {
            try PyRuntime.run("import actor_waiting; actor_waiting.answer()")
        }
    }

    @Test func aBindingCarriesTheHostContext() async throws {
        let module = try #require(py.newmodule("actor_context"))
        Probe.seen.withLock { $0.removeAll() }
        PyBridge.carryContext = {
            let value = Probe.current
            return { body in Probe.$current.withValue(value) { body() } }
        }
        defer { PyBridge.carryContext = nil }
        module.def("read()") { _, _ in
            PyAPI.return {
                Probe.seen.withLock { $0.append(Probe.current) }
                return nil
            }
        }

        let code = try compile("""
        import actor_context
        actor_context.read()
        """)
        try await Probe.$current.withValue("carried") {
            try await PyRuntime.execute(code)
        }
        #expect(Probe.seen.withLock { $0 } == ["carried"])
    }

    @Test func aBoxDroppedWithoutTheGILIsReleasedLater() async throws {
        try PyRuntime.run("import sys\nsentinel = object()")
        let sentinel = try #require(py.main.sentinel)
        let before: Int = try py.main.sys!.getrefcount!(sentinel)

        // Made in a scope of its own, so only the probe holds it afterwards.
        func hold() { Probe.held.withLock { $0 = PyObject(retaining: sentinel.reference) } }
        hold()
        let during: Int = try py.main.sys!.getrefcount!(sentinel)
        #expect(during == before + 1)

        // Dropped on a thread that never holds the GIL.
        await Task.detached { Probe.held.withLock { $0 = nil } }.value

        // Main drains what died while it slept as it wakes.
        try await Task.sleep(for: .milliseconds(1))
        let after: Int = try py.main.sys!.getrefcount!(sentinel)
        #expect(after == before)
    }

    @Test func aBindingsErrorIsRaisedWhereItWasCalled() async throws {
        let module = try #require(py.newmodule("actor_raising"))
        module.def("fail()") { _, _ in
            PyAPI.return { throw PythonError.ValueError("from main") }
        }

        // The body raised on main; the cell, on the actor, must see it.
        let code = try compile("""
        import actor_raising
        try:
            actor_raising.fail()
            caught = None
        except ValueError as error:
            caught = str(error)
        """)
        try await PyRuntime.execute(code)
        #expect(try PyRuntime.evaluate("caught") == "from main")
        // And nothing is left behind on main.
        #expect(PyErr_Occurred() == nil)
    }

    @Test func theTraceFollowsTheCellOntoThePythonThread() async throws {
        Probe.tracedFrom.withLock { $0.removeAll() }
        py.setTrace { _, _ in Probe.noteTrace() }
        defer { py.setTrace(nil) }

        try await PyRuntime.execute(try compile("traced = 1"))
        // Compiling traced on main too; the cell itself ran on the actor.
        #expect(Probe.tracedFrom.withLock { $0 }.contains(false))
    }
}

/// Shared with the bindings, which as C function pointers capture nothing.
/// The recorders are nonisolated: a closure written inside the main-actor
/// suite would assert main, and these run on the Python thread.
private enum Probe {
    @TaskLocal static var current = "none"
    static let calledFrom = Mutex<[Bool]>([])
    static let seen = Mutex<[String]>([])
    static let tracedFrom = Mutex<Set<Bool>>([])
    static let held = Mutex<PyObject?>(nil)

    nonisolated static func noteCaller() {
        calledFrom.withLock { $0.append(Thread.isMainThread) }
    }

    nonisolated static func noteTrace() {
        tracedFrom.withLock { _ = $0.insert(Thread.isMainThread) }
    }
}
