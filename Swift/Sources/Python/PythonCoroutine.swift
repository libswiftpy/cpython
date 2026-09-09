import CPython
import Foundation

public extension PyRuntime {
    /// Whether `execute` handed back a coroutine instead of running the code,
    /// which is what source with a top-level `await` compiles to.
    @MainActor
    static func isCoroutine(_ object: PyObject) -> Bool {
        object.typeName == "coroutine"
    }

    /// Steps a coroutine to completion, doing the Swift-side work each `await`
    /// asks for. The main actor is free while that work is in flight.
    @MainActor
    @discardableResult
    static func drive(_ coroutine: PyObject) async throws(PythonError) -> PyObject {
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
            sent = try await perform(object)
        }
    }

    /// Runs what a suspended coroutine yielded. The PoC understands one
    /// request; a real bridge would dispatch on the object's type.
    @MainActor
    private static func perform(_ request: PyObject) async throws(PythonError) -> PyObject {
        // Int and Double separately: unlike SwiftPy, this package does not
        // accept a Python int where a float is asked for.
        let seconds: Double? = if let value: Double = request.seconds {
            value
        } else if let value: Int = request.seconds {
            Double(value)
        } else {
            nil
        }
        guard let seconds else {
            throw .TypeError("awaited a \(request.typeName), which Swift cannot run")
        }
        try? await Task.sleep(for: .seconds(seconds))
        return .none
    }
}
