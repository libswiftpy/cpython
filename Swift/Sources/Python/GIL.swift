import CPython
import Foundation
import Synchronization

/// Who holds the GIL.
///
/// Main owns it whenever the main run loop is awake: it is taken as the loop
/// wakes and given back as the loop goes to sleep. Main-actor code -- a
/// binding body, a `PyObject` call from a SwiftUI view -- therefore always
/// finds it held, and ``PythonActor``'s thread borrows it while main sleeps.
/// CPython's switch interval bounds how long a waking main waits for it.
enum GIL {
    /// Main's thread state while it is not holding the GIL.
    private nonisolated(unsafe) static var parkedMain: UnsafeMutablePointer<PyThreadState>?

    /// The switch interval: how long a thread asking for the GIL waits before
    /// the holder is made to drop it, so also how long a waking main waits.
    static let switchInterval = 0.0005

    /// Hooks the main run loop. Main keeps the GIL it took during
    /// initialization until the loop first sleeps.
    @MainActor
    static func shareWithRunLoop() {
        // First to run after waking, last before sleeping: Core Animation's
        // commit, which evaluates SwiftUI bodies, sits in between.
        let take = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in resumeMain() }
        let give = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { _, _ in parkMain() }
        CFRunLoopAddObserver(CFRunLoopGetMain(), take, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), give, .commonModes)
    }

    private static func parkMain() {
        guard parkedMain == nil else { return }
        parkedMain = PyEval_SaveThread()
    }

    private static func resumeMain() {
        guard let state = parkedMain else { return }
        parkedMain = nil
        PyEval_RestoreThread(state)
        // Before anything else runs on main, so what died while it slept is
        // gone by the time main-actor code looks.
        PyRelease.drain()
        MainActor.assumeIsolated { PyRelease.runMainWork() }
    }
}

/// Work that needs the GIL, or the main actor, from a thread that has neither.
enum PyRelease {
    private static let pending = Mutex<[GILBound<CPython.PyObject>]>([])
    private static let mainWork = Mutex<[@Sendable @MainActor () -> Void]>([])

    /// Drops a reference later, from a thread holding the GIL.
    static func `defer`(_ reference: PyRef) {
        pending.withLock { $0.append(GILBound(reference)) }
    }

    /// With the GIL held.
    static func drain() {
        let batch = pending.withLock { pending -> [GILBound<CPython.PyObject>] in
            defer { pending.removeAll() }
            return pending
        }
        for reference in batch {
            Py_DecRef(reference.pointer)
        }
    }

    /// Runs `work` on the main actor before any other main-actor code, or
    /// inline when this already is main.
    static func onMain(_ work: @Sendable @MainActor @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
            return
        }
        mainWork.withLock { $0.append(work) }
        // Wakes the loop, in case nothing else would.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    @MainActor
    static func runMainWork() {
        let batch = mainWork.withLock { work -> [@Sendable @MainActor () -> Void] in
            defer { work.removeAll() }
            return work
        }
        for work in batch {
            work()
        }
    }
}

/// Runs `body` on the main actor with the GIL held, from wherever CPython
/// made the call: inline on main, otherwise across a hop during which this
/// thread lets go of the GIL -- so main can never wait on a thread that is
/// waiting on main.
func onMain<T>(_ body: @MainActor () -> T) -> T {
    // Handed back by hand: the isolated returns want a Sendable result, and
    // nothing here outlives the call.
    nonisolated(unsafe) var result: T?
    if Thread.isMainThread {
        MainActor.assumeIsolated { result = body() }
        return result!
    }
    // Captured here: task-locals do not travel through a queue hop.
    let carry = PyBridge.carryContext?()
    let state = PyEval_SaveThread()
    defer { PyEval_RestoreThread(state) }
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            guard let carry else {
                result = body()
                return
            }
            carry { result = body() }
        }
    }
    return result!
}
