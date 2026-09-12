import CPython

@MainActor
public enum PythonCompiler {
    public enum Mode: Sendable {
        /// A script: statements run, nothing is echoed.
        case execution
        /// A single expression, whose value is the result.
        case evaluation
        /// A console cell: statements run and each expression echoes its value
        /// through `sys.displayhook`.
        case single

        var start: Int32 {
            switch self {
            case .execution: Py_file_input
            case .evaluation: Py_eval_input
            case .single: Py_single_input
            }
        }
    }

    /// Compiles source into a code object.
    public static func compile(
        _ source: String,
        filename: String = "<string>",
        mode: Mode = .execution
    ) throws(PythonError) -> PyObject {
        let code: PyObject
        if mode == .single {
            // CPython's own single input takes one statement, while a cell is a
            // whole block. See PythonCell.swift.
            let compileCell = try PyRuntime.helper("_compile_cell")
            defer { Py_DecRef(compileCell) }
            code = PyObject(
                consuming: try PyRuntime.call(compileCell, with: [source, filename])
            )
        } else {
            // Source with a top-level `await` compiles to a coroutine that
            // `execute` hands back instead of running. See PythonCoroutine.swift.
            var flags = PyCompilerFlags(
                cf_flags: PyCF_ALLOW_TOP_LEVEL_AWAIT,
                cf_feature_version: 0
            )
            guard let reference = Py_CompileStringExFlags(source, filename, mode.start, &flags, -1) else {
                throw PyRuntime.raisedError()
            }
            code = PyObject(consuming: reference)
        }

        try PyRuntime.cacheSource(source, filename: filename)
        return code
    }
}

/// The name SwiftPy uses for a compile mode. The cases are the same, so the
/// shared code needs no mapping.
public typealias CompileMode = PythonCompiler.Mode
