import CPython

extension Python {
    /// Routes everything Python writes to `sys.stdout` and `sys.stderr` —
    /// `print()`, tracebacks, `sys.stderr.write` — to a Swift closure.
    ///
    /// Text arrives in the chunks Python writes it, so a single `print()` call
    /// usually shows up as two: the value, then the newline.
    ///
    ///     try Python.initialize()
    ///     try Python.redirectOutput { print("python:", $0, terminator: "") }
    ///
    /// Pass `nil` to restore the interpreter's own streams.
    public static func redirectOutput(to hook: ((String) -> Void)?) throws {
        outputHook = hook

        guard hook != nil else {
            try run("import sys; sys.stdout = sys.__stdout__; sys.stderr = sys.__stderr__")
            return
        }

        try withGIL {
            guard let main = PyImport_AddModule("__main__"),
                  let globals = PyModule_GetDict(main),
                  let write = PyCFunction_NewEx(writeMethod, nil, nil) else {
                throw PythonError.executionFailed
            }
            defer { Py_DecRef(write) }
            PyDict_SetItemString(globals, "_swift_write", write)
        }

        // A file-like object is all sys.stdout has to be; `print` only ever
        // calls write(), and the interpreter calls flush() on shutdown.
        try run("""
            class _SwiftOutput:
                def write(self, text):
                    _swift_write(text)
                    return len(text)

                def flush(self):
                    pass

                def isatty(self):
                    return False

            import sys
            sys.stdout = sys.stderr = _SwiftOutput()
            del _SwiftOutput
            """)
    }

    private nonisolated(unsafe) static var outputHook: ((String) -> Void)?

    /// `write` as CPython sees it. Allocated once and never freed: CPython
    /// keeps referring to the method table for as long as the function lives.
    private nonisolated(unsafe) static let writeMethod: UnsafeMutablePointer<PyMethodDef> = {
        let method = UnsafeMutablePointer<PyMethodDef>.allocate(capacity: 1)
        method.initialize(to: PyMethodDef(
            ml_name: strdup("write"),
            ml_meth: { _, argument in
                if let argument, let text = PyUnicode_AsUTF8(argument) {
                    Python.outputHook?(String(cString: text))
                }
                return Py_GetConstant(UInt32(Py_CONSTANT_NONE))
            },
            ml_flags: Int32(METH_O),
            ml_doc: nil
        ))
        return method
    }()
}
