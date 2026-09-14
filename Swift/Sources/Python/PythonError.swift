import CPython
import Foundation

/// A Python exception, or a failure of the interpreter itself.
public struct PythonError: Error, Equatable {
    /// The exception type's name, e.g. `ValueError`.
    public let type: String

    /// The exception's message, usually `str()` of its value.
    public let value: String

    /// The formatted traceback, when the interpreter produced one.
    public let traceback: String?

    public init(type: String, value: String, traceback: String? = nil) {
        self.type = type
        self.value = value
        self.traceback = traceback
    }

    /// Returns a copy of this error carrying the given traceback.
    public func withTraceback(_ traceback: String?) -> PythonError {
        PythonError(type: type, value: value, traceback: traceback)
    }
}

extension PythonError: LocalizedError, CustomStringConvertible {
    public var description: String { traceback ?? "\(type): \(value)" }

    public var errorDescription: String? { description }
}

// MARK: - Exception constructors

public extension PythonError {
    static func RuntimeError(_ value: String) -> PythonError {
        PythonError(type: "RuntimeError", value: value)
    }

    /// The interpreter or the C API failed where it should not have.
    static func SystemError(_ value: String) -> PythonError {
        PythonError(type: "SystemError", value: value)
    }

    static func ImportError(_ value: String) -> PythonError {
        PythonError(type: "ImportError", value: value)
    }

    static func SyntaxError(_ value: String) -> PythonError {
        PythonError(type: "SyntaxError", value: value)
    }

    static func ValueError(_ value: String) -> PythonError {
        PythonError(type: "ValueError", value: value)
    }

    static func TypeError(_ value: String) -> PythonError {
        PythonError(type: "TypeError", value: value)
    }

    static func NotImplementedError(_ value: String) -> PythonError {
        PythonError(type: "NotImplementedError", value: value)
    }

    static func KeyError(_ value: String) -> PythonError {
        PythonError(type: "KeyError", value: value)
    }

    static func StopIteration(_ value: String) -> PythonError {
        PythonError(type: "StopIteration", value: value)
    }

    static func argCountError(_ got: Int, expected: Int) -> PythonError {
        .TypeError("expected \(expected) arguments, got \(got)")
    }
}

extension PyRuntime {
    /// The builtin exception type of that name, falling back to `RuntimeError`
    /// for one this build does not have.
    static func exceptionType(named name: String) -> PyRef? {
        guard let builtins = PyEval_GetBuiltins() else { return nil }
        return PyDict_GetItemString(builtins, name)
            ?? PyDict_GetItemString(builtins, "RuntimeError")
    }
}

// MARK: - As a Python object

extension PythonError: PythonConvertible {
    @MainActor
    public static var pyType: PyType { .builtin("BaseException") }

    public func toPython() throws(PythonError) -> PyObject {
        guard let exceptionType = PyRuntime.exceptionType(named: type),
              let message = PyUnicode_FromString(value) else {
            throw .SystemError("could not build a \(type)")
        }
        defer { Py_DecRef(message) }

        guard let object = PyObject_CallOneArg(exceptionType, message) else {
            PyErr_Clear()
            throw .SystemError("could not build a \(type)")
        }
        return PyObject(consuming: object)
    }

    public static func fromPython(_ reference: PyRef) -> PythonError {
        let name = PyRuntime.typeName(of: reference)
        // `str(exception)` is the message, the same thing pocketpy reads out of
        // `args[0]`.
        // Formatted here: a host only reports errors that carry a traceback.
        let traceback = PyRuntime.formattedException(reference)
        guard let text = PyObject_Str(reference) else {
            PyErr_Clear()
            return PythonError(type: name, value: "", traceback: traceback)
        }
        defer { Py_DecRef(text) }
        return PythonError(type: name, value: String(text) ?? "", traceback: traceback)
    }
}
