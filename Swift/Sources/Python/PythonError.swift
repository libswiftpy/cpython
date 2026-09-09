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
