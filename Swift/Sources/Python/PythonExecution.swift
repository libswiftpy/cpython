import CPython

extension PyRuntime {
    /// Runs a code object from ``PythonCompiler/compile(_:filename:mode:)``,
    /// on the calling thread, which must hold the GIL: main does whenever it
    /// runs. ``PythonActor`` has the asynchronous form.
    ///
    /// Defaults to `__main__`'s namespace. Pass a ``namespace()`` of your own
    /// for code that should not see, or be seen by, what runs there.
    @discardableResult
    public nonisolated static func execute(
        _ code: PyObject,
        globals: PyObject? = nil,
        locals: PyObject? = nil
    ) throws(PythonError) -> PyObject {
        try run(code: code, globals: globals, locals: locals)
    }

    /// The synchronous `execute`, under a name the asynchronous one can reach.
    @discardableResult
    nonisolated static func run(
        code: PyObject,
        globals: PyObject?,
        locals: PyObject?
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
    public nonisolated static func namespace() throws(PythonError) -> PyObject {
        guard let dictionary = PyDict_New() else { throw .SystemError("could not allocate a dict") }
        let namespace = PyObject(consuming: dictionary)

        guard let builtins = PyEval_GetBuiltins(),
              PyDict_SetItemString(dictionary, "__builtins__", builtins) == 0 else {
            throw raisedError()
        }
        return namespace
    }

    /// Calls `function` with positional `arguments`. Expects the GIL held:
    /// what ``PythonActor`` code uses in place of the main-actor `PyObject`
    /// call.
    @discardableResult
    public nonisolated static func call(
        _ function: PyObject,
        arguments: [PyObject] = []
    ) throws(PythonError) -> PyObject {
        guard let tuple = PyTuple_New(arguments.count) else {
            throw .SystemError("could not allocate an argument tuple")
        }
        defer { Py_DecRef(tuple) }
        for (index, argument) in arguments.enumerated() {
            // The tuple steals what it is given, and the box keeps its own.
            Py_IncRef(argument.reference)
            PyTuple_SetItem(tuple, index, argument.reference)
        }

        guard let result = PyObject_Call(function.reference, tuple, nil) else {
            throw raisedError()
        }
        return PyObject(consuming: result)
    }

    /// `str()` of an object.
    public nonisolated static func string(of object: PyObject) throws(PythonError) -> String {
        guard let text = PyObject_Str(object.reference) else { throw raisedError() }
        defer { Py_DecRef(text) }

        guard let utf8 = PyUnicode_AsUTF8(text) else { throw raisedError() }
        return String(cString: utf8)
    }

    /// The module `name`, importing it the way `import name` does.
    public nonisolated static func module(_ name: String) throws(PythonError) -> PyObject {
        guard let module = PyImport_ImportModule(name) else { throw raisedError() }
        return PyObject(consuming: module)
    }

    /// `__main__`'s namespace, which is where console input runs.
    nonisolated static func mainNamespace() throws(PythonError) -> PyObject {
        guard let main = PyImport_AddModule("__main__"),
              let namespace = PyModule_GetDict(main) else {
            throw .SystemError("__main__ is missing")
        }
        // Both are borrowed references.
        Py_IncRef(namespace)
        return PyObject(consuming: namespace)
    }
}
