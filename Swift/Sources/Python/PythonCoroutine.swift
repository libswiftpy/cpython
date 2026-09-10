import CPython
import Foundation

public extension PyRuntime {
    /// Whether `execute` handed back a coroutine instead of running the code,
    /// which is what source with a top-level `await` compiles to.
    @MainActor
    static func isCoroutine(_ object: PyObject) -> Bool {
        object.typeName == "coroutine"
    }

    /// A one-shot iterator handing `request` to the driver: what a Swift-backed
    /// `__await__` returns to make its object awaitable.
    @MainActor
    static func awaitable(yielding request: PyObject) throws(PythonError) -> PyObject {
        let make = try helper("_awaitable")
        defer { Py_DecRef(make) }

        guard let iterator = PyObject_CallOneArg(make, request.reference) else {
            throw raisedError()
        }
        return PyObject(consuming: iterator)
    }

    /// Steps a coroutine to completion, handing whatever it suspends on to
    /// `perform` and sending the result back in. The main actor is free while
    /// that work is in flight.
    @MainActor
    @discardableResult
    static func drive(
        _ coroutine: PyObject,
        perform: @MainActor (PyObject) async throws -> PyObject = { try await performSleep($0) }
    ) async throws(PythonError) -> PyObject {
        // A coroutine that has not started yet can only be sent None.
        var sent = PyObject.none

        while true {
            var produced: PyRef?
            let status = PyIter_Send(coroutine.reference, sent.reference, &produced)

            if status == PYGEN_ERROR {
                throw raisedError()
            }
            guard let produced else {
                throw .SystemError("a coroutine produced nothing")
            }
            let object = PyObject(consuming: produced)

            // PYGEN_RETURN carries the return value, so there is no
            // StopIteration to unwrap.
            if status == PYGEN_RETURN {
                return object
            }

            do {
                sent = try await perform(object)
            } catch let error as PythonError {
                throw error
            } catch {
                throw PythonError.RuntimeError("\(error)")
            }
        }
    }

    /// What an awaited object means when the host has not said: this package
    /// understands its own `_swiftpy.sleep` and nothing else.
    @MainActor
    static func performSleep(_ request: PyObject) async throws -> PyObject {
        guard let seconds: Double = request.seconds else {
            throw PythonError.TypeError("awaited a \(request.typeName), which Swift cannot run")
        }
        try? await Task.sleep(for: .seconds(seconds))
        return .none
    }
}
