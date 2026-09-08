import CPython
import Foundation

/// A Python object, kept alive for as long as this wrapper is.
///
/// `@unchecked Sendable` so it can be held by an actor, but every use of
/// ``pointer`` still belongs on the main actor.
@dynamicMemberLookup
public final class PythonObject: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<PyObject>

    /// Takes ownership of a new reference.
    init(consuming pointer: UnsafeMutablePointer<PyObject>) {
        self.pointer = pointer
    }

    /// Reads or writes a Python attribute. Reading gives `nil` when it is
    /// missing or `None`; writing `nil` sets it to `None`.
    ///
    ///     let sys = try cpy.module("sys")
    ///     sys.stdout = sys.__stdout__
    @MainActor
    public subscript(dynamicMember name: String) -> PythonObject? {
        get {
            guard let attribute = PyObject_GetAttrString(pointer, name) else {
                PyErr_Clear()
                return nil
            }

            guard Py_IsNone(attribute) == 0 else {
                Py_DecRef(attribute)
                return nil
            }
            return PythonObject(consuming: attribute)
        }
        set {
            let value = newValue?.pointer ?? Py_GetConstantBorrowed(UInt32(Py_CONSTANT_NONE))
            if PyObject_SetAttrString(pointer, name, value) != 0 {
                PyErr_Clear()
            }
        }
    }

    // Isolated, because the last reference can be dropped anywhere — an actor
    // holding a code object releases it on its own thread — and a decref there
    // has no thread state and would abort the process.
    @MainActor deinit {
        Py_DecRef(pointer)
    }
}

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
    ) throws(PythonError) -> PythonObject {
        // `single` goes through the helper: CPython's own single input takes
        // one statement, while a cell is a whole block. See PythonCell.swift.
        guard mode != .single else {
            let compileCell = try Python.helper("_compile_cell")
            defer { Py_DecRef(compileCell) }
            return PythonObject(
                consuming: try Python.call(compileCell, with: [source, filename])
            )
        }

        guard let code = Py_CompileStringExFlags(source, filename, mode.start, nil, -1) else {
            throw Python.raisedError()
        }
        return PythonObject(consuming: code)
    }
}
