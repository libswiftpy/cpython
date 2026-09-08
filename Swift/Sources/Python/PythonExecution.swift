import CPython

extension Python {
    /// Runs a code object from ``PythonCompiler/compile(_:filename:mode:)``.
    ///
    /// Defaults to `__main__`'s namespace. Pass a ``namespace()`` of your own
    /// for code that should not see, or be seen by, what runs there.
    @discardableResult
    public static func execute(
        _ code: PyObject,
        globals: PyObject? = nil,
        locals: PyObject? = nil
    ) throws(PythonError) -> PyObject {
        // `??` widens a typed throw to `any Error`, so spell the fallback out.
        let globals = if let globals { globals } else { try mainNamespace() }
        let locals = locals ?? globals

        guard let result = PyEval_EvalCode(code.reference, globals.reference, locals.reference) else {
            throw raisedError()
        }
        return PyObject(consuming: result)
    }

    /// A fresh namespace, seeded with the builtins so code can run in it.
    public static func namespace() throws(PythonError) -> PyObject {
        guard let dictionary = PyDict_New() else { throw .SystemError("could not allocate a dict") }
        let namespace = PyObject(consuming: dictionary)

        guard let builtins = PyEval_GetBuiltins(),
              PyDict_SetItemString(dictionary, "__builtins__", builtins) == 0 else {
            throw raisedError()
        }
        return namespace
    }

    /// `str()` of an object.
    public static func string(of object: PyObject) throws(PythonError) -> String {
        guard let text = PyObject_Str(object.reference) else { throw raisedError() }
        defer { Py_DecRef(text) }

        guard let utf8 = PyUnicode_AsUTF8(text) else { throw raisedError() }
        return String(cString: utf8)
    }

    /// The module `name`, importing it the way `import name` does.
    public static func module(_ name: String) throws(PythonError) -> PyObject {
        guard let module = PyImport_ImportModule(name) else { throw raisedError() }
        return PyObject(consuming: module)
    }

    /// `__main__`'s namespace, which is where console input runs.
    static func mainNamespace() throws(PythonError) -> PyObject {
        guard let main = PyImport_AddModule("__main__"),
              let namespace = PyModule_GetDict(main) else {
            throw .SystemError("__main__ is missing")
        }
        // Both are borrowed references.
        Py_IncRef(namespace)
        return PyObject(consuming: namespace)
    }
}
