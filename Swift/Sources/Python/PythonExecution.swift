import CPython

extension Python {
    /// Runs a code object from ``PythonCompiler/compile(_:filename:mode:)``.
    ///
    /// Defaults to `__main__`'s namespace. Pass a ``namespace()`` of your own
    /// for code that should not see, or be seen by, what runs there.
    @discardableResult
    public static func execute(
        _ code: PythonObject,
        globals: PythonObject? = nil,
        locals: PythonObject? = nil
    ) throws(PythonError) -> PythonObject {
        // `??` widens a typed throw to `any Error`, so spell the fallback out.
        let globals = if let globals { globals } else { try mainNamespace() }
        let locals = locals ?? globals

        guard let result = PyEval_EvalCode(code.reference, globals.reference, locals.reference) else {
            throw raisedError()
        }
        return PythonObject(consuming: result)
    }

    /// A fresh namespace, seeded with the builtins so code can run in it.
    public static func namespace() throws(PythonError) -> PythonObject {
        guard let dictionary = PyDict_New() else { throw .SystemError("could not allocate a dict") }
        let namespace = PythonObject(consuming: dictionary)

        guard let builtins = PyEval_GetBuiltins(),
              PyDict_SetItemString(dictionary, "__builtins__", builtins) == 0 else {
            throw raisedError()
        }
        return namespace
    }

    /// `str()` of an object.
    public static func string(of object: PythonObject) throws(PythonError) -> String {
        guard let text = PyObject_Str(object.reference) else { throw raisedError() }
        defer { Py_DecRef(text) }

        guard let utf8 = PyUnicode_AsUTF8(text) else { throw raisedError() }
        return String(cString: utf8)
    }

    /// The module `name`, importing it the way `import name` does.
    public static func module(_ name: String) throws(PythonError) -> PythonObject {
        guard let module = PyImport_ImportModule(name) else { throw raisedError() }
        return PythonObject(consuming: module)
    }

    /// `__main__`'s namespace, which is where console input runs.
    static func mainNamespace() throws(PythonError) -> PythonObject {
        guard let main = PyImport_AddModule("__main__"),
              let namespace = PyModule_GetDict(main) else {
            throw .SystemError("__main__ is missing")
        }
        // Both are borrowed references.
        Py_IncRef(namespace)
        return PythonObject(consuming: namespace)
    }
}
