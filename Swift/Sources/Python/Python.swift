import CPython
import PythonModules
import _apple_support
import encodings
import stdlib
import zlib
import math
import _random
import _sha2
import _lsprof
import _struct
import binascii
import _csv
import array
import cmathmodule
import _md5
import _sha1
import _sha3
import _blake2
import _sqlite3
import unicodedata
import pyexpat

@_exported import struct PythonModules.PythonModule

import Foundation

/// A minimal embedded CPython interpreter.
///
/// CPython is a process-wide singleton, so every entry point here is static,
/// mirroring the C API it wraps.
///
/// Isolated to the main actor, which is what makes the interpreter
/// single-threaded: the GIL is taken there during initialization and never
/// released, so the isolation and the lock describe the same thread.
@MainActor
public enum PyRuntime {
    /// The stdlib always linked in: what the interpreter imports while starting,
    /// plus the C modules behind the pure-Python stdlib the package ships.
    public static var essentialModules: [PythonModule] {
        [.encodings, .appleSupport, .stdlib, .zlib, .math, .random, .sha2, .lsprof,
         .struct, .binascii, .csv, .array, .cmath, .md5, .sha1, .sha3, .blake2,
         .sqlite3, .unicodedata, .pyexpat]
    }

    /// The interpreter's version, e.g. `3.16.0a0 (heads/main, ...)`.
    public static var version: String { String(cString: Py_GetVersion()) }

    public static var isInitialized: Bool { Py_IsInitialized() != 0 }

    /// Starts the interpreter.
    ///
    /// The configuration is *isolated*: no `site` import, no environment
    /// variables, no signal handlers — only what an embedded interpreter needs.
    ///
    /// The interpreter is single-threaded: the GIL stays attached to the main
    /// thread and is never released, so Python only ever runs there — where
    /// Python code can reach the UI directly.
    public static func initialize(modules: [PythonModule] = []) throws(PythonError) {
        guard !isInitialized else { return }

        let all = essentialModules + modules
        let searchPaths = all.flatMap(\.searchPaths)
        guard !searchPaths.isEmpty else {
            throw .ImportError("no stdlib bundled; run Swift/build.sh")
        }

        // The inittab is read during initialization, so C modules have to be
        // registered before it.
        for builtin in all.flatMap(\.builtins) {
            // CPython stores the name pointer as-is, so it has to outlive this
            // call: the copy is deliberately never freed.
            let name = strdup(builtin.name)
            guard PyImport_AppendInittab(name, builtin.initializer) == 0 else {
                throw .SystemError("could not register \(builtin.name)")
            }
        }

        // zoneinfo asks sysconfig for the tz database, and sysconfig has no
        // build data here; the isolated config ignores PYTHON* variables, but
        // os.environ still carries this one to zoneinfo.
        setenv("PYTHONTZPATH", "/usr/share/zoneinfo", 1)

        var configuration = PyConfig()
        PyConfig_InitIsolatedConfig(&configuration)
        defer { PyConfig_Clear(&configuration) }

        // sys.path is set outright rather than computed from a prefix: the
        // stdlib is spread across one resource bundle per module, and
        // `encodings` has to be found before initialization finishes.
        for path in searchPaths {
            guard let wide = Py_DecodeLocale(path, nil) else {
                throw .ValueError("could not decode \(path)")
            }
            defer { PyMem_RawFree(wide) }
            try check(PyWideStringList_Append(&configuration.module_search_paths, wide))
        }
        configuration.module_search_paths_set = 1
        configuration.site_import = 0
        configuration.install_signal_handlers = 0
        // Never write __pycache__ next to the staged sources: they would end up
        // in the resource bundles as dead weight.
        configuration.write_bytecode = 0
        try check(Py_InitializeFromConfig(&configuration))

        // Built here rather than on first use, so `import _swiftpy` works from
        // Python code too and not only from the Swift side.
        _ = try helper("_compile_cell")

        // Initialization leaves the GIL held by this thread, and it stays that
        // way: an uncontended GIL that is never handed over costs nothing, and
        // keeping it here is what makes the interpreter single-threaded.
    }

    /// Adds a directory to `sys.path`.
    public static func addSearchPath(_ path: String) throws(PythonError) {
        try run("import sys; sys.path.append(\(pythonLiteral(path)))")
    }

    private static func pythonLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Runs a block of Python source in `__main__`.
    public static func run(_ source: String) throws(PythonError) {
        // The interpreter prints and clears the traceback itself, so there is
        // nothing left to report beyond the failure.
        guard PyRun_SimpleStringFlags(source, nil) == 0 else {
            throw .RuntimeError("execution failed")
        }
    }

    /// Evaluates a Python expression and returns `str()` of its result.
    public static func evaluate(_ expression: String) throws(PythonError) -> String {
        guard let main = PyImport_AddModule("__main__"),
              let globals = PyModule_GetDict(main) else {
            throw .SystemError("__main__ is missing")
        }

        guard let result = PyRun_StringFlags(expression, Py_eval_input, globals, globals, nil) else {
            throw raisedError()
        }
        defer { Py_DecRef(result) }

        guard let text = PyObject_Str(result) else { throw raisedError() }
        defer { Py_DecRef(text) }

        guard let utf8 = PyUnicode_AsUTF8(text) else { throw raisedError() }
        return String(cString: utf8)
    }

    /// Shuts the interpreter down.
    @discardableResult
    public static func finalize() -> Bool {
        guard isInitialized else { return true }
        return Py_FinalizeEx() == 0
    }

    // MARK: - Errors

    private static func check(_ status: PyStatus) throws(PythonError) {
        guard PyStatus_Exception(status) != 0 else { return }
        let message = status.err_msg.map(String.init(cString:)) ?? "unknown failure"
        throw .SystemError(message)
    }

    /// Consumes the currently raised exception, if any.
    static func raisedError() -> PythonError {
        guard let exception = PyErr_GetRaisedException() else {
            return .SystemError("failed without raising")
        }
        defer { Py_DecRef(exception) }

        let type = typeName(of: exception)
        let traceback = formattedException(exception)

        guard let text = PyObject_Str(exception), let utf8 = PyUnicode_AsUTF8(text) else {
            return PythonError(type: type, value: "", traceback: traceback)
        }
        defer { Py_DecRef(text) }
        return PythonError(type: type, value: String(cString: utf8), traceback: traceback)
    }

    /// `type(exception).__name__`, or a fallback when even that fails.
    static func typeName(of exception: PyRef) -> String {
        guard let type = PyObject_GetAttrString(exception, "__class__") else {
            PyErr_Clear()
            return "Exception"
        }
        defer { Py_DecRef(type) }

        guard let name = PyObject_GetAttrString(type, "__name__"),
              let utf8 = PyUnicode_AsUTF8(name) else {
            PyErr_Clear()
            return "Exception"
        }
        defer { Py_DecRef(name) }
        return String(cString: utf8)
    }
}
