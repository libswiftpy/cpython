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
        // `single` goes through the helper: CPython's own single input takes
        // one statement, while a cell is a whole block. See PythonCell.swift.
        guard mode != .single else {
            let compileCell = try PyRuntime.helper("_compile_cell")
            defer { Py_DecRef(compileCell) }
            return PyObject(
                consuming: try PyRuntime.call(compileCell, with: [source, filename])
            )
        }

        guard let code = Py_CompileStringExFlags(source, filename, mode.start, nil, -1) else {
            throw PyRuntime.raisedError()
        }
        return PyObject(consuming: code)
    }
}
