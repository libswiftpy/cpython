import CPython
import Foundation
import Synchronization

/// A binding whose result is what asynchronous Swift work will produce.
///
/// A binding runs on main and cannot wait there, but the thread that called
/// it -- ``PythonActor``'s, running a cell -- can: it lets go of the GIL and
/// parks until the work completes, so from Python the call is an ordinary
/// blocking one, `name = input("Name?")`, while main stays free. Called
/// from main itself, where nothing can wait, the binding raises instead.
public enum PyWait {
    /// Returns, from a binding body, what has the calling thread wait for the
    /// completion `start` is given. Complete on main; the value crosses to the
    /// waiting thread as a reference.
    @MainActor
    public static func result(
        of start: (@escaping @Sendable @MainActor (Result<PyObject?, PythonError>) -> Void) -> Void
    ) throws(PythonError) -> PyObject {
        guard Bindings.calledFromPythonThread else {
            throw .RuntimeError("cannot wait on the main thread; call this from a cell")
        }
        let pending = Pending()
        current.withLock { $0 = pending }
        start { outcome in
            pending.outcome = outcome
            pending.done.signal()
        }
        return sentinel
    }

    /// What a binding returned to say it waits: not a value, but a marker the
    /// dispatcher recognizes.
    static let sentinel = PyObject(consuming: PyDict_New())

    /// One at a time: the waiting thread takes it before it parks.
    private static let current = Mutex<Pending?>(nil)

    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        // Written before `done` is signalled, read after it is waited for.
        nonisolated(unsafe) var outcome: Result<PyObject?, PythonError>?
    }

    /// On the calling thread, once the binding has returned the marker.
    static func finish() -> PyRef? {
        guard let pending = current.withLock({ current -> Pending? in
            defer { current = nil }
            return current
        }) else {
            PyAPI.raise(.SystemError("a binding waits for nothing"))
            return nil
        }
        let state = PyEval_SaveThread()
        pending.done.wait()
        PyEval_RestoreThread(state)

        switch pending.outcome {
        case .success(let object?):
            Py_IncRef(object.reference)
            return object.reference
        case .success(nil):
            return Py_GetConstant(UInt32(Py_CONSTANT_NONE))
        case .failure(let error):
            PyAPI.raise(error)
            return nil
        case nil:
            PyAPI.raise(.SystemError("a binding's work completed with nothing"))
            return nil
        }
    }
}
