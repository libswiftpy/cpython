import CPython

public extension PyAPI {
    /// An interpreter trace event shared with SwiftPy's pocketpy backend.
    enum TraceEvent: Equatable {
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
    struct Frame {
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

    typealias TraceFunction = @MainActor (Frame, TraceEvent) -> Void

    /// Installs a synchronous trace callback for line and frame events, or
    /// removes it when `trace` is nil.
    func setTrace(_ trace: TraceFunction?) {
        PyAPI.traceFunction = trace
        PyEval_SetTrace(trace == nil ? nil : traceTrampoline, nil)
    }

    internal static var traceFunction: TraceFunction?
}

@MainActor
private let traceTrampoline: Py_tracefunc = { _, frame, event, _ in
    guard let frame,
          let event = PyAPI.TraceEvent(event) else { return 0 }

    PyAPI.traceFunction?(PyAPI.Frame(reference: frame), event)
    return 0
}
