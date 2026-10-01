import CPython

public extension PyAPI {
    /// An interpreter trace event shared with SwiftPy's pocketpy backend.
    nonisolated enum TraceEvent: Equatable, Sendable {
        /// About to execute a new source line.
        case line
        /// A frame was pushed (a call was entered).
        case push
        /// A frame was popped (a call returned or raised).
        case pop

        init?(_ event: Int32) {
            switch event {
            case PyTrace_LINE: self = .line
            case PyTrace_CALL: self = .push
            case PyTrace_RETURN: self = .pop
            default: return nil
            }
        }
    }

    /// A lightweight view over a CPython frame passed to a trace function.
    /// The pointer is only valid for the duration of the callback.
    nonisolated struct Frame {
        let reference: OpaquePointer

        public var lineNumber: Int? {
            let line = PyFrame_GetLineNumber(reference)
            return line >= 0 ? Int(line) : nil
        }

        public var sourceLocation: String? {
            guard let code = PyFrame_GetCode(reference) else { return nil }
            defer { Py_DecRef(UnsafeMutableRawPointer(code).assumingMemoryBound(to: CPython.PyObject.self)) }

            let object = UnsafeMutableRawPointer(code).assumingMemoryBound(to: CPython.PyObject.self)
            guard let filename = PyObject_GetAttrString(object, "co_filename") else {
                PyErr_Clear()
                return nil
            }
            defer { Py_DecRef(filename) }
            guard let text = PyUnicode_AsUTF8(filename) else {
                PyErr_Clear()
                return nil
            }
            return String(cString: text)
        }
    }

    /// The innermost frame of the running stack whose source passes `matches`,
    /// as its source and line. Call with the GIL held, from code Python called.
    nonisolated static func frame(where matches: (String) -> Bool) -> (source: String, line: Int)? {
        // Unchecked: no thread state, as off Python's thread, means no stack.
        guard let state = PyThreadState_GetUnchecked() else { return nil }
        var current = PyThreadState_GetFrame(state)
        while let frame = current {
            defer { Py_DecRef(UnsafeMutableRawPointer(frame).assumingMemoryBound(to: CPython.PyObject.self)) }
            let view = Frame(reference: frame)
            if let source = view.sourceLocation, matches(source), let line = view.lineNumber {
                return (source, line)
            }
            current = PyFrame_GetBack(frame)
        }
        return nil
    }

    /// Called on whichever thread runs the traced code, with the GIL held.
    typealias TraceFunction = @Sendable (Frame, TraceEvent) -> Void

    /// Installs a synchronous trace callback for line and frame events, or
    /// removes it when `trace` is nil.
    func setTrace(_ trace: TraceFunction?) {
        PyAPI.traceFunction = trace
        PyAPI.traceGeneration += 1
        // A trace hook is per thread state; the Python thread picks this one
        // up before its next job.
        PyEval_SetTrace(trace == nil ? nil : traceTrampoline, nil)
    }

    internal nonisolated(unsafe) static var traceFunction: TraceFunction?
    private nonisolated(unsafe) static var traceGeneration = 0
    private nonisolated(unsafe) static var installedTraceGeneration = 0

    /// Brings the calling thread's trace hook up to date with ``setTrace``.
    nonisolated static func installTraceIfNeeded() {
        guard installedTraceGeneration != traceGeneration else { return }
        installedTraceGeneration = traceGeneration
        PyEval_SetTrace(traceFunction == nil ? nil : traceTrampoline, nil)
    }
}

private let traceTrampoline: Py_tracefunc = { _, frame, event, _ in
    guard let frame,
          let event = PyAPI.TraceEvent(event) else { return 0 }

    PyAPI.traceFunction?(PyAPI.Frame(reference: frame), event)
    return 0
}
