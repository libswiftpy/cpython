import CPython
import Foundation
import Synchronization

/// Where code runs: one thread of its own that holds the GIL for as long as a
/// job runs and gives it back in between. Main-actor calls into Python wait at
/// most CPython's switch interval for it. See ``GIL``.
@globalActor
public actor PythonActor {
    public static let shared = PythonActor()

    private init() {}

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        PythonExecutor.shared.asUnownedSerialExecutor()
    }
}

/// The actor's thread. Started on first use, once the interpreter is up.
final class PythonExecutor: SerialExecutor {
    static let shared: PythonExecutor = {
        let executor = PythonExecutor()
        executor.start()
        return executor
    }()

    private let jobs = Mutex<[UnownedJob]>([])
    private let wake = DispatchSemaphore(value: 0)
    private nonisolated(unsafe) var thread: Thread?
    /// CPython's ident for the thread, what an async exception is addressed to.
    private(set) nonisolated(unsafe) var threadIdent: UInt = 0

    private func start() {
        precondition(Py_IsInitialized() != 0, "start the interpreter before using PythonActor")
        let thread = Thread { [unowned self] in run() }
        thread.name = "Python"
        thread.qualityOfService = .userInitiated
        // Deep recursion lives here now, not on main's stack.
        thread.stackSize = 16 << 20
        self.thread = thread
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        jobs.withLock { $0.append(job) }
        wake.signal()
    }

    func checkIsolated() {
        precondition(Thread.current === thread, "expected the Python thread")
    }

    private func run() {
        // One thread state for the life of the thread, so the trace hook,
        // threading.local and contextvars carry across jobs.
        _ = PyGILState_Ensure()
        threadIdent = PyThread_get_thread_ident()
        PyRuntime.prepareThread?()
        var parked = PyEval_SaveThread()

        while true {
            wake.wait()
            let batch = jobs.withLock { jobs -> [UnownedJob] in
                defer { jobs.removeAll() }
                return jobs
            }
            guard !batch.isEmpty else { continue }

            PyEval_RestoreThread(parked)
            PyRelease.drain()
            PyAPI.installTraceIfNeeded()
            for job in batch {
                job.runSynchronously(on: asUnownedSerialExecutor())
            }
            parked = PyEval_SaveThread()
        }
    }
}

public extension PyRuntime {
    /// Runs once on ``PythonActor``'s thread as it starts, with the GIL held
    /// and a thread state of its own: where a host sets what CPython keeps
    /// per thread, such as asyncio's running loop. Set it before the first
    /// use of the actor.
    nonisolated(unsafe) static var prepareThread: (@Sendable () -> Void)?

    /// Raises `KeyboardInterrupt` in whatever ``PythonActor`` is running, at
    /// its next bytecode: a blocking C call returns first. Needs the GIL,
    /// which main has while its run loop is awake. One that has not landed
    /// by the time the code ends stays pending for whatever runs next, so
    /// the caller withdraws it then with ``clearInterrupt()``.
    nonisolated static func interrupt() {
        guard let interrupt = exceptionType(named: "KeyboardInterrupt") else { return }
        PyThreadState_SetAsyncExc(PythonExecutor.shared.threadIdent, interrupt)
    }

    nonisolated static func clearInterrupt() {
        PyThreadState_SetAsyncExc(PythonExecutor.shared.threadIdent, nil)
    }

    /// Runs a code object on ``PythonActor``, off the main actor. The same
    /// call as the synchronous one, for code that should not hold main up.
    @PythonActor
    @discardableResult
    static func execute(
        _ code: PyObject,
        globals: PyObject? = nil,
        locals: PyObject? = nil
    ) async throws(PythonError) -> PyObject {
        try run(code: code, globals: globals, locals: locals)
    }
}
