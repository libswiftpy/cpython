import CPython

import Foundation

/// A minimal embedded CPython interpreter.
///
/// CPython is a process-wide singleton, so every entry point here is static,
/// mirroring the C API it wraps.
public enum Python {
    /// The interpreter home shipped with this package: a `lib/python<X.Y>`
    /// holding the minimal stdlib, staged by Swift/build.sh and copied into
    /// the resource bundle by SwiftPM. In an app that bundle sits inside
    /// `Contents/Resources`, which a sandboxed process can read — unlike the
    /// CPython checkout it was built from.
    public static var defaultHome: String? {
        guard let home = Bundle.module.url(forResource: "PythonHome", withExtension: nil),
              (try? home.appendingPathComponent("lib").checkResourceIsReachable()) == true else {
            return nil
        }
        return home.path
    }

    /// The interpreter's version, e.g. `3.16.0a0 (heads/main, ...)`.
    public static var version: String { String(cString: Py_GetVersion()) }

    public static var isInitialized: Bool { Py_IsInitialized() != 0 }

    /// Thread state parked by ``initialize(home:)``; see ``withGIL(_:)``.
    private nonisolated(unsafe) static var parkedThreadState: UnsafeMutablePointer<PyThreadState>?

    /// Starts the interpreter.
    ///
    /// The configuration is *isolated*: no `site` import, no environment
    /// variables, no signal handlers — only what an embedded interpreter needs.
    public static func initialize(home: String? = defaultHome) throws {
        guard !isInitialized else { return }
        guard let home else {
            throw PythonError.initializationFailed(
                "no stdlib in \(Bundle.module.bundlePath); run Swift/build.sh")
        }

        var configuration = PyConfig()
        PyConfig_InitIsolatedConfig(&configuration)
        defer { PyConfig_Clear(&configuration) }

        try withUnsafeMutablePointer(to: &configuration) { configuration in
            try check(PyConfig_SetBytesString(configuration, &configuration.pointee.home, home))
            configuration.pointee.site_import = 0
            configuration.pointee.install_signal_handlers = 0
            try check(Py_InitializeFromConfig(configuration))
        }

        // Initialization leaves the GIL held by this thread. Release it, so any
        // thread can take it through `withGIL`.
        parkedThreadState = PyEval_SaveThread()
    }

    /// Runs `body` while holding the global interpreter lock.
    ///
    /// Every call into CPython has to be made under the lock, including the
    /// ones made by ``run(_:)`` and ``evaluate(_:)``.
    public static func withGIL<T>(_ body: () throws -> T) rethrows -> T {
        let state = PyGILState_Ensure()
        defer { PyGILState_Release(state) }
        return try body()
    }

    /// Runs a block of Python source in `__main__`.
    public static func run(_ source: String) throws {
        try withGIL {
            guard PyRun_SimpleStringFlags(source, nil) == 0 else {
                throw PythonError.executionFailed
            }
        }
    }

    /// Evaluates a Python expression and returns `str()` of its result.
    public static func evaluate(_ expression: String) throws -> String {
        try withGIL {
            guard let main = PyImport_AddModule("__main__"),
                  let globals = PyModule_GetDict(main) else {
                throw PythonError.executionFailed
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
    }

    /// Shuts the interpreter down.
    @discardableResult
    public static func finalize() -> Bool {
        guard isInitialized else { return true }
        if let state = parkedThreadState {
            PyEval_RestoreThread(state)
            parkedThreadState = nil
        }
        return Py_FinalizeEx() == 0
    }

    // MARK: - Errors

    private static func check(_ status: PyStatus) throws {
        guard PyStatus_Exception(status) != 0 else { return }
        let message = status.err_msg.map(String.init(cString:)) ?? "unknown failure"
        throw PythonError.initializationFailed(message)
    }

    /// Consumes the currently raised exception, if any.
    private static func raisedError() -> PythonError {
        guard let exception = PyErr_GetRaisedException() else { return .executionFailed }
        defer { Py_DecRef(exception) }

        guard let text = PyObject_Str(exception), let utf8 = PyUnicode_AsUTF8(text) else {
            return .executionFailed
        }
        defer { Py_DecRef(text) }
        return .raised(String(cString: utf8))
    }
}

public enum PythonError: Error, Equatable {
    case initializationFailed(String)
    case executionFailed
    case raised(String)
}
