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
    /// that work is in flight. An error from `perform` is raised at the await
    /// site, where a `try` around it can catch it.
    @MainActor
    @discardableResult
    static func drive(
        _ coroutine: PyObject,
        perform: @MainActor (PyObject) async throws -> PyObject = { try await performSleep($0) }
    ) async throws(PythonError) -> PyObject {
        // A coroutine that has not started yet can only be sent None.
        var step = Step.send(.none)

        while true {
            let produced: PyObject
            switch try resume(coroutine, with: step) {
            case .returned(let value): return value
            case .yielded(let request): produced = request
            }

            do {
                step = .send(try await perform(produced))
            } catch let error as PythonError {
                step = .throw(error)
            } catch {
                step = .throw(.RuntimeError("\(error)"))
            }
        }
    }

    private enum Step {
        case send(PyObject)
        case `throw`(PythonError)
    }

    private enum Outcome {
        case yielded(PyObject)
        case returned(PyObject)
    }

    /// One step: `send` for a value, `throw` to raise at the await point.
    @MainActor
    private static func resume(_ coroutine: PyObject, with step: Step) throws(PythonError) -> Outcome {
        switch step {
        case .send(let value):
            var produced: PyRef?
            let status = PyIter_Send(coroutine.reference, value.reference, &produced)
            if status == PYGEN_ERROR { throw raisedError() }
            guard let produced else { throw .SystemError("a coroutine produced nothing") }
            // PYGEN_RETURN carries the return value, so there is no
            // StopIteration to unwrap.
            let object = PyObject(consuming: produced)
            return status == PYGEN_RETURN ? .returned(object) : .yielded(object)

        case .throw(let error):
            PyAPI.raise(error)
            guard let exception = PyErr_GetRaisedException(),
                  let method = PyObject_GetAttrString(coroutine.reference, "throw") else {
                throw raisedError()
            }
            defer { Py_DecRef(exception); Py_DecRef(method) }

            // coroutine.throw() answers like next(): the next request, or
            // StopIteration carrying the return value, or the error unhandled.
            if let produced = PyObject_CallOneArg(method, exception) {
                return .yielded(PyObject(consuming: produced))
            }
            // Looked up by name: the C global is not concurrency-safe to read.
            guard PyErr_ExceptionMatches(exceptionType(named: "StopIteration")) != 0,
                  let stop = PyErr_GetRaisedException() else {
                throw raisedError()
            }
            defer { Py_DecRef(stop) }
            let value = PyObject_GetAttrString(stop, "value")
            return .returned(value.map { PyObject(consuming: $0) } ?? .none)
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
