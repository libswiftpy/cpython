import CPython

/// Lets `import` reach Python sources the host holds, the way a file finder
/// reaches files. Appended to `sys.meta_path`, so the bundled stdlib wins and
/// the host's sources only fill the gaps.
///
/// The providers are asked on whichever thread imports, with the GIL held,
/// and -- unlike a binding -- not from main: an import holds the import lock,
/// and main may be waiting for that very lock.
public extension PyRuntime {
    /// The source of the module `name`, dotted, or `nil` when the host has none.
    nonisolated(unsafe) static var sourceProvider: (@Sendable (String) -> String?)?

    /// Whether `name` is a package: something has a submodule under it.
    nonisolated(unsafe) static var packageProvider: (@Sendable (String) -> Bool)?

    /// Installs the finder. Call once, on main, after setting the providers.
    static func installSourceFinder() throws(PythonError) {
        guard let module = PyImport_AddModule("_swiftpy_sources") else {
            throw raisedError()
        }
        for method in [sourceMethod, isPackageMethod] {
            guard let function = PyCFunction_NewEx(method, module, nil) else {
                throw raisedError()
            }
            defer { Py_DecRef(function) }
            guard PyObject_SetAttrString(module, method.pointee.ml_name, function) == 0 else {
                throw raisedError()
            }
        }

        // A namespace of its own, not __main__: a console clears that.
        let namespace = try namespace()
        guard let result = PyRun_StringFlags(finderSource, Py_file_input, namespace.reference, namespace.reference, nil) else {
            throw raisedError()
        }
        Py_DecRef(result)
    }

    /// The finder's bindings. Raw method tables rather than ``PyModule/def``:
    /// a thunk would take them to main. Allocated once and never freed, as
    /// CPython keeps referring to them.
    private nonisolated(unsafe) static let sourceMethod: UnsafeMutablePointer<PyMethodDef> = {
        let method = UnsafeMutablePointer<PyMethodDef>.allocate(capacity: 1)
        method.initialize(to: PyMethodDef(
            ml_name: strdup("source"),
            ml_meth: { _, name in
                guard let name, let utf8 = PyUnicode_AsUTF8(name) else { return nil }
                guard let source = sourceProvider?(String(cString: utf8)) else {
                    return Py_GetConstant(UInt32(Py_CONSTANT_NONE))
                }
                return PyUnicode_FromString(source)
            },
            ml_flags: Int32(METH_O),
            ml_doc: nil
        ))
        return method
    }()

    private nonisolated(unsafe) static let isPackageMethod: UnsafeMutablePointer<PyMethodDef> = {
        let method = UnsafeMutablePointer<PyMethodDef>.allocate(capacity: 1)
        method.initialize(to: PyMethodDef(
            ml_name: strdup("is_package"),
            ml_meth: { _, name in
                guard let name, let utf8 = PyUnicode_AsUTF8(name) else { return nil }
                return PyBool_FromLong(packageProvider?(String(cString: utf8)) == true ? 1 : 0)
            },
            ml_flags: Int32(METH_O),
            ml_doc: nil
        ))
        return method
    }()

    private nonisolated static let finderSource = """
        import sys
        from _frozen_importlib import ModuleSpec
        import _swiftpy_sources as _sources

        class _SwiftSourceLoader:
            def __init__(self, source):
                self._source = source

            def create_module(self, spec):
                return None

            def exec_module(self, module):
                code = compile(self._source, module.__spec__.origin, 'exec')
                exec(code, module.__dict__)

            # What tracebacks and linecache read the lines from.
            def get_source(self, fullname):
                return self._source

        class _SwiftSourceFinder:
            @staticmethod
            def find_spec(fullname, path=None, target=None):
                source = _sources.source(fullname)
                if source is None:
                    return None
                spec = ModuleSpec(fullname, _SwiftSourceLoader(source), origin='<' + fullname + '>')
                if _sources.is_package(fullname):
                    spec.submodule_search_locations = []
                return spec

        sys.meta_path.append(_SwiftSourceFinder)
        """
}
