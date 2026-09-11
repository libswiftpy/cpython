import CPython

extension PyRuntime {
    /// Calls `function` with string arguments, returning a new reference.
    static func call(
        _ function: PyRef,
        with arguments: [String]
    ) throws(PythonError) -> PyRef {
        guard let tuple = PyTuple_New(arguments.count) else {
            throw .SystemError("could not allocate an argument tuple")
        }
        defer { Py_DecRef(tuple) }

        for (index, argument) in arguments.enumerated() {
            guard let value = PyUnicode_FromString(argument) else {
                throw .SystemError("could not allocate a string")
            }
            // Steals the reference it is given.
            PyTuple_SetItem(tuple, index, value)
        }

        guard let result = PyObject_Call(function, tuple, nil) else {
            throw raisedError()
        }
        return result
    }

    /// `str()` of a raised exception, with its traceback, or `nil` when the
    /// helpers are not up yet — which is the one case that must not recurse.
    static func formattedException(
        _ exception: PyRef
    ) -> String? {
        guard helpers != nil,
              let format = try? helper("_format_exception") else { return nil }
        defer { Py_DecRef(format) }

        guard let tuple = PyTuple_New(1) else { return nil }
        defer { Py_DecRef(tuple) }
        Py_IncRef(exception)
        PyTuple_SetItem(tuple, 0, exception)

        guard let text = PyObject_Call(format, tuple, nil) else {
            PyErr_Clear()
            return nil
        }
        defer { Py_DecRef(text) }

        return PyUnicode_AsUTF8(text).map(String.init(cString:))
    }

    /// The `_swiftpy` module, holding what is easier to write in Python than
    /// through the C API. Built on first use and kept for the process lifetime.
    private static var helpers: PyRef?

    /// Returns a new reference to one of the helpers.
    static func helper(_ name: String) throws(PythonError) -> PyRef {
        if helpers == nil {
            guard let module = PyImport_AddModule("_swiftpy"),
                  let namespace = PyModule_GetDict(module) else {
                throw .SystemError("could not make the _swiftpy module")
            }
            guard PyRun_StringFlags(helperSource, Py_file_input, namespace, namespace, nil) != nil else {
                throw raisedError()
            }
            Py_IncRef(module)
            helpers = module
        }

        guard let function = PyObject_GetAttrString(helpers, name) else {
            throw raisedError()
        }
        return function
    }

    private static let helperSource = """
        import _ast

        # CPython's own `single` input rejects more than one statement, but
        # the compiler is happy to build single-mode bytecode from Interactive.
        def _compile_cell(source, filename):
            tree = compile(source, filename, 'exec', 0x0400 | 0x2000)
            # 0x2000 again: the flag does not survive the AST, and a cell with
            # a top-level await has to compile to a coroutine here too.
            return compile(_ast.Interactive(body=tree.body), filename, 'single', 0x2000)

        # What a Swift-backed __await__ returns: an iterator that hands the
        # object to the driver, which sends the result of the work back in.
        def _awaitable(request):
            return (yield request)

        class _SwiftAwaitable:
            def __init__(self, seconds):
                self.seconds = seconds

            def __await__(self):
                return _awaitable(self)

        def sleep(seconds):
            return _SwiftAwaitable(seconds)

        # The def standing in front of a binding whose signature has defaults or
        # star parameters. CPython's own argument binding then does what
        # pocketpy's py_bind does: keywords by name, defaults filled, *args
        # one tuple, **kwargs one dict, all handed on in declaration order.
        def _wrap(signature, raw, docstring):
            import ast
            name = signature[:signature.index('(')].strip()
            arguments = ast.parse('def ' + signature + ': pass').body[0].args
            names = [a.arg for a in arguments.posonlyargs + arguments.args]
            if arguments.vararg:
                names.append(arguments.vararg.arg)
            names += [a.arg for a in arguments.kwonlyargs]
            if arguments.kwarg:
                names.append(arguments.kwarg.arg)
            namespace = {'_raw': raw}
            exec('def ' + signature + ':\\n    return _raw(' + ', '.join(names) + ')', namespace)
            function = namespace[name]
            function.__doc__ = docstring
            return function

        def _format_exception(exception):
            lines = ['Traceback (most recent call last):\\n']
            traceback = exception.__traceback__
            while traceback is not None:
                code = traceback.tb_frame.f_code
                lines.append('  File "%s", line %d, in %s\\n'
                             % (code.co_filename, traceback.tb_lineno, code.co_name))
                traceback = traceback.tb_next
            lines.append('%s: %s\\n' % (type(exception).__name__, exception))
            return ''.join(lines)
        """
}
